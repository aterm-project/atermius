package com.atermius.aterm_client

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Runtime permissions behind RDP microphone and camera redirection. The
 * native engine opens the microphone (OpenSL ES) and cameras (Camera2) inside
 * the session, so Dart asks before the handshake: when the user starts a
 * connection whose Host has them on (once per Host per app process), or when
 * the user turns the Host's switch on. "check" never prompts. "request" runs
 * only while the activity is resumed and one at a time; each name reports
 * "granted", "denied" (Android still shows its dialog) or "permanentlyDenied"
 * (only app settings can grant it, so Dart offers "Open app settings"). */
class RdpDevicePermissions(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val resumed: () -> Boolean,
) {
    private val channel = MethodChannel(messenger, "atermius/rdp_permissions")
    private var pending: MethodChannel.Result? = null
    private var pendingNames: List<String> = emptyList()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> {
                    val names = names(call)
                    if (names == null) invalid(result) else result.success(states(names))
                }
                "request" -> {
                    val names = names(call)
                    if (names == null) invalid(result) else request(names, result)
                }
                "openSettings" -> result.success(openSettings())
                else -> result.notImplemented()
            }
        }
    }

    private fun invalid(result: MethodChannel.Result) =
        result.error("invalid_arguments", "Expected permission names", null)

    /** Only the names this broker knows; anything else is rejected whole. */
    private fun names(call: MethodCall): List<String>? {
        val raw = call.argument<List<Any?>>("permissions") ?: return null
        if (raw.isEmpty() || raw.size > PERMISSIONS.size) return null
        val names = raw.map { it as? String ?: return null }.distinct()
        return if (names.all { it in PERMISSIONS }) names else null
    }

    private fun granted(name: String) =
        activity.checkSelfPermission(PERMISSIONS.getValue(name)) == PackageManager.PERMISSION_GRANTED

    private fun states(names: List<String>): Map<String, String> = names.associateWith { name ->
        when {
            granted(name) -> { blocked.remove(name); "granted" }
            name in blocked -> "permanentlyDenied"
            else -> "denied"
        }
    }

    private fun request(names: List<String>, result: MethodChannel.Result) {
        val missing = names.filter { !granted(it) }
        if (missing.isEmpty()) { result.success(states(names)); return }
        if (pending != null) { result.error("busy", "A permission request is already open", null); return }
        // A dialog over another app, or after the user left, is never shown.
        if (!resumed()) {
            result.error("unavailable", "Permission requests need the visible activity", null)
            return
        }
        pending = result
        pendingNames = names
        try {
            activity.requestPermissions(missing.map { PERMISSIONS.getValue(it) }.toTypedArray(), REQUEST_CODE)
        } catch (_: Exception) {
            pending = null
            pendingNames = emptyList()
            result.success(states(names))
        }
    }

    /** From MainActivity.onRequestPermissionsResult. A denial after which
     * Android would no longer show its dialog is remembered for this process
     * so "check" reports it too. An interrupted request (empty results)
     * decided nothing and is reported as an error, so Dart may ask again on
     * the next user action. A first-time dismissal also leaves the rationale
     * off, so it is reported as permanent: "Open app settings" still works
     * then, while a retry button might do nothing. */
    fun permissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != REQUEST_CODE) return
        val result = pending ?: return
        val names = pendingNames
        pending = null
        pendingNames = emptyList()
        if (grantResults.isEmpty()) {
            result.error("interrupted", "The permission request was interrupted", null)
            return
        }
        val refused = permissions.indices
            .filter { it < grantResults.size && grantResults[it] != PackageManager.PERMISSION_GRANTED }
            .map { permissions[it] }
            .toSet()
        for (name in names) {
            val permission = PERMISSIONS.getValue(name)
            if (permission in refused && !activity.shouldShowRequestPermissionRationale(permission)) {
                blocked.add(name)
            }
        }
        result.success(states(names))
    }

    private fun openSettings(): Boolean {
        if (!resumed()) return false
        return try {
            activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${activity.packageName}")))
            true
        } catch (_: Exception) {
            false
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
        val result = pending
        val names = pendingNames
        pending = null
        pendingNames = emptyList()
        result?.success(states(names))
    }

    companion object {
        private const val REQUEST_CODE = 0x4154
        private val PERMISSIONS = mapOf(
            "microphone" to Manifest.permission.RECORD_AUDIO,
            "camera" to Manifest.permission.CAMERA,
        )
        /** Names Android stopped asking for in this process. */
        private val blocked = mutableSetOf<String>()
    }
}
