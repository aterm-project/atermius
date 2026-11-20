package com.atermius.aterm_client

import android.app.Activity
import android.app.AppOpsManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.text.Html
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Text clipboard for Dart where Flutter's own reader falls short on Android
 * ("atermius/clipboard").
 *
 * Android has no clipboard permission an app can request. Since Android 10
 * only the focused app (or the keyboard) may read; otherwise there is simply
 * no clip. Android 12+ shows a "pasted from your clipboard" toast when an app
 * reads another app's clip, and the READ_CLIPBOARD app-op, which several
 * ROMs (MIUI/HyperOS, ColorOS, OriginOS) present as a "clipboard" permission
 * that defaults to ask or deny, can refuse reads. Flutter's reader reports all
 * of that as "no text", looks only at the first item, and also returns null
 * for an item that is HTML without plain text or a link copied as a URI.
 *
 * - "state" describes the primary clip without reading its content (no
 *   toast): focus, the app-op, whether there is a clip, its timestamp
 *   (API 26+: equal timestamps mean the same clip) and whether the copying
 *   app marked it sensitive (password managers do).
 * - "read" reads text from every item: plain text, else HTML as text, else a
 *   link. A content URI is opened only for a paste the user asked for and
 *   only with a read grant the copying app gave through the clipboard: a URI
 *   planted on the clipboard must never make Atermius, which may hold All
 *   files access, read a document on another app's behalf. Reads are capped
 *   at maxBytes and run off the main thread because a provider may be slow.
 *   The provider controls how long a URI read takes, so each runs on a
 *   thread of its own with a deadline ([URI_READ_TIMEOUT_MS]) after which
 *   its descriptor is closed: a stalled provider never holds up later
 *   reads (terminal paste, automatic remote-desktop sync).
 * - "changed" tells Dart that the primary clip changed while this activity
 *   has window focus (the listener is registered only then).
 * - "openSettings" opens this app's system settings page, where such a ROM
 *   keeps its clipboard permission.
 */
class ClipboardBridge(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "atermius/clipboard")
    private val clipboard = activity.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    /** URI reads still running, including ones abandoned after the deadline. */
    private val uriReads = AtomicInteger()
    private var listening = false
    private var closed = false
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        if (!closed) channel.invokeMethod("changed", null)
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "state" -> result.success(state())
                "read" -> {
                    val maxBytes = call.argument<Int>("maxBytes")
                    val uris = call.argument<Boolean>("uris") == true
                    if (maxBytes == null || maxBytes < 1) {
                        result.error("invalid_arguments", "Expected maxBytes", null)
                        return@setMethodCallHandler
                    }
                    // Window focus belongs to the main thread: sample it here.
                    val focused = activity.hasWindowFocus()
                    worker.execute {
                        val read = try {
                            read(maxBytes, uris, focused)
                        } catch (_: Exception) {
                            mapOf("status" to "noText")
                        }
                        main.post { if (!closed) result.success(read) }
                    }
                }
                "openSettings" -> result.success(openSettings())
                else -> result.notImplemented()
            }
        }
    }

    /** Listens for clip changes only while this activity has window focus. */
    fun focusChanged(focused: Boolean) {
        if (closed || focused == listening) return
        try {
            if (focused) clipboard.addPrimaryClipChangedListener(listener)
            else clipboard.removePrimaryClipChangedListener(listener)
            listening = focused
        } catch (_: RuntimeException) {
            // A failing clipboard service only disables change notifications.
        }
    }

    fun close() {
        focusChanged(false)
        closed = true
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    /**
     * False only when the READ_CLIPBOARD app-op is explicitly refused. Each
     * SDK level deprecates the other level's name for the same check.
     */
    @Suppress("DEPRECATION")
    private fun readAllowed(): Boolean = try {
        val ops = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            ops.unsafeCheckOpNoThrow(READ_CLIPBOARD_OP, Process.myUid(), activity.packageName)
        } else {
            ops.checkOpNoThrow(READ_CLIPBOARD_OP, Process.myUid(), activity.packageName)
        }
        // A ROM's own "ask" mode is left to the read itself.
        mode != AppOpsManager.MODE_IGNORED && mode != AppOpsManager.MODE_ERRORED
    } catch (_: RuntimeException) {
        true
    }

    private fun sensitive(description: ClipDescription?): Boolean =
        description?.extras?.getBoolean(EXTRA_IS_SENSITIVE, false) == true

    private fun stamp(description: ClipDescription?): Long? =
        if (description != null && Build.VERSION.SDK_INT >= 26) description.timestamp else null

    private fun state(): Map<String, Any?> {
        var description: ClipDescription? = null
        var hasClip = false
        try {
            description = clipboard.primaryClipDescription
            hasClip = description != null && clipboard.hasPrimaryClip()
        } catch (_: RuntimeException) {
            // SecurityException included: "no clip"; Dart asks again later.
        }
        return mapOf(
            "focused" to activity.hasWindowFocus(),
            "allowed" to readAllowed(),
            "hasClip" to hasClip,
            "stamp" to stamp(description),
            "sensitive" to sensitive(description),
        )
    }

    private fun read(maxBytes: Int, uris: Boolean, focused: Boolean): Map<String, Any?> {
        if (!focused) return mapOf("status" to "unfocused")
        if (!readAllowed()) return mapOf("status" to "denied")
        val clip: ClipData? = try {
            clipboard.primaryClip
        } catch (_: SecurityException) {
            return mapOf("status" to "denied")
        }
        if (clip == null) return mapOf("status" to "empty")
        val description = clip.description
        val extra = mapOf("stamp" to stamp(description), "sensitive" to sensitive(description))
        if (!uris && sensitive(description)) return extra + ("status" to "noText")
        val text = StringBuilder()
        var found = false
        for (i in 0 until clip.itemCount) {
            when (val item = itemText(clip.getItemAt(i), uris, maxBytes - text.length)) {
                null -> continue
                ItemText.TooLarge -> return extra + ("status" to "tooLarge")
                is ItemText.Found -> {
                    // Several items paste one per line, as in TextView.
                    if (found) text.append('\n')
                    // UTF-16 units never outnumber UTF-8 bytes. Dart
                    // checks the exact size of the returned text.
                    if (item.text.length > maxBytes - text.length) return extra + ("status" to "tooLarge")
                    text.append(item.text)
                    found = true
                }
            }
        }
        if (!found) return extra + ("status" to if (clip.itemCount == 0) "empty" else "noText")
        return extra + mapOf("status" to "text", "text" to text.toString())
    }

    private sealed interface ItemText {
        class Found(val text: CharSequence) : ItemText
        object TooLarge : ItemText
    }

    private fun itemText(item: ClipData.Item, uris: Boolean, budget: Int): ItemText? {
        item.text?.let { return ItemText.Found(it) }
        item.htmlText?.let { html ->
            // Markup is larger than its text, but parsing megabytes is not
            // worth it for a paste.
            if (html.length > MAX_HTML_CHARS) return ItemText.TooLarge
            val text = Html.fromHtml(html, Html.FROM_HTML_MODE_LEGACY).toString()
                .replace("￼", "")
                .trimEnd('\n')
            return ItemText.Found(text)
        }
        val uri = item.uri ?: return null
        return when (uri.scheme?.lowercase()) {
            null, "file", "android.resource" -> null
            "content" -> if (uris) contentText(uri, budget) else null
            // A link copied as a URI pastes as the link itself.
            else -> ItemText.Found(uri.toString())
        }
    }

    private fun contentText(uri: Uri, budget: Int): ItemText? {
        // Only an explicit grant counts (the clipboard gives one when the
        // copying app may read the URI itself); access Atermius has on its
        // own, such as All files access, does not.
        val granted = try {
            activity.checkUriPermission(
                uri, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION,
            ) == PackageManager.PERMISSION_GRANTED
        } catch (_: RuntimeException) {
            false
        }
        if (!granted) return null
        // A blocked read cannot be interrupted, and a binder call into the
        // provider not even by closing; such threads are left to finish on
        // their own, at most MAX_URI_READS of them.
        if (uriReads.incrementAndGet() > MAX_URI_READS) {
            uriReads.decrementAndGet()
            return null
        }
        val read = UriRead()
        val task = FutureTask<ItemText?>(Callable { read.run(uri, budget) })
        try {
            Thread({
                try {
                    task.run()
                } finally {
                    uriReads.decrementAndGet()
                }
            }, "atermius-clipboard-uri").apply { isDaemon = true }.start()
        } catch (_: Throwable) {
            uriReads.decrementAndGet()
            return null
        }
        return try {
            task.get(URI_READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
            // Timed out, failed, or close() interrupted the worker. Closing
            // the descriptor fails a pipe read blocked in the provider.
            read.abandon()
            task.cancel(true)
            null
        }
    }

    /** One content URI read on its own thread; [abandon] may come from another. */
    private inner class UriRead {
        private var descriptor: AssetFileDescriptor? = null // guarded by this
        private var abandoned = false // guarded by this

        fun run(uri: Uri, budget: Int): ItemText? = try {
            val opened = activity.contentResolver.openTypedAssetFileDescriptor(uri, "text/*", null)
            if (opened == null || !adopt(opened)) {
                null
            } else {
                opened.use { readText(it, budget) }
            }
        } catch (_: Exception) {
            // Gone, not text, the provider refused, or abandoned meanwhile.
            null
        }

        @Synchronized
        private fun adopt(opened: AssetFileDescriptor): Boolean {
            if (abandoned) {
                closeQuietly(opened)
                return false
            }
            descriptor = opened
            return true
        }

        @Synchronized
        fun abandon() {
            abandoned = true
            descriptor?.let { closeQuietly(it) }
            descriptor = null
        }

        private fun closeQuietly(descriptor: AssetFileDescriptor) {
            try {
                descriptor.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun readText(descriptor: AssetFileDescriptor, budget: Int): ItemText {
        descriptor.createInputStream().use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > budget) return ItemText.TooLarge
            }
            return ItemText.Found(
                StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPLACE)
                    .onUnmappableCharacter(CodingErrorAction.REPLACE)
                    .decode(ByteBuffer.wrap(out.toByteArray()))
                    .toString()
            )
        }
    }

    private fun openSettings(): Boolean = try {
        activity.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
        )
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }

    companion object {
        private const val READ_CLIPBOARD_OP = "android:read_clipboard"
        private const val MAX_HTML_CHARS = 4 * 1024 * 1024
        /** Below Dart's 5 s read timeout, so the reader still answers in time. */
        private const val URI_READ_TIMEOUT_MS = 3000L
        private const val MAX_URI_READS = 2

        /** ClipDescription.EXTRA_IS_SENSITIVE (API 33); older apps set it too. */
        private const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
