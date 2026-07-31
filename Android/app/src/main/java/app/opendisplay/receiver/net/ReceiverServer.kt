package app.opendisplay.receiver.net

import android.os.Handler
import android.os.Looper
import android.util.Log
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

    @Volatile private var serverSocket: ServerSocket? = null
    @Volatile private var panel = PanelInfo(1920, 1200, 2.0)
    @Volatile private var serviceName = "OpenDisplay"
    @Volatile private var port = WireProtocol.DEFAULT_PORT
    @Volatile private var running = false

    private var acceptJob: Job? = null
    private var sessionJob: Job? = null
    private var watchdogJob: Job? = null
    private var pingJob: Job? = null

    private var state = ReceiverUiState()

    fun updatePanel(info: PanelInfo) {
        val changed = panel != info
        panel = info
        if (changed && state.connected) {
            scope.launch { sendHello() }
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

    private suspend fun listenLoop() {
        while (scope.isActive && running) {
            try {
                val server = ServerSocket(port)
                server.reuseAddress = true
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
                    // Single client: replace any previous session.
                    closeClient("replaced")
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    clientSocket.set(socket)
                    sessionJob = scope.launch { runSession(socket) }
                }
            } catch (e: Exception) {
                if (!running) break
                Log.e(tag, "listen error", e)
                publish(state.copy(status = "Listen error: ${e.message}", listening = false))
                delay(1_000)
            }
        }
    }

    private suspend fun runSession(socket: Socket) = withContext(Dispatchers.IO) {
        lastDataMs.set(System.currentTimeMillis())
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
            try {
                socket.close()
            } catch (_: Exception) {
            }
            if (clientSocket.get() === socket) clientSocket.set(null)
            mainHandler.post { onCursorReset() }
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

    private fun handleInbound(payload: ByteArray) {
        if (AnnexBParser.isJsonControl(payload)) {
            handleJson(payload.toString(Charsets.UTF_8))
            return
        }
        decoder.feed(payload)
        if (!state.streaming) {
            publish(state.copy(status = "Streaming", streaming = true))
        }
    }

    private fun handleJson(text: String) {
        try {
            val obj = JSONObject(text)
            when (obj.optString("type")) {
                WireMessage.PONG -> Unit // clock sync later
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
        sendJson(json)
        Log.i(tag, "hello ${p.pixelsWide}x${p.pixelsHigh} @${p.scale}x")
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
            while (isActive) {
                delay(1_000)
                val idle = System.currentTimeMillis() - lastDataMs.get()
                if (idle > 5_000) {
                    Log.w(tag, "watchdog: no data for ${idle}ms — dropping")
                    closeClient("watchdog")
                    break
                }
            }
        }
    }

    private fun closeClient(reason: String) {
        Log.i(tag, "close client ($reason)")
        try {
            clientSocket.getAndSet(null)?.close()
        } catch (_: Exception) {
        }
        sessionJob?.cancel()
        pingJob?.cancel()
        watchdogJob?.cancel()
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
