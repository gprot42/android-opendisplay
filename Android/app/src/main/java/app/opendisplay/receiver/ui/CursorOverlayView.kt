package app.opendisplay.receiver.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.util.AttributeSet
import android.util.Base64
import android.view.View
import kotlin.math.max

/**
 * Draws the Mac's local cursor echo (position + optional PNG sprite).
 *
 * The Mac hides the system cursor from ScreenCaptureKit and streams:
 * - `cursor`   — normalized [0,1] position at ~120Hz
 * - `cursorImg` — PNG sprite + normalized size/hotspot when shape changes
 *
 * Updates are applied on the UI thread without going through Compose so
 * 120Hz moves stay cheap.
 */
class CursorOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val drawMatrix = Matrix()

    private var sprite: Bitmap? = null
    private var normX = 0.5
    private var normY = 0.5
    private var visible = false

    /** Sprite size as fraction of the video/view (Mac display points / display size). */
    private var normW = 0.0
    private var normH = 0.0

    /** Hotspot as fraction of sprite size (0,0 = top-left of sprite). */
    private var anchorX = 0.0
    private var anchorY = 0.0

    init {
        // Let touches pass through to the SurfaceView underneath.
        isClickable = false
        isFocusable = false
        setWillNotDraw(false)
    }

    fun setCursorPosition(x: Double, y: Double, isVisible: Boolean) {
        normX = x
        normY = y
        visible = isVisible
        invalidate()
    }

    fun setCursorSprite(pngBase64: String, nw: Double, nh: Double, ax: Double, ay: Double) {
        try {
            val bytes = Base64.decode(pngBase64, Base64.DEFAULT)
            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bmp != null) {
                sprite?.recycle()
                sprite = bmp
                normW = nw
                normH = nh
                anchorX = ax
                anchorY = ay
                invalidate()
            }
        } catch (_: Exception) {
            // Ignore corrupt sprites — keep last good one.
        }
    }

    fun clear() {
        visible = false
        sprite?.recycle()
        sprite = null
        normW = 0.0
        normH = 0.0
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (!visible) return
        val bmp = sprite
        val vw = width.toFloat()
        val vh = height.toFloat()
        if (vw <= 0f || vh <= 0f) return

        // Hotspot lands on (normX, normY) in view space.
        val hotX = (normX * vw).toFloat()
        val hotY = (normY * vh).toFloat()

        if (bmp != null && normW > 0.0 && normH > 0.0) {
            val drawW = max(1f, (normW * vw).toFloat())
            val drawH = max(1f, (normH * vh).toFloat())
            val left = hotX - (anchorX * drawW).toFloat()
            val top = hotY - (anchorY * drawH).toFloat()
            drawMatrix.reset()
            drawMatrix.postScale(drawW / bmp.width, drawH / bmp.height)
            drawMatrix.postTranslate(left, top)
            canvas.drawBitmap(bmp, drawMatrix, paint)
        } else {
            // Fallback arrow if the sprite hasn't arrived yet.
            drawFallbackPointer(canvas, hotX, hotY)
        }
    }

    private fun drawFallbackPointer(canvas: Canvas, x: Float, y: Float) {
        val scale = resources.displayMetrics.density
        val path = android.graphics.Path().apply {
            moveTo(x, y)
            lineTo(x, y + 16f * scale)
            lineTo(x + 4f * scale, y + 12f * scale)
            lineTo(x + 8f * scale, y + 20f * scale)
            lineTo(x + 10f * scale, y + 19f * scale)
            lineTo(x + 6f * scale, y + 11f * scale)
            lineTo(x + 11f * scale, y + 11f * scale)
            close()
        }
        paint.color = 0xFFFFFFFF.toInt()
        paint.style = Paint.Style.FILL
        canvas.drawPath(path, paint)
        paint.color = 0xFF000000.toInt()
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = scale
        canvas.drawPath(path, paint)
        paint.style = Paint.Style.FILL
    }
}
