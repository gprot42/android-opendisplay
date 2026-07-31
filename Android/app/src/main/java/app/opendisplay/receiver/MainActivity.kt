package app.opendisplay.receiver

import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Bundle
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import app.opendisplay.receiver.compat.DeviceReport
import app.opendisplay.receiver.input.TouchMapper
import app.opendisplay.receiver.net.NsdAdvertiser
import app.opendisplay.receiver.net.PanelInfo
import app.opendisplay.receiver.net.ReceiverServer
import app.opendisplay.receiver.net.ReceiverUiState
import app.opendisplay.receiver.protocol.WireProtocol
import app.opendisplay.receiver.ui.CursorOverlayView
import app.opendisplay.receiver.video.H264Decoder
import kotlinx.coroutines.flow.MutableStateFlow

class MainActivity : ComponentActivity() {
    private lateinit var decoder: H264Decoder
    private lateinit var server: ReceiverServer
    private lateinit var nsd: NsdAdvertiser
    private lateinit var touchMapper: TouchMapper
    private val uiState = MutableStateFlow(ReceiverUiState())

    /** Bound when the video view is inflated; cursor updates post to it. */
    @Volatile private var cursorView: CursorOverlayView? = null
    @Volatile private var videoView: TextureView? = null
    @Volatile private var videoSurface: Surface? = null
    @Volatile private var latestViewport: TouchMapper.Viewport = TouchMapper.Viewport()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val app = application as OpenDisplayApp
        val deviceInfo = DeviceReport.collect()
        DeviceReport.logOnce()
        if (!deviceInfo.hasAvcDecoder) {
            uiState.value = uiState.value.copy(
                status = "No H.264 decoder on this device — cannot stream",
                deviceSummary = deviceInfo.summaryLine(),
            )
        } else {
            uiState.value = uiState.value.copy(deviceSummary = deviceInfo.summaryLine())
        }

        decoder = H264Decoder(
            onNeedKeyframe = {
                if (::server.isInitialized) server.requestKeyframe()
            },
            onVideoSize = { w, h ->
                if (::server.isInitialized) server.onVideoSize(w, h)
                if (::touchMapper.isInitialized) touchMapper.setVideoSize(w, h)
            },
        )
        server = ReceiverServer(
            installId = app.installId,
            onState = { next ->
                uiState.value = next.copy(
                    deviceSummary = next.deviceSummary.ifEmpty { deviceInfo.summaryLine() },
                )
            },
            decoder = decoder,
            onCursor = { x, y, visible ->
                // Mac cursor is full-desktop normalized. When zoomed, the stream
                // is ROI-cropped to contentX/Y/W/H, so remap into that rect.
                val vp = latestViewport
                if (vp.scale <= 1.05f || vp.contentW <= 0.001f || vp.contentH <= 0.001f) {
                    cursorView?.setCursorPosition(x, y, visible)
                } else {
                    val lx = (x - vp.contentX) / vp.contentW
                    val ly = (y - vp.contentY) / vp.contentH
                    val inView = lx in -0.05..1.05 && ly in -0.05..1.05
                    cursorView?.setCursorPosition(
                        lx.coerceIn(0.0, 1.0),
                        ly.coerceIn(0.0, 1.0),
                        visible && inView,
                    )
                }
            },
            onCursorImage = { png, nw, nh, ax, ay ->
                val vp = latestViewport
                if (vp.scale <= 1.05f || vp.contentW <= 0.001f || vp.contentH <= 0.001f) {
                    cursorView?.setCursorSprite(png, nw, nh, ax, ay)
                } else {
                    cursorView?.setCursorSprite(
                        png,
                        nw / vp.contentW.toDouble(),
                        nh / vp.contentH.toDouble(),
                        ax,
                        ay,
                    )
                }
            },
            onCursorReset = {
                cursorView?.clear()
            },
        )
        touchMapper = TouchMapper(this, server) { viewport ->
            latestViewport = viewport
            // Instant local pinch for feedback. The Mac ROI-crops capture to
            // the same rect and re-encodes at full stream resolution, so after
            // ~1 RTT the magnified region has real pixels (not just upscale).
            // Local scale is eased so we don't fully double-zoom the ROI feed.
            applyViewport(viewport)
        }
        nsd = NsdAdvertiser(this)

        val defaultName = Build.MODEL.ifBlank { "OpenDisplay" }
        server.setServiceName(defaultName)
        updatePanelFromDisplay()
        server.start(WireProtocol.DEFAULT_PORT)
        nsd.register(defaultName, WireProtocol.DEFAULT_PORT, app.installId)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                val state by uiState.collectAsState()
                ReceiverScreen(
                    state = state,
                    onBindViews = { texture, cursor ->
                        videoView = texture
                        cursorView = cursor
                        applyViewport(touchMapper.viewport())
                    },
                    onSurfaceReady = { surface ->
                        videoSurface?.release()
                        videoSurface = surface
                        decoder.setSurface(surface)
                    },
                    onSurfaceDestroyed = {
                        decoder.setSurface(null)
                        videoSurface?.release()
                        videoSurface = null
                    },
                    onTouch = { event, w, h -> touchMapper.onTouch(event, w, h) },
                    onPanelMetrics = { w, h, scale ->
                        server.updatePanel(PanelInfo(w, h, scale))
                    },
                )
            }
        }

        lifecycle.addObserver(
            LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_STOP -> server.announceSleeping()
                    Lifecycle.Event.ON_DESTROY -> {
                        server.announceClosing()
                        nsd.unregister()
                        server.stop()
                        videoSurface?.release()
                        videoSurface = null
                    }
                    else -> Unit
                }
            },
        )
    }

    private fun applyViewport(viewport: TouchMapper.Viewport) {
        val video = videoView ?: return
        val cursor = cursorView
        // Soft local scale: full response near 1× for snappy pinch; asymptote
        // toward ~1.2× as logical zoom grows, because the Mac ROI stream
        // already supplies the rest of the magnification as real pixels.
        val local = softLocalScale(viewport.scale)
        val panScale = if (viewport.scale > 1.01f) local / viewport.scale else 1f
        for (v in listOfNotNull(video, cursor)) {
            v.pivotX = v.width / 2f
            v.pivotY = v.height / 2f
            v.scaleX = local
            v.scaleY = local
            v.translationX = viewport.panX * panScale
            v.translationY = viewport.panY * panScale
        }
    }

    /**
     * Brief local magnification for pinch feedback. Kept small because the Mac
     * ROI stream already carries most of the zoom as real pixels; large local
     * scale would double-zoom and reintroduce softness.
     */
    private fun softLocalScale(logical: Float): Float {
        if (logical <= 1.01f) return 1f
        // z=1.5 → ~1.12; z=2 → ~1.15; z=4 → ~1.18 (cap 1.2)
        val t = ((logical - 1f) / 3f).coerceIn(0f, 1f)
        return 1f + 0.2f * t
    }

    private fun updatePanelFromDisplay() {
        val metrics = resources.displayMetrics
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        val scale = metrics.density.toDouble()
        server.updatePanel(PanelInfo(w, h, scale))
    }

    fun setImmersiveMode(enabled: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (enabled) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }
}

@Composable
private fun ReceiverScreen(
    state: ReceiverUiState,
    onBindViews: (TextureView?, CursorOverlayView?) -> Unit,
    onSurfaceReady: (Surface) -> Unit,
    onSurfaceDestroyed: () -> Unit,
    onTouch: (android.view.MotionEvent, Int, Int) -> Boolean,
    onPanelMetrics: (widthPx: Int, heightPx: Int, scale: Double) -> Unit,
) {
    val activity = LocalContext.current as? MainActivity
    DisposableEffect(state.streaming) {
        activity?.setImmersiveMode(state.streaming || state.connected)
        onDispose { }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { context ->
                val match = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                FrameLayout(context).apply {
                    layoutParams = match
                    val texture = TextureView(context).apply {
                        layoutParams = FrameLayout.LayoutParams(match)
                        surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                            override fun onSurfaceTextureAvailable(
                                surface: SurfaceTexture,
                                width: Int,
                                height: Int,
                            ) {
                                onSurfaceReady(Surface(surface))
                                val density = resources.displayMetrics.density
                                onPanelMetrics(width, height, density.toDouble())
                            }

                            override fun onSurfaceTextureSizeChanged(
                                surface: SurfaceTexture,
                                width: Int,
                                height: Int,
                            ) {
                                val density = resources.displayMetrics.density
                                onPanelMetrics(width, height, density.toDouble())
                            }

                            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                                onSurfaceDestroyed()
                                // We release the Surface wrapper ourselves.
                                return true
                            }

                            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
                        }
                    }
                    val cursor = CursorOverlayView(context).apply {
                        layoutParams = FrameLayout.LayoutParams(match)
                        isClickable = false
                        isFocusable = false
                    }
                    addView(texture)
                    addView(cursor)
                    onBindViews(texture, cursor)

                    setOnTouchListener { v, event ->
                        val handled = onTouch(event, v.width, v.height)
                        if (handled) v.performClick()
                        handled
                    }
                }
            },
            onRelease = {
                onBindViews(null, null)
            },
        )

        if (!state.streaming) {
            IdleOverlay(state)
        }
    }
}

@Composable
private fun IdleOverlay(state: ReceiverUiState) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xCC000000))
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "OpenDisplay",
            color = Color.White,
            fontSize = 32.sp,
            style = MaterialTheme.typography.headlineMedium,
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = state.status,
            color = Color(0xFFB0B0B0),
            fontSize = 18.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(24.dp))
        Text(
            text = "Port ${state.port}",
            color = Color.White,
            fontFamily = FontFamily.Monospace,
            fontSize = 16.sp,
        )
        if (state.localAddresses.isNotEmpty()) {
            Spacer(modifier = Modifier.height(8.dp))
            state.localAddresses.forEach { ip ->
                Text(
                    text = "$ip:${state.port}",
                    color = Color(0xFF8AB4F8),
                    fontFamily = FontFamily.Monospace,
                    fontSize = 18.sp,
                )
            }
        }
        Spacer(modifier = Modifier.height(24.dp))
        Text(
            text = "On your Mac: open OpenDisplay → connect over WiFi,\nor use manual host with an address above.",
            color = Color(0xFF9E9E9E),
            fontSize = 14.sp,
            textAlign = TextAlign.Center,
            lineHeight = 20.sp,
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = "Pinch to zoom (higher quality while zoomed) · double-tap to reset · two-finger pan scrolls",
            color = Color(0xFF6E6E6E),
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "Advertised as \"${state.serviceName}\"",
            color = Color(0xFF6E6E6E),
            fontSize = 12.sp,
        )
        if (state.deviceSummary.isNotEmpty()) {
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = state.deviceSummary,
                color = Color(0xFF555555),
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                textAlign = TextAlign.Center,
            )
        }
    }
}
