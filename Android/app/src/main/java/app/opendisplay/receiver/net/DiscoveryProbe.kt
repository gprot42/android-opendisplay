package app.opendisplay.receiver.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import app.opendisplay.receiver.protocol.WireProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.nio.charset.StandardCharsets

/**
 * UDP signature responder so LAN scanners only list real OpenDisplay apps.
 *
 * Listens on [MCAST_PORT] (9010):
 * - Multicast group [MCAST_GROUP] (preferred when AP blocks unicast)
 * - Unicast on the same port (when the network allows)
 *
 * Does not use TCP 9000 (would steal an active stream).
 *
 * Note: many consumer APs block peer unicast and custom multicast while still
 * allowing mDNS — Mac discovery falls back to Bonjour TXT `sig=OpenDisplay`.
 */
class DiscoveryProbe(
    context: Context,
    private val installId: String,
    private val serviceName: () -> String,
    private val tcpPort: () -> Int,
) {
    private val tag = "DiscoveryProbe"
    private val appContext = context.applicationContext
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var socket: DatagramSocket? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    @Volatile
    var running = false
        private set

    fun start(port: Int = MCAST_PORT) {
        if (running) return
        running = true
        if (scope.coroutineContext[Job]?.isActive != true) {
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        }
        acquireMulticastLock()
        job = scope.launch {
            // Give MulticastLock + Wi‑Fi radio a beat before IGMP join (avoids EPERM
            // on some Pixel / OEM stacks when join races radio bring-up).
            delay(150)
            if (!running) return@launch
            listenLoop(port)
        }
    }

    fun stop() {
        running = false
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        job?.cancel()
        job = null
        releaseMulticastLock()
    }

    private fun listenLoop(port: Int) {
        try {
            val sock = openSocket(port)
            socket = sock
            Log.i(tag, "discovery on :$port group=$MCAST_GROUP sig=$SIGNATURE")
            val buf = ByteArray(1024)
            while (running) {
                val packet = DatagramPacket(buf, buf.size)
                try {
                    sock.receive(packet)
                } catch (e: Exception) {
                    if (!running) break
                    continue
                }
                handle(sock, packet)
            }
        } catch (e: Exception) {
            Log.e(tag, "discovery failed: ${e.message}", e)
        } finally {
            try {
                socket?.close()
            } catch (_: Exception) {
            }
            socket = null
        }
    }

    private fun openSocket(port: Int): DatagramSocket {
        // Prefer MulticastSocket; fall back to plain DatagramSocket if join is denied.
        val wifiNetwork = activeWifiNetwork()
        try {
            val ms = MulticastSocket(null)
            ms.reuseAddress = true
            ms.bind(InetSocketAddress(port))
            // Bind to the Wi‑Fi Network so IGMP/multicast leave on the right iface.
            if (wifiNetwork != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                try {
                    wifiNetwork.bindSocket(ms)
                    Log.i(tag, "bound MulticastSocket to Wi‑Fi network")
                } catch (e: Exception) {
                    Log.d(tag, "bindSocket: ${e.message}")
                }
            }

            val group = InetAddress.getByName(MCAST_GROUP)
            var joined = false

            // 1) Per-interface join (most reliable on Android 10+).
            val ifaces = preferredInterfaces()
            for (ni in ifaces) {
                try {
                    ms.joinGroup(InetSocketAddress(group, port), ni)
                    joined = true
                    Log.i(tag, "joined $MCAST_GROUP on ${ni.name}")
                } catch (e: Exception) {
                    Log.d(tag, "join ${ni.name}: ${e.message}")
                }
            }

            // 2) Legacy default join.
            if (!joined) {
                try {
                    @Suppress("DEPRECATION")
                    ms.joinGroup(group)
                    joined = true
                    Log.i(tag, "joined multicast $MCAST_GROUP (default)")
                } catch (e: Exception) {
                    Log.w(tag, "default joinGroup: ${e.message}")
                }
            }

            // 3) Retry once after re-acquiring the lock (OEM race).
            if (!joined) {
                acquireMulticastLock()
                Thread.sleep(100)
                for (ni in ifaces) {
                    try {
                        ms.joinGroup(InetSocketAddress(group, port), ni)
                        joined = true
                        Log.i(tag, "joined $MCAST_GROUP on ${ni.name} (retry)")
                        break
                    } catch (e: Exception) {
                        Log.d(tag, "retry join ${ni.name}: ${e.message}")
                    }
                }
            }

            if (joined) {
                try {
                    ms.timeToLive = 1
                } catch (_: Exception) {
                }
                return ms
            }
            ms.close()
        } catch (e: Exception) {
            Log.w(tag, "MulticastSocket failed: ${e.message}")
        }

        val ds = DatagramSocket(null)
        ds.reuseAddress = true
        ds.bind(InetSocketAddress(port))
        if (wifiNetwork != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                wifiNetwork.bindSocket(ds)
            } catch (_: Exception) {
            }
        }
        Log.i(tag, "unicast-only DatagramSocket :$port (multicast join denied — Bonjour still verifies)")
        return ds
    }

    private fun preferredInterfaces(): List<NetworkInterface> {
        val out = mutableListOf<NetworkInterface>()
        try {
            val all = NetworkInterface.getNetworkInterfaces() ?: return out
            while (all.hasMoreElements()) {
                val ni = all.nextElement()
                try {
                    if (!ni.isUp || ni.isLoopback) continue
                    if (!ni.supportsMulticast()) continue
                    // Prefer wlan*; skip rmnet / mobile.
                    val n = ni.name.lowercase()
                    if (n.startsWith("rmnet") || n.startsWith("ccmni") || n.startsWith("dummy")) continue
                    out.add(ni)
                } catch (_: Exception) {
                }
            }
        } catch (_: Exception) {
        }
        // wlan first
        return out.sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
    }

    private fun activeWifiNetwork(): Network? {
        return try {
            val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val active = cm.activeNetwork
                val caps = active?.let { cm.getNetworkCapabilities(it) }
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    return active
                }
                // Fall through: any Wi‑Fi network.
                for (n in cm.allNetworks) {
                    val c = cm.getNetworkCapabilities(n) ?: continue
                    if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return n
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun handle(sock: DatagramSocket, packet: DatagramPacket) {
        val text = try {
            String(packet.data, packet.offset, packet.length, StandardCharsets.UTF_8)
        } catch (_: Exception) {
            return
        }
        if (!text.contains(TYPE_PROBE)) return
        val obj = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }
        if (obj.optString("t") != TYPE_PROBE) return
        if (obj.optInt("v", 0) < 1) return
        val nonce = obj.opt("n") ?: return

        val reply = JSONObject()
            .put("t", TYPE_ACK)
            .put("v", 1)
            .put("n", nonce)
            .put("sig", SIGNATURE)
            .put("pv", WireProtocol.VERSION)
            .put("id", installId)
            .put("name", serviceName().ifBlank { "OpenDisplay" })
            .put("port", tcpPort())
            .toString()
            .toByteArray(StandardCharsets.UTF_8)

        try {
            // Unicast ack to the probe source (primary).
            sock.send(DatagramPacket(reply, reply.size, packet.address, packet.port))
            // Multicast ack so browsers joined to the group can hear us even if
            // unicast reply path is filtered (optional).
            try {
                sock.send(
                    DatagramPacket(
                        reply,
                        reply.size,
                        InetAddress.getByName(MCAST_GROUP),
                        MCAST_PORT,
                    ),
                )
            } catch (_: Exception) {
            }
            Log.i(tag, "ack → ${packet.address.hostAddress}:${packet.port}")
        } catch (e: Exception) {
            Log.w(tag, "send ack: ${e.message}")
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            val lock = wifi.createMulticastLock("opendisplay-discovery")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
            Log.i(tag, "multicast lock held")
        } catch (e: Exception) {
            Log.w(tag, "multicast lock: ${e.message}")
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    companion object {
        const val MCAST_GROUP = "239.255.90.0"
        const val MCAST_PORT = 9010
        const val TYPE_PROBE = "od-probe"
        const val TYPE_ACK = "od-ack"
        const val SIGNATURE = "OpenDisplay"
    }
}
