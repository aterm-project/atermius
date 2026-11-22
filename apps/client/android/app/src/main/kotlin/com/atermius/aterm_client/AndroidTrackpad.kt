package com.atermius.aterm_client

import android.os.Build
import android.view.InputDevice
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Preserves Android trackpad input that Flutter would interpret as touchscreen contacts. */
internal class AndroidTrackpad(view: FlutterView, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "atermius/android_trackpad")
    private val pinching = mutableMapOf<Int, Boolean>()

    init {
        view.setOnTouchListener { _, event ->
            handleGesture(event) || asMouse(event, view::onTouchEvent)
        }
        view.setOnHoverListener { _, event -> asMouse(event, view::onGenericMotionEvent) }
        view.setOnGenericMotionListener { _, event -> asMouse(event, view::onGenericMotionEvent) }
    }

    private fun send(method: String, event: MotionEvent, vararg values: Double) {
        channel.invokeMethod(method, listOf(event.deviceId, event.eventTime) + values.toList())
    }

    private fun handleGesture(event: MotionEvent): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        val device = event.deviceId
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            if (pinching.remove(device) != null) send("end", event)
            val pinch = when (event.classification) {
                MotionEvent.CLASSIFICATION_PINCH -> true
                MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE -> false
                else -> return false
            }
            pinching[device] = pinch
            if (!pinch) send("start", event, event.x.toDouble(), event.y.toDouble())
            return true
        }
        val pinch = pinching[device] ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_POINTER_DOWN -> if (pinch && event.pointerCount == 2) {
                // Android's two synthetic contacts are symmetric around the cursor.
                send("start", event, (event.x + event.getX(1)) / 2.0, (event.y + event.getY(1)) / 2.0)
            }
            MotionEvent.ACTION_MOVE -> if (pinch) {
                val axis = MotionEvent.AXIS_GESTURE_PINCH_SCALE_FACTOR
                var scale = 1.0
                for (sample in 0 until event.historySize) {
                    val factor = event.getHistoricalAxisValue(axis, sample)
                    if (factor.isFinite() && factor > 0) scale *= factor
                }
                val factor = event.getAxisValue(axis)
                if (factor.isFinite() && factor > 0) scale *= factor
                if (scale.isFinite() && scale > 0 && scale != 1.0) send("pinch", event, scale)
            } else {
                send("pan", event, event.x.toDouble(), event.y.toDouble())
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                pinching.remove(device)
                send("end", event)
            }
        }
        return true
    }

    private fun asMouse(event: MotionEvent, dispatch: (MotionEvent) -> Boolean): Boolean {
        if (!event.isFromSource(InputDevice.SOURCE_MOUSE) || event.pointerCount != 1 ||
            event.getToolType(0) != MotionEvent.TOOL_TYPE_FINGER ||
            (Build.VERSION.SDK_INT >= 29 && event.classification != MotionEvent.CLASSIFICATION_NONE)) {
            return false
        }
        // Android uses a finger tool with a mouse source for cursor movement and
        // clicks from some touchpads. Keep the cursor position and mouse buttons.
        val properties = MotionEvent.PointerProperties().apply {
            event.getPointerProperties(0, this)
            toolType = MotionEvent.TOOL_TYPE_MOUSE
        }
        val coords = MotionEvent.PointerCoords().apply { event.getPointerCoords(0, this) }
        val mouse = MotionEvent.obtain(
            event.downTime, event.eventTime, event.action, 1, arrayOf(properties), arrayOf(coords),
            event.metaState, event.buttonState, event.xPrecision, event.yPrecision,
            event.deviceId, event.edgeFlags, event.source, event.flags,
        )
        return try {
            dispatch(mouse)
        } finally {
            mouse.recycle()
        }
    }
}
