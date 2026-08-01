package app.opendisplay.receiver.net

import android.os.Handler
import android.os.Looper
import android.util.Log
import app.opendisplay.receiver.audio.AudioPlayer
import app.opendisplay.receiver.protocol.WireMessage
import app.opendisplay.receiver.protocol.WireProtocol
import app.opendisplay.receiver.video.AnnexBParser
import app.opendisplay.receiver.video.H264Decoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

data class PanelInfo(
    val pixelsWide: Int,
    val pixelsHigh: Int,
    val scale: Double,
)

/** One-second metrics snapshot for the stats loop (thread-safe handoff). */
private data class StatsTick(
    val fps: Int,
    val mbps: Double,
    val stalls: Int,
    val e2e50: Double,
    val e2e95: Double,
    val enc50: Double,
)

data class ReceiverUiState(
    val status: String = "Starting…",
    val listening: Boolean = false,
    val connected: Boolean = false,
    val streaming: Boolean = false,
    val videoWidth: Int = 0,
    val videoHeight: Int = 0,
    val localAddresses: List<String> = emptyList(),
    val port: Int = WireProtocol.DEFAULT_PORT,
    val serviceName: String = "OpenDisplay",
    /** e.g. "Android 15 (API 35) · Pixel Tablet" for support reports. */
    val deviceSummary: String = "",
    /** Network (default) or USB cable path. */
    val connectionMode: String = "NETWORK",
)

/**
 * Listens on TCP (default 9000), accepts one Mac connection, speaks the
 * OpenDisplay wire protocol (WIRE.md).
 */
class ReceiverServer(
    private val installId: String,
    private val onState: (ReceiverUiState) -> Unit,
    private val decoder: H264Decoder,
    /** Mac local-cursor echo — invoked on the main thread. */
    private val onCursor: (x: Double, y: Double, visible: Boolean) -> Unit = { _, _, _ -> },
    private val onCursorImage: (pngBase64: String, nw: Double, nh: Double, ax: Double, ay: Double) -> Unit =
        { _, _, _, _, _ -> },
    private val onCursorReset: () -> Unit = {},
) {
    private val tag = "ReceiverServer"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val writeMutex = Mutex()
    private val lastDataMs = AtomicLong(0)
    private val clientSocket = AtomicReference<Socket?>(null)
    private val audioPlayer = AudioPlayer()

    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var panel = PanelInfo(1920, 1200, 2.0)
    @Volatile private var serviceName = "OpenDisplay"
    @Volatile private var port = WireProtocol.DEFAULT_PORT
    @Volatile private var running = false

    private var acceptJob: Job? = null
    private var sessionJob: Job? = null
    private var watchdogJob: Job? = null
    private var pingJob: Job? = null
    private var statsJob: Job? = null
    private var helloDebounceJob: Job? = null

    private var state = ReceiverUiState()

    // Clock sync (lowest-RTT sample, same as iOS PhoneReceiver).
    private val offsetSamples = ArrayList<Pair<Double, Double>>(16) // rtt → offset
    @Volatile private var clockOffsetMs: Double? = null
    @Volatile private var lastRttMs: Double = 0.0

    // Per-window stream health (reset each stats tick).
    private var windowStartMs = 0L
    private var framesThisWindow = 0
    private var bytesThisWindow = 0L
    private var stallsThisWindow = 0
    private var lastFrameAtMs = 0L
    // Session read thread + stats coroutine both touch these — guard access.
    private val metricsLock = Any()
    private val e2eWindow = ArrayList<Double>(64)
    private val encodeWindow = ArrayList<Double>(64)
    private var statsReportCounter = 0

    fun updatePanel(info: PanelInfo) {
        val changed = panel != info
        panel = info
        if (changed && state.connected) {
            // Debounce: orientation / surface size can fire several times in a
            // row; flooding the Mac with hello rebuilds drops the stream.
            helloDebounceJob?.cancel()
            helloDebounceJob = scope.launch {
                delay(250)
                if (state.connected) sendHello()
            }
        }
    }

    fun setServiceName(name: String) {
        serviceName = name.ifBlank { "OpenDisplay" }
        publish(state.copy(serviceName = serviceName))
    }

    fun start(port: Int = WireProtocol.DEFAULT_PORT) {
        if (running) return
        running = true
        this.port = port
        acceptJob = scope.launch { listenLoop() }
    }

    fun stop() {
        running = false
        acceptJob?.cancel()
        sessionJob?.cancel()
        watchdogJob?.cancel()
        pingJob?.cancel()
        statsJob?.cancel()
        try {
            clientSocket.getAndSet(null)?.close()
        } catch (_: Exception) {
        }
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        decoder.release()
        audioPlayer.release()
        scope.cancel()
        publish(
            state.copy(
                status = "Stopped",
                listening = false,
                connected = false,
                streaming = false,
            ),
        )
    }

    fun sendTouch(phase: String, x: Double, y: Double) {
        scope.launch {
            sendJson(
                JSONObject()
                    .put("type", WireMessage.TOUCH)
                    .put("phase", phase)
                    .put("x", x)
                    .put("y", y),
            )
        }
    }

    fun sendScroll(dx: Double, dy: Double) {
        scope.launch {
            sendJson(
                JSONObject()
                    .put("type", WireMessage.SCROLL)
                    .put("dx", dx)
                    .put("dy", dy),
            )
        }
    }

    fun announceSleeping() {
        scope.launch {
            sendJson(JSONObject().put("type", WireMessage.SLEEPING))
            closeClient("sleeping")
        }
    }

    fun announceClosing() {
        scope.launch {
            sendJson(JSONObject().put("type", WireMessage.CLOSING))
            closeClient("closing")
        }
    }

    fun requestKeyframe() {
        scope.launch {
            sendJson(JSONObject().put("type", WireMessage.KF))
        }
    }

    /**
     * Tell the Mac which fraction of the desktop is on screen (pinch-zoom).
     * Mac crops ScreenCaptureKit to that rect and encodes it at full stream
     * resolution so zoom stays sharp instead of magnifying compressed pixels.
     *
     * @param x,y top-left of visible region in normalized video space [0,1]
     * @param w,h size of visible region in normalized video space
     * @param z   pinch scale (≥ 1); used for bitrate boost
     */
    fun sendViewport(x: Double, y: Double, w: Double, h: Double, z: Double) {
        scope.launch {
            sendJson(
                JSONObject()
                    .put("type", WireMessage.VIEWPORT)
                    .put("x", x)
                    .put("y", y)
                    .put("w", w)
                    .put("h", h)
                    .put("z", z),
            )
        }
    }

    private suspend fun listenLoop() {
        while (scope.isActive && running) {
            try {
                // reuseAddress must be set BEFORE bind; ServerSocket(port) binds
                // immediately and the flag would be ignored — causing flaky
                // "address already in use" after a quick restart.
                val server = ServerSocket()
                server.reuseAddress = true
                server.bind(java.net.InetSocketAddress(port))
                // Accept both IPv4 and IPv6; Mac may dial either after Bonjour.
                serverSocket = server
                publish(
                    state.copy(
                        status = "Waiting for Mac…",
                        listening = true,
                        connected = false,
                        streaming = false,
                        localAddresses = localIpv4Addresses(),
                        port = port,
                        serviceName = serviceName,
                    ),
                )
                Log.i(tag, "listening on $port")

                while (scope.isActive && running) {
                    val socket = try {
                        server.accept()
                    } catch (e: SocketException) {
                        if (!running) break
                        throw e
                    }
                    // Single client: the newest dial wins. (Do not "sticky-reject"
                    // extras — if the Mac has already abandoned the old socket,
                    // rejecting the new one leaves a zombie session with no
                    // sender and a permanent connect/RST thrash.)
                    closeClient("replaced")
                    try {
                        socket.tcpNoDelay = true
                        socket.keepAlive = true
                        // Detect half-open peers faster on flaky Wi‑Fi.
                        socket.soTimeout = 0 // framing does blocking reads
                    } catch (_: Exception) {
                    }
                    clientSocket.set(socket)
                    sessionJob = scope.launch { runSession(socket) }
                }
            } catch (e: Exception) {
                if (!running) break
                Log.e(tag, "listen error", e)
                publish(state.copy(status = "Listen error: ${e.message}", listening = false))
                try {
                    serverSocket?.close()
                } catch (_: Exception) {
                }
                serverSocket = null
                delay(1_000)
            }
        }
    }

    private suspend fun runSession(socket: Socket) = withContext(Dispatchers.IO) {
        lastDataMs.set(System.currentTimeMillis())
        resetSessionMetrics()
        publish(
            state.copy(
                status = "Connected — sending hello",
                connected = true,
                streaming = false,
            ),
        )
        Log.i(tag, "session from ${socket.inetAddress?.hostAddress}")

        try {
            sendHello()
            startPing()
            startWatchdog()
            startStats()

            val input = BufferedInputStream(socket.getInputStream(), 256 * 1024)
            while (scope.isActive && !socket.isClosed) {
                val frame = FrameCodec.readFrame(input) ?: break
                lastDataMs.set(System.currentTimeMillis())
                handleInbound(frame)
            }
        } catch (e: Exception) {
            Log.i(tag, "session ended: ${e.message}")
        } finally {
            pingJob?.cancel()
            watchdogJob?.cancel()
            statsJob?.cancel()
            try {
                socket.close()
            } catch (_: Exception) {
            }
            if (clientSocket.get() === socket) clientSocket.set(null)
            mainHandler.post { onCursorReset() }
            // Keep the TextureView Surface bound — only tear down the codec.
            // setSurface(null) made reconnects stay black: SPS arrived with no
            // surface, configure returned early, UI never showed video.
            try {
                decoder.resetForNewSession()
            } catch (_: Exception) {
            }
            audioPlayer.stop()
            publish(
                state.copy(
                    status = "Waiting for Mac…",
                    connected = false,
                    streaming = false,
                    videoWidth = 0,
                    videoHeight = 0,
                ),
            )
        }
    }

    private fun resetSessionMetrics() {
        offsetSamples.clear()
        clockOffsetMs = null
        lastRttMs = 0.0
        windowStartMs = System.currentTimeMillis()
        synchronized(metricsLock) {
            framesThisWindow = 0
            bytesThisWindow = 0L
            stallsThisWindow = 0
            lastFrameAtMs = 0L
            e2eWindow.clear()
            encodeWindow.clear()
        }
        statsReportCounter = 0
    }

    private fun handleInbound(payload: ByteArray) {
        if (AnnexBParser.isJsonControl(payload)) {
            handleJson(payload.toString(Charsets.UTF_8))
            return
        }
        // System audio from Mac (AUD1 PCM) — not video.
        if (AudioPlayer.isAudioFrame(payload)) {
            audioPlayer.feed(payload)
            return
        }
        val parsed = AnnexBParser.parse(payload)
        noteVideoFrame(payload.size, parsed.captureMs, parsed.sendMs)
        decoder.feedParsed(parsed)
        if (!state.streaming) {
            publish(state.copy(status = "Streaming", streaming = true))
        }
    }

    private fun noteVideoFrame(byteCount: Int, captureMs: Double?, sendMs: Double?) {
        val now = System.currentTimeMillis()
        val offset = clockOffsetMs
        synchronized(metricsLock) {
            bytesThisWindow += byteCount
            framesThisWindow++
            if (lastFrameAtMs > 0) {
                val gap = now - lastFrameAtMs
                if (gap > 50) stallsThisWindow++
            }
            lastFrameAtMs = now

            if (captureMs != null && sendMs != null) {
                encodeWindow.add(sendMs - captureMs)
                if (encodeWindow.size > 120) encodeWindow.removeAt(0)
                if (offset != null) {
                    val e2e = (now.toDouble() + offset) - captureMs
                    if (e2e > -50 && e2e < 5000) {
                        e2eWindow.add(e2e)
                        if (e2eWindow.size > 120) e2eWindow.removeAt(0)
                    }
                }
            }
        }
    }

    private fun handleJson(text: String) {
        try {
            val obj = JSONObject(text)
            when (obj.optString("type")) {
                WireMessage.PONG -> {
                    val t1 = obj.optDouble("t", Double.NaN)
                    val mt = obj.optDouble("mt", Double.NaN)
                    if (t1.isNaN() || mt.isNaN()) return
                    val t2 = System.currentTimeMillis().toDouble()
                    val rtt = t2 - t1
                    if (rtt < 0 || rtt >= 2000) return
                    val offset = mt - (t1 + t2) / 2
                    offsetSamples.add(rtt to offset)
                    if (offsetSamples.size > 15) offsetSamples.removeAt(0)
                    clockOffsetMs = offsetSamples.minByOrNull { it.first }?.second
                    lastRttMs = rtt
                }
                WireMessage.PING -> {
                    // Mac liveness / health — nothing required beyond watchdog.
                }
                WireMessage.WELCOME -> {
                    val pv = obj.optInt("pv", WireProtocol.ASSUMED_WHEN_ABSENT)
                    Log.i(tag, "welcome from Mac pv=$pv")
                }
                WireMessage.UPDATE_REQUIRED -> {
                    Log.w(tag, "Mac requested update: ${obj.optString("message")}")
                    publish(state.copy(status = obj.optString("message", "Update required")))
                }
                WireMessage.CURSOR -> {
                    val visible = obj.optInt("v", 0) == 1
                    val x = obj.optDouble("x", 0.0)
                    val y = obj.optDouble("y", 0.0)
                    mainHandler.post { onCursor(x, y, visible) }
                }
                WireMessage.CURSOR_IMG -> {
                    val png = obj.optString("png")
                    val nw = obj.optDouble("nw", 0.0)
                    val nh = obj.optDouble("nh", 0.0)
                    val ax = obj.optDouble("ax", 0.0)
                    val ay = obj.optDouble("ay", 0.0)
                    if (nw > 0 && nh > 0 && png.isNotEmpty()) {
                        mainHandler.post { onCursorImage(png, nw, nh, ax, ay) }
                    }
                }
                else -> Log.d(tag, "ignore control type=${obj.optString("type")}")
            }
        } catch (e: Exception) {
            Log.w(tag, "bad JSON control: ${e.message}")
        }
    }

    private suspend fun sendHello() {
        val p = panel
        val json = JSONObject()
            .put("type", WireMessage.HELLO)
            .put("pixelsWide", p.pixelsWide)
            .put("pixelsHigh", p.pixelsHigh)
            .put("scale", p.scale)
            .put("device", "Android")
            .put("id", installId)
            .put("pv", WireProtocol.VERSION)
            // Ask the Mac to stream system audio (AUD1 frames).
            .put("audio", 1)
        sendJson(json)
        Log.i(tag, "hello ${p.pixelsWide}x${p.pixelsHigh} @${p.scale}x audio=1")
    }

    private suspend fun sendJson(obj: JSONObject) {
        val socket = clientSocket.get() ?: return
        writeMutex.withLock {
            try {
                val out = BufferedOutputStream(socket.getOutputStream())
                FrameCodec.writeJsonFrame(out, obj.toString())
            } catch (e: Exception) {
                Log.w(tag, "send failed: ${e.message}")
            }
        }
    }

    private fun startPing() {
        pingJob?.cancel()
        pingJob = scope.launch {
            while (isActive) {
                delay(2_000)
                sendJson(
                    JSONObject()
                        .put("type", WireMessage.PING)
                        .put("t", System.currentTimeMillis().toDouble()),
                )
            }
        }
    }

    private fun startWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            // Longer first grace: Mac may still be building the virtual display
            // / waiting for Screen Recording after TCP connects (often 5–20s).
            val connectedAt = System.currentTimeMillis()
            while (isActive) {
                delay(1_000)
                val idle = System.currentTimeMillis() - lastDataMs.get()
                val sinceConnect = System.currentTimeMillis() - connectedAt
                // First 20s: setup / permission / first keyframe. After that,
                // 15s of total radio silence means a half-open link. Shorter
                // limits (6s) dropped healthy sessions under decoder load.
                val limit = if (sinceConnect < 20_000) 20_000L else 15_000L
                if (idle > limit) {
                    Log.w(tag, "watchdog: no data for ${idle}ms — dropping")
                    closeClient("watchdog")
                    break
                }
            }
        }
    }

    /** Every 1s roll a local window; every 5s send aggregate `stats` to the Mac. */
    private fun startStats() {
        statsJob?.cancel()
        statsJob = scope.launch {
            while (isActive) {
                delay(1_000)
                val now = System.currentTimeMillis()
                val (fps, mbps, stalls, e2e50, e2e95, enc50) = synchronized(metricsLock) {
                    val elapsed = (now - windowStartMs).coerceAtLeast(1) / 1000.0
                    val f = (framesThisWindow / elapsed).toInt()
                    val m = bytesThisWindow * 8.0 / elapsed / 1_000_000.0
                    val s = stallsThisWindow
                    // Snapshot before percentile so session thread can keep writing.
                    val e2eSnap = ArrayList(e2eWindow)
                    val encSnap = ArrayList(encodeWindow)
                    framesThisWindow = 0
                    bytesThisWindow = 0L
                    stallsThisWindow = 0
                    windowStartMs = now
                    StatsTick(
                        fps = f,
                        mbps = m,
                        stalls = s,
                        e2e50 = H264Decoder.percentile(e2eSnap, 0.5),
                        e2e95 = H264Decoder.percentile(e2eSnap, 0.95),
                        enc50 = H264Decoder.percentile(encSnap, 0.5),
                    )
                }
                val decSnap = decoder.snapshotAndResetDecodeSamples()

                statsReportCounter++
                if (statsReportCounter < 5) continue
                statsReportCounter = 0

                val json = JSONObject()
                    .put("type", WireMessage.STATS)
                    .put("transport", "WiFi")
                    .put("fps", fps)
                    .put("mbps", (mbps * 10).toLong() / 10.0)
                    .put("e2e50", e2e50.roundTo())
                    .put("e2e95", e2e95.roundTo())
                    .put("enc50", enc50.roundTo())
                    .put("rtt", lastRttMs.roundTo())
                    .put("stalls", stalls)
                    .put("dec50", decSnap.decodeP50Ms.roundTo())
                    .put("drops", decSnap.inputDrops + decSnap.outputDrops)
                    .put("inDrops", decSnap.inputDrops)
                    .put("outDrops", decSnap.outputDrops)
                    .put("offsetKnown", clockOffsetMs != null)
                sendJson(json)
                Log.i(
                    tag,
                    "stats fps=$fps mbps=${"%.1f".format(mbps)} e2e50=${e2e50.toInt()} " +
                        "rtt=${lastRttMs.toInt()} drops=${decSnap.inputDrops + decSnap.outputDrops}",
                )
                e2eWindow.clear()
                encodeWindow.clear()
            }
        }
    }

    private fun Double.roundTo(): Double = kotlin.math.round(this)

    private fun closeClient(reason: String) {
        Log.i(tag, "close client ($reason)")
        try {
            clientSocket.getAndSet(null)?.close()
        } catch (_: Exception) {
        }
        sessionJob?.cancel()
        pingJob?.cancel()
        watchdogJob?.cancel()
        statsJob?.cancel()
    }

    fun onVideoSize(width: Int, height: Int) {
        publish(state.copy(videoWidth = width, videoHeight = height, streaming = true, status = "Receiving ${width}×${height}"))
    }

    private fun publish(next: ReceiverUiState) {
        state = next
        onState(next)
    }

    companion object {
        fun localIpv4Addresses(): List<String> {
            val out = ArrayList<String>()
            try {
                val en = NetworkInterface.getNetworkInterfaces() ?: return out
                while (en.hasMoreElements()) {
                    val nif = en.nextElement()
                    if (!nif.isUp || nif.isLoopback) continue
                    val addrs = nif.inetAddresses
                    while (addrs.hasMoreElements()) {
                        val a = addrs.nextElement()
                        if (a is Inet4Address && !a.isLoopbackAddress) {
                            out.add(a.hostAddress ?: continue)
                        }
                    }
                }
            } catch (_: Exception) {
            }
            return out
        }
    }
}
