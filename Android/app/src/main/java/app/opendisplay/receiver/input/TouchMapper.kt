package app.opendisplay.receiver.input

import android.content.Context
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import app.opendisplay.receiver.net.ReceiverServer
import kotlin.math.abs

/**
 * Maps MotionEvents to OpenDisplay touch/scroll JSON (WIRE.md) and local
 * pinch-to-zoom of the video viewport.
 *
 * - At 1×: 1 finger = Mac click/drag; 2 fingers = Mac scroll
 * - Zoomed: 1 finger = pan viewport; pinch = zoom; double-tap = reset
 * - Pinch keeps content under the focus point; pan is never gated on
 *   ScaleGestureDetector (which otherwise blocks two-finger translate).
 */
class TouchMapper(
    context: Context,
    private val server: ReceiverServer,
    private val onViewportChanged: (Viewport) -> Unit = {},
) {
    data class Viewport(
        val scale: Float = 1f,
        /** Pan in view pixels (translation after scale around view center). */
        val panX: Float = 0f,
        val panY: Float = 0f,
    )

    private var videoWidth = 1920
    private var videoHeight = 1080
    private var viewWidth = 1
    private var viewHeight = 1

    private var scale = 1f
    private var panX = 0f
    private var panY = 0f

    /** Two-finger gesture active — suppress residual one-finger Mac clicks. */
    private var multiFinger = false

    /** One-finger pan of the zoomed viewport (not Mac drag). */
    private var panningViewport = false
    private var lastPanX = 0f
    private var lastPanY = 0f

    /** Two-finger midpoint tracking for pan / Mac scroll. */
    private var lastMidX = 0f
    private var lastMidY = 0f
    private var midInitialized = false

    /** True once this gesture sent Mac scroll (avoid phantom click on lift). */
    private var didMacScroll = false

    /** One-finger Mac drag in progress. */
    private var macDragging = false

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                multiFinger = true
                macDragging = false
                panningViewport = false
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val factor = detector.scaleFactor
                // Ignore tiny scale noise so pure pans don't fight the zoom.
                if (abs(factor - 1f) < 0.01f) return true

                val old = scale
                val next = (old * factor).coerceIn(MIN_SCALE, MAX_SCALE)
                if (next == old) return true

                val focusX = detector.focusX
                val focusY = detector.focusY
                val cx = viewWidth / 2f
                val cy = viewHeight / 2f
                val contentX = (focusX - cx - panX) / old + cx
                val contentY = (focusY - cy - panY) / old + cy
                scale = next
                panX = focusX - cx - (contentX - cx) * scale
                panY = focusY - cy - (contentY - cy) * scale
                clampPan()
                publishViewport()
                // Midpoint may jump during scale — resync.
                midInitialized = false
                return true
            }
        },
    ).also {
        // Span slop defaults are fine; quick scale helps tablets.
        it.isQuickScaleEnabled = false
    }

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean {
                resetViewport()
                return true
            }
        },
    )

    fun setVideoSize(width: Int, height: Int) {
        if (width > 0) videoWidth = width
        if (height > 0) videoHeight = height
    }

    fun resetViewport() {
        scale = 1f
        panX = 0f
        panY = 0f
        publishViewport()
    }

    fun viewport(): Viewport = Viewport(scale, panX, panY)

    fun onTouch(event: MotionEvent, viewW: Int, viewH: Int): Boolean {
        if (viewW <= 0 || viewH <= 0) return false
        viewWidth = viewW
        viewHeight = viewH

        gestureDetector.onTouchEvent(event)
        scaleDetector.onTouchEvent(event)

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                multiFinger = false
                didMacScroll = false
                panningViewport = false
                macDragging = false
                midInitialized = false

                if (isZoomed) {
                    // One-finger drag pans the local viewport.
                    panningViewport = true
                    lastPanX = event.x
                    lastPanY = event.y
                } else {
                    macDragging = true
                    sendMappedTouch(event, "began")
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                multiFinger = true
                macDragging = false
                panningViewport = false
                midInitialized = true
                lastMidX = midpointX(event)
                lastMidY = midpointY(event)
            }

            MotionEvent.ACTION_MOVE -> {
                when {
                    event.pointerCount >= 2 -> {
                        handleTwoFingerMove(event, viewW, viewH)
                    }
                    isZoomed && panningViewport -> {
                        val dx = event.x - lastPanX
                        val dy = event.y - lastPanY
                        lastPanX = event.x
                        lastPanY = event.y
                        if (abs(dx) >= 0.5f || abs(dy) >= 0.5f) {
                            panX += dx
                            panY += dy
                            clampPan()
                            publishViewport()
                        }
                    }
                    macDragging && !multiFinger -> {
                        sendMappedTouch(event, "moved")
                    }
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                // Still multi until all fingers up — avoid accidental click.
                multiFinger = event.pointerCount > 2
                midInitialized = false
                if (event.pointerCount == 2 && isZoomed) {
                    // One finger remains while zoomed → continue pan with it.
                    val idx = if (event.actionIndex == 0) 1 else 0
                    panningViewport = true
                    lastPanX = event.getX(idx)
                    lastPanY = event.getY(idx)
                }
            }

            MotionEvent.ACTION_UP -> {
                when {
                    macDragging && !multiFinger && !didMacScroll -> {
                        sendMappedTouch(event, "ended")
                    }
                    macDragging && multiFinger -> {
                        // Was cancelled by a second finger; no end event needed.
                    }
                }
                multiFinger = false
                panningViewport = false
                macDragging = false
                didMacScroll = false
                midInitialized = false
            }

            MotionEvent.ACTION_CANCEL -> {
                if (macDragging && !multiFinger && !didMacScroll) {
                    sendMappedTouch(event, "cancelled")
                }
                multiFinger = false
                panningViewport = false
                macDragging = false
                didMacScroll = false
                midInitialized = false
            }
        }
        return true
    }

    private fun handleTwoFingerMove(event: MotionEvent, viewW: Int, viewH: Int) {
        val mx = midpointX(event)
        val my = midpointY(event)
        if (!midInitialized) {
            lastMidX = mx
            lastMidY = my
            midInitialized = true
            return
        }
        val dx = mx - lastMidX
        val dy = my - lastMidY
        lastMidX = mx
        lastMidY = my
        if (abs(dx) < 0.5f && abs(dy) < 0.5f) return

        if (isZoomed) {
            // Always pan with two-finger translate when zoomed (independent of scale detector).
            panX += dx
            panY += dy
            clampPan()
            publishViewport()
        } else {
            // At 1×: two-finger drag = Mac scroll.
            didMacScroll = true
            val dxPx = dx / viewW * videoWidth
            val dyPx = dy / viewH * videoHeight
            if (dxPx != 0f || dyPx != 0f) {
                server.sendScroll(dxPx.toDouble(), dyPx.toDouble())
            }
        }
    }

    private val isZoomed: Boolean
        get() = scale > 1.01f

    private fun sendMappedTouch(event: MotionEvent, phase: String) {
        val (nx, ny) = screenToNormalized(event.x, event.y)
        server.sendTouch(phase, nx, ny)
    }

    /**
     * Inverse of viewport transform: screen → content-normalized [0,1].
     * View applies: pivot=center, scale, then translation (pan).
     */
    fun screenToNormalized(screenX: Float, screenY: Float): Pair<Double, Double> {
        val cx = viewWidth / 2f
        val cy = viewHeight / 2f
        val contentX = (screenX - cx - panX) / scale + cx
        val contentY = (screenY - cy - panY) / scale + cy
        val nx = (contentX / viewWidth).toDouble().coerceIn(0.0, 1.0)
        val ny = (contentY / viewHeight).toDouble().coerceIn(0.0, 1.0)
        return nx to ny
    }

    private fun clampPan() {
        if (scale <= 1.01f) {
            scale = 1f
            panX = 0f
            panY = 0f
            return
        }
        // With pivot at center: max translation exposes content edges.
        val maxPanX = viewWidth * (scale - 1f) / 2f
        val maxPanY = viewHeight * (scale - 1f) / 2f
        panX = panX.coerceIn(-maxPanX, maxPanX)
        panY = panY.coerceIn(-maxPanY, maxPanY)
    }

    private fun publishViewport() {
        onViewportChanged(Viewport(scale, panX, panY))
    }

    private fun midpointX(e: MotionEvent): Float =
        if (e.pointerCount >= 2) (e.getX(0) + e.getX(1)) / 2f else e.x

    private fun midpointY(e: MotionEvent): Float =
        if (e.pointerCount >= 2) (e.getY(0) + e.getY(1)) / 2f else e.y

    companion object {
        const val MIN_SCALE = 1f
        const val MAX_SCALE = 5f
    }
}
