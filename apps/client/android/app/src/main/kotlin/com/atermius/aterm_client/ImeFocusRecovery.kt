package com.atermius.aterm_client

import android.os.SystemClock
import android.view.View
import android.view.inputmethod.InputMethodManager
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * The system IME picker can return focus before Flutter's editor is ready.
 * Android may dismiss the keyboard in that gap. Some Gboard languages are
 * managed inside Gboard, so changing one does not always change the Android
 * subtype. Recover only across a focus interruption of this resumed activity,
 * when it had a visible IME before and still has an active editor afterward.
 */
internal class ImeFocusRecovery(private val input: InputMethodManager) {
    private var hadVisibleIme = false
    private var retryView: View? = null
    private var deadline = 0L
    private val retry = Runnable { restore() }

    fun focusChanged(view: View, focused: Boolean) {
        if (!focused) {
            cancel()
            hadVisibleIme = imeVisible(view)
        } else if (hadVisibleIme) {
            retryView = view
            deadline = SystemClock.uptimeMillis() + 1_000
            // Allow the editor to reconnect and the system's hide to finish.
            view.postDelayed(retry, 350)
        }
    }

    fun cancel() {
        retryView?.removeCallbacks(retry)
        retryView = null
        hadVisibleIme = false
    }

    private fun restore() {
        val view = retryView ?: return
        if (!view.hasWindowFocus() || !view.hasFocus()) {
            cancel()
            return
        }
        if (input.isActive(view) && input.isAcceptingText) {
            // A hide can still be animating even though its request has
            // already taken effect, so visibility here is not authoritative.
            input.showSoftInput(view, 0)
            cancel()
        } else if (SystemClock.uptimeMillis() < deadline) {
            view.postDelayed(retry, 50)
        } else {
            cancel()
        }
    }

    private fun imeVisible(view: View) =
        ViewCompat.getRootWindowInsets(view)?.isVisible(WindowInsetsCompat.Type.ime()) == true
}
