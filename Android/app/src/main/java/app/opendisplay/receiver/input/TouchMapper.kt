package app.opendisplay.receiver.input

import android.view.MotionEvent
import app.opendisplay.receiver.net.ReceiverServer

/**
 * Maps MotionEvents to OpenDisplay touch/scroll JSON (WIRE.md).
 * Coordinates are normalized [0,1] in the view, origin top-left.
 */
class TouchMapper(
    private val server: ReceiverServer,
) {
    private var scrolling = false
    private var lastScrollX = 0f
    private var lastScrollY = 0f
    private var videoWidth = 1920
    private var videoHeight = 1080

    fun setVideoSize(width: Int, height: Int) {
        if (width > 0) videoWidth = width
        if (height > 0) videoHeight = height
    }

    fun onTouch(event: MotionEvent, viewWidth: Int, viewHeight: Int): Boolean {
        if (viewWidth <= 0 || viewHeight <= 0) return false

        when (event.pointerCount) {
            1 -> {
                if (scrolling) {
                    // End scroll gesture without emitting a phantom click.
                    scrolling = false
                    return true
                }
                val x = (event.x / viewWidth).toDouble().coerceIn(0.0, 1.0)
                val y = (event.y / viewHeight).toDouble().coerceIn(0.0, 1.0)
                val phase = when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> "began"
                    MotionEvent.ACTION_MOVE -> "moved"
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL ->
                        if (event.actionMasked == MotionEvent.ACTION_CANCEL) "cancelled" else "ended"
                    else -> return false
                }
                server.sendTouch(phase, x, y)
                return true
            }
            2 -> {
                when (event.actionMasked) {
                    MotionEvent.ACTION_POINTER_DOWN -> {
                        scrolling = true
                        lastScrollX = midpointX(event)
                        lastScrollY = midpointY(event)
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!scrolling) {
                            scrolling = true
                            lastScrollX = midpointX(event)
                            lastScrollY = midpointY(event)
                        } else {
                            val mx = midpointX(event)
                            val my = midpointY(event)
                            val dxPx = (mx - lastScrollX) / viewWidth * videoWidth
                            val dyPx = (my - lastScrollY) / viewHeight * videoHeight
                            lastScrollX = mx
                            lastScrollY = my
                            // Natural scrolling: finger moves content with it.
                            if (dxPx != 0f || dyPx != 0f) {
                                server.sendScroll(dxPx.toDouble(), dyPx.toDouble())
                            }
                        }
                    }
                    MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        scrolling = false
                    }
                }
                return true
            }
            else -> {
                scrolling = false
                return true
            }
        }
    }

    private fun midpointX(e: MotionEvent): Float = (e.getX(0) + e.getX(1)) / 2f
    private fun midpointY(e: MotionEvent): Float = (e.getY(0) + e.getY(1)) / 2f
}
