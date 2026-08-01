package app.opendisplay.receiver.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.SystemClock
import android.util.Log
import app.opendisplay.receiver.protocol.WireProtocol
import java.net.Inet4Address

/**
 * Discovers OpenDisplay Mac hosts that advertise reverse-connect
 * (`_opendisplay-mac._tcp`) when the AP blocks Mac→tablet TCP.
 *
 * On resolve, invokes [onHost] with the Mac IPv4 and reverse port so
 * [ReceiverServer.connectOutbound] can dial.
 */
class MacHostBrowser(
    context: Context,
    private val onHost: (host: String, port: Int, name: String) -> Unit,
) {
    private val tag = "MacHostBrowser"
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var discovery: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val resolving = HashSet<String>()
    /** host:port → last dial attempt elapsedRealtime */
    private val lastDialAt = HashMap<String, Long>()
    private val dialCooldownMs = 8_000L

    @Volatile
    var running = false
        private set

    fun start() {
        if (running) return
        running = true
        acquireMulticastLock()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.i(tag, "discovering $regType")
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                val type = service.serviceType ?: return
                if (!type.contains("opendisplay-mac", ignoreCase = true)) return
                val key = "${service.serviceName}|$type"
                synchronized(resolving) {
                    if (!resolving.add(key)) return
                }
                Log.i(tag, "found Mac host candidate \"${service.serviceName}\" type=$type")
                try {
                    nsd.resolveService(
                        service,
                        object : NsdManager.ResolveListener {
                            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                                Log.w(tag, "resolve failed $errorCode for ${serviceInfo.serviceName}")
                                synchronized(resolving) { resolving.remove(key) }
                                // Retry once after a short pause (OEM mDNS flakes).
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    if (!running) return@postDelayed
                                    synchronized(resolving) {
                                        if (!resolving.add(key)) return@postDelayed
                                    }
                                    try {
                                        nsd.resolveService(serviceInfo, this)
                                    } catch (e: Exception) {
                                        synchronized(resolving) { resolving.remove(key) }
                                        Log.w(tag, "resolve retry threw: ${e.message}")
                                    }
                                }, 1500)
                            }

                            override fun onServiceResolved(info: NsdServiceInfo) {
                                synchronized(resolving) { resolving.remove(key) }
                                val port = if (info.port > 0) info.port else WireProtocol.MAC_REVERSE_PORT
                                val host = pickIPv4(info)
                                    ?: txtIp(info)
                                    ?: info.host?.hostAddress
                                if (host.isNullOrBlank()) {
                                    Log.w(tag, "resolved without host")
                                    return
                                }
                                // Skip IPv6 link-local for dial (often needs scope id).
                                if (host.contains(':') && !host.contains('.')) {
                                    Log.w(tag, "skip IPv6-only host $host")
                                    return
                                }
                                val dialKey = "$host:$port"
                                val now = SystemClock.elapsedRealtime()
                                synchronized(lastDialAt) {
                                    val prev = lastDialAt[dialKey] ?: 0L
                                    if (now - prev < dialCooldownMs) {
                                        Log.d(tag, "cooldown $dialKey")
                                        return
                                    }
                                    lastDialAt[dialKey] = now
                                }
                                Log.i(tag, "resolved Mac \"${info.serviceName}\" → $host:$port — dialing")
                                onHost(host, port, info.serviceName ?: "Mac")
                            }
                        },
                    )
                } catch (e: Exception) {
                    Log.w(tag, "resolve threw: ${e.message}")
                    synchronized(resolving) { resolving.remove(key) }
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                Log.i(tag, "lost ${service.serviceName}")
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.i(tag, "discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(tag, "start discovery failed: $errorCode — restarting in 3s")
                running = false
                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                    if (discovery == null) start()
                }, 3000)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(tag, "stop discovery failed: $errorCode")
            }
        }
        discovery = listener
        try {
            nsd.discoverServices(WireProtocol.MAC_HOST_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(tag, "discoverServices threw", e)
            running = false
        }
    }

    fun stop() {
        running = false
        discovery?.let {
            try {
                nsd.stopServiceDiscovery(it)
            } catch (_: Exception) {
            }
        }
        discovery = null
        synchronized(resolving) { resolving.clear() }
        releaseMulticastLock()
    }

    private fun pickIPv4(info: NsdServiceInfo): String? {
        // API 34+ may expose hostAddresses; fall back to host.
        try {
            val method = info.javaClass.getMethod("getHostAddresses")
            @Suppress("UNCHECKED_CAST")
            val addrs = method.invoke(info) as? Array<java.net.InetAddress>
            addrs?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
                ?.hostAddress
                ?.let { return it }
        } catch (_: Exception) {
        }
        val h = info.host
        if (h is Inet4Address && !h.isLoopbackAddress) return h.hostAddress
        return null
    }

    private fun txtIp(info: NsdServiceInfo): String? {
        return try {
            val map = info.attributes ?: return null
            val raw = map["ip"] ?: return null
            String(raw, Charsets.UTF_8).trim().ifBlank { null }
        } catch (_: Exception) {
            null
        }
    }

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            val lock = wifi.createMulticastLock("opendisplay-mac-host")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
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
}
