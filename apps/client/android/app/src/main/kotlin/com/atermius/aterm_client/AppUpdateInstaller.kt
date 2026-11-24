package com.atermius.aterm_client

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Installs a release package the Dart updater downloaded and verified into
 * the app's own cache. Only a newer version of this very app is accepted;
 * Android itself checks that it is signed with the same key. The system asks
 * the user where it has to (always before Android 12, and the first time a
 * side-loaded copy updates itself); it ends this process when it replaces
 * the app.
 */
class AppUpdateInstaller(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "atermius/app_update")
    private val main = Handler(Looper.getMainLooper())
    private val action = activity.packageName + ".APP_UPDATE_STATUS"
    private var registered = false

    private val status = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    val confirm = if (Build.VERSION.SDK_INT >= 33)
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    val prompt = confirm?.let(::installerPrompt)
                    val shown = prompt != null && runCatching { activity.startActivity(prompt) }.isSuccess
                    if (!shown) report("failed")
                }
                // The process is replaced before this could matter.
                PackageInstaller.STATUS_SUCCESS -> Unit
                PackageInstaller.STATUS_FAILURE_ABORTED -> report("cancelled")
                else -> report("failed")
            }
        }
    }

    init {
        // Opening the updated app is what the "updated" notification asks for.
        cancelDoneNotification(activity)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(Build.VERSION.SDK_INT >= 23)
                "metered" -> result.success(runCatching {
                    activity.getSystemService(ConnectivityManager::class.java)?.isActiveNetworkMetered
                }.getOrNull() ?: false)
                "install" -> {
                    val path = call.argument<String>("path")
                    val title = call.argument<String>("doneTitle")
                    val body = call.argument<String>("doneBody")
                    if (path == null || title.isNullOrBlank() || body.isNullOrBlank() ||
                        title.length > 120 || body.length > 240) {
                        result.error("invalid_arguments", "Invalid install request", null)
                    } else install(path, title, body, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * [confirm] made explicit for the system installer's confirmation screen,
     * or null when it would start anything else. Only the system reaches the
     * receiver, but this app starts what the status carries with its own
     * identity (and its file provider grants URI access), so it is checked
     * too: it has to resolve to a system app holding INSTALL_PACKAGES, which
     * approving an install session takes, in the package it names, and it
     * must not carry data or URI grants; the system's never does.
     */
    private fun installerPrompt(confirm: Intent): Intent? {
        val grants = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        if (confirm.flags and grants != 0 || confirm.data != null || confirm.clipData != null ||
            confirm.selector != null) return null
        // The system always names the installer; it never leaves the choice open.
        val named = confirm.component?.packageName ?: confirm.`package` ?: return null
        val manager = activity.packageManager
        val info = runCatching {
            @Suppress("DEPRECATION")
            manager.queryIntentActivities(confirm, PackageManager.MATCH_DEFAULT_ONLY).firstOrNull()?.activityInfo
        }.getOrNull() ?: return null
        if (info.packageName != named || info.packageName == activity.packageName ||
            info.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM == 0 ||
            manager.checkPermission(Manifest.permission.INSTALL_PACKAGES, info.packageName) !=
                PackageManager.PERMISSION_GRANTED) return null
        return Intent(confirm).setComponent(ComponentName(info.packageName, info.name))
    }

    private fun report(state: String) {
        forgetDone(activity)
        main.post { channel.invokeMethod("installStatus", state) }
    }

    private fun install(path: String, title: String, body: String, result: MethodChannel.Result) {
        val file: File
        try {
            val root = File(activity.cacheDir, "app-updates").canonicalFile
            file = File(path).canonicalFile
            require(file.isFile && file.path.startsWith(root.path + File.separator))
        } catch (_: Exception) {
            result.error("invalid_package", "Not an update package of this app", null)
            return
        }
        val manager = activity.packageManager
        @Suppress("DEPRECATION")
        val incoming = manager.getPackageArchiveInfo(file.path, 0)
        if (incoming == null || incoming.packageName != activity.packageName) {
            result.error("invalid_package", "Not an update package of this app", null)
            return
        }
        @Suppress("DEPRECATION")
        val installed = manager.getPackageInfo(activity.packageName, 0)
        if (versionCode(incoming) <= versionCode(installed)) {
            result.error("not_newer", "The package is not newer than the installed app", null)
            return
        }
        if (!registered) {
            // Not exported on every API level (androidx guards it with a
            // signature permission before 33): only the status the system
            // sends through this app's own PendingIntent reaches it.
            ContextCompat.registerReceiver(activity, status, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
            registered = true
        }
        // Remembered across the replacement for [AppUpdatedReceiver].
        activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_PENDING, true).putString(KEY_TITLE, title).putString(KEY_BODY, body).apply()
        Thread {
            try {
                val installer = manager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(activity.packageName)
                params.setSize(file.length())
                if (Build.VERSION.SDK_INT >= 26) params.setInstallReason(PackageManager.INSTALL_REASON_USER)
                // Android 12+: no prompt once this app is its own installer of record.
                if (Build.VERSION.SDK_INT >= 31) {
                    params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                if (Build.VERSION.SDK_INT >= 33) params.setPackageSource(PackageInstaller.PACKAGE_SOURCE_OTHER)
                val id = installer.createSession(params)
                installer.openSession(id).use { session ->
                    session.openWrite("atermius.apk", 0, file.length()).use { out ->
                        file.inputStream().use { it.copyTo(out, 1 shl 16) }
                        session.fsync(out)
                    }
                    val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                        (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                    val pending = PendingIntent.getBroadcast(
                        activity, id, Intent(action).setPackage(activity.packageName), flags)
                    session.commit(pending.intentSender)
                }
                main.post { result.success(null) }
            } catch (error: Exception) {
                forgetDone(activity)
                main.post { result.error("install_failed", "The system installer refused the package", null) }
            }
        }.start()
    }

    fun close() {
        channel.setMethodCallHandler(null)
        if (registered) {
            runCatching { activity.unregisterReceiver(status) }
            registered = false
        }
    }

    companion object {
        const val PREFS = "atermius_app_update"
        const val KEY_PENDING = "pending"
        const val KEY_TITLE = "done_title"
        const val KEY_BODY = "done_body"
        const val CHANNEL = "atermius_app_update"
        const val NOTIFICATION = 0x41550001

        @Suppress("DEPRECATION")
        private fun versionCode(info: android.content.pm.PackageInfo): Long =
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

        fun forgetDone(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY_PENDING).apply()
        }

        fun cancelDoneNotification(context: Context) {
            runCatching {
                context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION)
            }
        }
    }
}

/**
 * After the system replaced the app during an update the user started, the
 * app is closed. Android does not let it reopen itself from the background,
 * so a notification offers the way back. Nothing is shown for updates that
 * did not come from the in-app updater.
 */
class AppUpdatedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val prefs = context.getSharedPreferences(AppUpdateInstaller.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(AppUpdateInstaller.KEY_PENDING, false)) return
        val title = prefs.getString(AppUpdateInstaller.KEY_TITLE, null)
        val body = prefs.getString(AppUpdateInstaller.KEY_BODY, null)
        prefs.edit().clear().apply()
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT < 29) {
            // Before Android 10 the app may simply come back.
            if (runCatching { context.startActivity(launch) }.isSuccess) return
        }
        if (title.isNullOrBlank() || body.isNullOrBlank()) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(AppUpdateInstaller.CHANNEL, title, NotificationManager.IMPORTANCE_DEFAULT))
        }
        val open = PendingIntent.getActivity(context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, AppUpdateInstaller.CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(context)
        val notification = builder.setSmallIcon(R.drawable.ic_atermius_notification)
            .setContentTitle(title).setContentText(body)
            .setContentIntent(open).setAutoCancel(true).build()
        runCatching { manager.notify(AppUpdateInstaller.NOTIFICATION, notification) }
    }
}
