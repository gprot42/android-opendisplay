package app.opendisplay.receiver.net

import android.content.Context
import android.net.wifi.WifiManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import app.opendisplay.receiver.protocol.WireProtocol

/**
 * Advertise the receiver so the Mac's Bonjour browser can find it.
 * Service type and TXT keys match iOS (docs/WIRE.md).
 */
class NsdAdvertiser(context: Context) {
    private val tag = "NsdAdvertiser"
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registration: NsdManager.RegistrationListener? = null
    private var registeredName: String? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var registrationRetries = 0

    fun register(serviceName: String, port: Int, installId: String, protocolVersion: Int = WireProtocol.VERSION) {
        unregister()
        registrationRetries = 0
        acquireMulticastLock()
        acquireWifiLock()
        val info = NsdServiceInfo().apply {
            this.serviceName = serviceName.ifBlank { "OpenDisplay" }
            this.serviceType = WireProtocol.SERVICE_TYPE
            this.port = port
            setAttribute("id", installId)
            setAttribute("pv", protocolVersion.toString())
            // Lets the Mac treat this Bonjour hit as signature-verified.
            setAttribute("sig", "OpenDisplay")
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                registeredName = serviceInfo.serviceName
                registrationRetries = 0
                Log.i(tag, "registered as \"${serviceInfo.serviceName}\" on port $port")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(tag, "registration failed: $errorCode")
                // Some OEMs fail the first register after wake; retry once.
                if (registrationRetries < 1) {
                    registrationRetries++
                    Log.i(tag, "retrying mDNS registration")
                    try {
                        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, this)
                    } catch (e: Exception) {
                        Log.e(tag, "register retry threw", e)
                    }
                }
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                Log.i(tag, "unregistered")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(tag, "unregistration failed: $errorCode")
            }
        }
        registration = listener
        try {
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(tag, "registerService threw", e)
        }
    }

    fun unregister() {
        val listener = registration
        registration = null
        if (listener != null) {
            try {
                nsd.unregisterService(listener)
            } catch (e: Exception) {
                Log.w(tag, "unregister: ${e.message}")
            }
        }
        registeredName = null
        releaseMulticastLock()
        releaseWifiLock()
    }

    /** Keep Wi‑Fi radio up while advertising / listening for the Mac. */
    private fun acquireWifiLock() {
        if (wifiLock?.isHeld == true) return
        try {
            val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            @Suppress("DEPRECATION")
            val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "opendisplay-wifi")
            lock.setReferenceCounted(false)
            lock.acquire()
            wifiLock = lock
            Log.i(tag, "Wi‑Fi high-perf lock acquired")
        } catch (e: Exception) {
            Log.w(tag, "wifi lock: ${e.message}")
        }
    }

    private fun releaseWifiLock() {
        try {
            wifiLock?.takeIf { it.isHeld }?.release()
        } catch (_: Exception) {
        }
        wifiLock = null
    }

    /** Multicast lock keeps mDNS advertisements reachable on many OEM Wi‑Fi stacks. */
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = appContext.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return
            val lock = wifi.createMulticastLock("opendisplay-mdns").also {
                it.setReferenceCounted(false)
                it.acquire()
            }
            multicastLock = lock
            Log.i(tag, "Wi‑Fi multicast lock acquired")
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
