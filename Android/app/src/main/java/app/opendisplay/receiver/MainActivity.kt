package app.opendisplay.receiver

import android.content.Intent
import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
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
import app.opendisplay.receiver.net.DiscoveryProbe
import app.opendisplay.receiver.net.MacHostBrowser
import app.opendisplay.receiver.net.NsdAdvertiser
import app.opendisplay.receiver.net.PanelInfo
import app.opendisplay.receiver.net.ReceiverServer
import app.opendisplay.receiver.net.ReceiverUiState
import app.opendisplay.receiver.net.WifiNetworkHolder
import app.opendisplay.receiver.protocol.WireProtocol
import app.opendisplay.receiver.ui.CursorOverlayView
import app.opendisplay.receiver.video.H264Decoder
import kotlinx.coroutines.flow.MutableStateFlow

class MainActivity : ComponentActivity() {
    private lateinit var decoder: H264Decoder
    private lateinit var server: ReceiverServer
    private lateinit var nsd: NsdAdvertiser
    private lateinit var discoveryProbe: DiscoveryProbe
    private var macHostBrowser: MacHostBrowser? = null
    private lateinit var touchMapper: TouchMapper
    private val uiState = MutableStateFlow(ReceiverUiState())
    private var connectionMode: ConnectionMode = ConnectionMode.NETWORK

    /** Bound when the video view is inflated; cursor updates post to it. */
    @Volatile private var cursorView: CursorOverlayView? = null
    @Volatile private var videoView: TextureView? = null
    @Volatile private var videoSurface: Surface? = null
    /** Keeps decode alive while the activity is stopped (home / recents). */
    @Volatile private var holdSurfaceTexture: SurfaceTexture? = null
    @Volatile private var holdSurface: Surface? = null
    @Volatile private var latestViewport: TouchMapper.Viewport = TouchMapper.Viewport()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val app = application as OpenDisplayApp
        connectionMode = ConnectionMode.load(this)
        // Hold a Wi‑Fi Network for this process early — outbound reverse dial
        // needs it (GrapheneOS often has activeNetwork=null until requested).
        WifiNetworkHolder.start(this)
        val deviceInfo = DeviceReport.collect()
        DeviceReport.logOnce()
        if (!deviceInfo.hasAvcDecoder) {
            uiState.value = uiState.value.copy(
                status = "No H.264 decoder on this device — cannot stream",
                deviceSummary = deviceInfo.summaryLine(),
                connectionMode = connectionMode.name,
            )
        } else {
            uiState.value = uiState.value.copy(
                deviceSummary = deviceInfo.summaryLine(),
                connectionMode = connectionMode.name,
            )
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
            context = this,
            installId = app.installId,
            onState = { next ->
                uiState.value = next.copy(
                    deviceSummary = next.deviceSummary.ifEmpty { deviceInfo.summaryLine() },
                    connectionMode = connectionMode.name,
                )
                // Re-bind the live TextureView after a reconnect so the decoder
                // has a Surface even if a prior session cleared codec state.
                if (next.connected) {
                    videoSurface?.let { surface ->
                        if (surface.isValid) decoder.setSurface(surface)
                    }
                }
            },
            decoder = decoder,
            onCursor = { x, y, visible ->
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
            applyViewport(viewport)
        }
        nsd = NsdAdvertiser(this)
        discoveryProbe = DiscoveryProbe(
            context = this,
            installId = app.installId,
            serviceName = { uiState.value.serviceName.ifBlank { Build.MODEL.ifBlank { "OpenDisplay" } } },
            tcpPort = { WireProtocol.DEFAULT_PORT },
        )
        // When the Mac cannot dial us (AP isolation), it advertises reverse host
        // and we dial the Mac instead.
        macHostBrowser = MacHostBrowser(this) { host, port, name ->
            runOnUiThread {
                if (!::server.isInitialized) return@runOnUiThread
                server.connectOutbound(host, port)
            }
        }

        val defaultName = Build.MODEL.ifBlank { "OpenDisplay" }
        server.setServiceName(defaultName)
        updatePanelFromDisplay()
        server.start(WireProtocol.DEFAULT_PORT)
        discoveryProbe.start() // UDP multicast signature on :9010
        macHostBrowser?.start()
        applyConnectionMode(connectionMode)
        ReceiverForegroundService.start(this)

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                val state by uiState.collectAsState()
                ReceiverScreen(
                    state = state,
                    onConnectionMode = { mode -> setConnectionMode(mode) },
                    onBindViews = { texture, cursor ->
                        videoView = texture
                        cursorView = cursor
                        applyViewport(touchMapper.viewport())
                    },
                    onSurfaceReady = { surface ->
                        releaseHoldSurface()
                        videoSurface?.release()
                        videoSurface = surface
                        decoder.setSurface(surface)
                    },
                    onSurfaceDestroyed = {
                        // Keep decoding into an off-screen surface so the Mac
                        // session survives home / recents (foreground service).
                        attachHoldSurface()
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
                    // Do NOT announce sleeping on ON_STOP — the foreground
                    // service keeps the TCP session for a real second-monitor.
                    Lifecycle.Event.ON_START -> {
                        // Always listen on :9000 and re-advertise when visible —
                        // USB mode still accepts network dials (adb forward and Wi‑Fi).
                        ensureListeningAndAdvertising()
                        macHostBrowser?.start()
                    }
                    Lifecycle.Event.ON_DESTROY -> {
                        if (!isChangingConfigurations) {
                            server.announceClosing()
                            nsd.unregister()
                            if (::discoveryProbe.isInitialized) discoveryProbe.stop()
                            macHostBrowser?.stop()
                            macHostBrowser = null
                            WifiNetworkHolder.stop()
                            server.stop()
                            ReceiverForegroundService.stop(this)
                            releaseHoldSurface()
                            videoSurface?.release()
                            videoSurface = null
                        }
                    }
                    else -> Unit
                }
            },
        )
    }

    private fun setConnectionMode(mode: ConnectionMode) {
        if (mode == connectionMode) return
        connectionMode = mode
        ConnectionMode.save(this, mode)
        uiState.value = uiState.value.copy(connectionMode = mode.name)
        applyConnectionMode(mode)
    }

    /**
     * Mode is a **hint for the user / Mac preference** only.
     * The TCP server always listens on port 9000 for both USB (adb forward)
     * and Wi‑Fi so the Mac can use either path while the app is open.
     */
    private fun applyConnectionMode(mode: ConnectionMode) {
        ensureListeningAndAdvertising()
        // Keep mode in UI state for idle copy; do not tear down the listener.
        uiState.value = uiState.value.copy(connectionMode = mode.name)
    }

    /** Start (or keep) :9000 TCP + UDP probe + mDNS so Network and USB both work. */
    private fun ensureListeningAndAdvertising() {
        if (!::server.isInitialized) return
        // start() is a no-op if already running — never stop for mode switches.
        server.start(WireProtocol.DEFAULT_PORT)
        if (::discoveryProbe.isInitialized) {
            discoveryProbe.start()
        }
        if (::nsd.isInitialized) {
            val name = Build.MODEL.ifBlank { "OpenDisplay" }
            val app = application as OpenDisplayApp
            nsd.register(name, WireProtocol.DEFAULT_PORT, app.installId)
        }
    }

    private fun attachHoldSurface() {
        if (holdSurface != null) {
            decoder.setSurface(holdSurface)
            return
        }
        val st = SurfaceTexture(0)
        st.setDefaultBufferSize(16, 16)
        val surface = Surface(st)
        holdSurfaceTexture = st
        holdSurface = surface
        decoder.setSurface(surface)
    }

    private fun releaseHoldSurface() {
        decoder.setSurface(null)
        try {
            holdSurface?.release()
        } catch (_: Exception) {
        }
        try {
            holdSurfaceTexture?.release()
        } catch (_: Exception) {
        }
        holdSurface = null
        holdSurfaceTexture = null
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
    onConnectionMode: (ConnectionMode) -> Unit,
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
        // Keep the surface alive while idle so reconnect does not drop the
        // first keyframe. Alpha 0 + solid IdleOverlay hide any leftover frame
        // when the Mac stops sharing.
        AndroidView(
            modifier = Modifier
                .fillMaxSize()
                .then(
                    if (state.streaming) Modifier else Modifier.alpha(0f),
                ),
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
            IdleOverlay(state, onConnectionMode)
        }
    }
}

@Composable
private fun IdleOverlay(
    state: ReceiverUiState,
    onConnectionMode: (ConnectionMode) -> Unit,
) {
    val context = LocalContext.current
    val mode = ConnectionMode.entries.firstOrNull { it.name == state.connectionMode }
        ?: ConnectionMode.NETWORK
    var showVpnHelp by remember { mutableStateOf(false) }

    if (showVpnHelp) {
        VpnKillSwitchHelpDialog(
            onDismiss = { showVpnHelp = false },
            onOpenSettings = {
                showVpnHelp = false
                openVpnSettings(context)
            },
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            // Fully opaque: never show a leftover stream frame behind the menu.
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
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
        Spacer(modifier = Modifier.height(20.dp))
        ConnectionModePicker(selected = mode, onSelect = onConnectionMode)
        Spacer(modifier = Modifier.height(20.dp))
        Text(
            text = "Port ${state.port}",
            color = Color.White,
            fontFamily = FontFamily.Monospace,
            fontSize = 16.sp,
        )
        // Always show LAN addresses — port 9000 stays open in both modes.
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
        Spacer(modifier = Modifier.height(16.dp))
        when (mode) {
            ConnectionMode.NETWORK -> {
                Text(
                    text = "Same Wi‑Fi as your Mac. OpenDisplay → pick this device,\nor Connect over network with an address above.\nAlso works with USB (adb) at the same time.",
                    color = Color(0xFF9E9E9E),
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    lineHeight = 20.sp,
                )
            }
            ConnectionMode.USB -> {
                Text(
                    text = "Listening on port ${state.port} (USB + Wi‑Fi).\n\n" +
                        "USB (recommended, keeps Mac internet):\n" +
                        "1. Enable USB debugging\n" +
                        "2. Plug into the Mac · accept prompt\n" +
                        "3. Mac OpenDisplay → Android USB\n\n" +
                        "Wi‑Fi still works: use the IP above or discovery.",
                    color = Color(0xFF9E9E9E),
                    fontSize = 14.sp,
                    textAlign = TextAlign.Center,
                    lineHeight = 20.sp,
                )
            }
        }
        Spacer(modifier = Modifier.height(20.dp))
        // Apps cannot flip the OS kill switch; open Settings and show steps.
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.92f)
                .clickable(role = Role.Button) { showVpnHelp = true },
            color = Color(0xFF2A2A2A),
            shape = MaterialTheme.shapes.small,
        ) {
            Column(
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = "Can't connect over Wi‑Fi?",
                    color = Color.White,
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "GrapheneOS VPN lockdown · turn off\n" +
                        "“Block connections without VPN”",
                    color = Color(0xFFFBBF24),
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    lineHeight = 18.sp,
                )
            }
        }
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = "Pinch to zoom · double-tap reset · stays on in background",
            color = Color(0xFF6E6E6E),
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            text = "Advertised as \"${state.serviceName}\" · always on :${state.port}",
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

/**
 * GrapheneOS enables Always-on VPN and “Block connections without VPN”
 * (lockdown) when any VPN is first set up. Lockdown blocks LAN peer TCP
 * even if the tunnel looks disconnected. Apps cannot clear it.
 */
@Composable
private fun VpnKillSwitchHelpDialog(
    onDismiss: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(text = "Wi‑Fi blocked by VPN lockdown")
        },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text = VPN_LOCKDOWN_HELP_TEXT,
                    lineHeight = 20.sp,
                    fontSize = 14.sp,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onOpenSettings) {
                Text("Open VPN settings")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        },
    )
}

/**
 * User-facing copy for GrapheneOS / Android VPN lockdown.
 * Keep lines short for readability on tablets and phones.
 */
private const val VPN_LOCKDOWN_HELP_TEXT =
    "If Wi‑Fi fails but USB / adb reverse works, " +
        "the OS VPN lockdown is usually still on.\n\n" +
        "GrapheneOS turns these ON by default " +
        "the first time you set up any VPN:\n\n" +
        "• Always-on VPN — keeps that VPN selected\n" +
        "• Block connections without VPN — kill switch\n\n" +
        "The second toggle is what blocks LAN " +
        "(Mac ↔ tablet TCP). It still blocks " +
        "even when ExpressVPN / Nord / WireGuard " +
        "looks disconnected.\n\n" +
        "Fix (required for pure Wi‑Fi):\n\n" +
        "1. Settings → Network & internet → VPN\n" +
        "2. Tap the gear on each listed VPN\n" +
        "3. Turn OFF “Block connections without VPN”\n" +
        "4. Optionally turn Always-on off too\n" +
        "5. Toggle Wi‑Fi, then Connect over network\n\n" +
        "Also enable Allow LAN / turn off Network " +
        "Lock inside the VPN app if present.\n\n" +
        "This app cannot flip those toggles " +
        "(only you or a device admin can).\n\n" +
        "USB + adb reverse still works under " +
        "lockdown because the tablet dials " +
        "127.0.0.1, not your Mac’s LAN IP."

private fun openVpnSettings(context: android.content.Context) {
    val intents = listOf(
        Intent(Settings.ACTION_VPN_SETTINGS),
        Intent(Settings.ACTION_WIRELESS_SETTINGS),
        Intent(Settings.ACTION_SETTINGS),
    )
    for (intent in intents) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
            return
        } catch (_: Exception) {
            // try next fallback
        }
    }
}

@Composable
private fun ConnectionModePicker(
    selected: ConnectionMode,
    onSelect: (ConnectionMode) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth(0.85f)
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ConnectionMode.entries.forEach { mode ->
            val active = mode == selected
            Surface(
                modifier = Modifier
                    .weight(1f)
                    .selectable(
                        selected = active,
                        onClick = { onSelect(mode) },
                        role = Role.RadioButton,
                    ),
                color = if (active) Color(0xFF3B82F6) else Color(0xFF2A2A2A),
                shape = MaterialTheme.shapes.small,
            ) {
                Text(
                    text = mode.label,
                    color = Color.White,
                    fontSize = 15.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(vertical = 10.dp),
                )
            }
        }
    }
}
