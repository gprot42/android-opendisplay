package app.opendisplay.receiver.net

import android.content.Context
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
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registration: NsdManager.RegistrationListener? = null
    private var registeredName: String? = null

    fun register(serviceName: String, port: Int, installId: String, protocolVersion: Int = WireProtocol.VERSION) {
        unregister()
        val info = NsdServiceInfo().apply {
            this.serviceName = serviceName.ifBlank { "OpenDisplay" }
            this.serviceType = WireProtocol.SERVICE_TYPE
            this.port = port
            setAttribute("id", installId)
            setAttribute("pv", protocolVersion.toString())
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                registeredName = serviceInfo.serviceName
                Log.i(tag, "registered as \"${serviceInfo.serviceName}\" on port $port")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(tag, "registration failed: $errorCode")
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
        val listener = registration ?: return
        registration = null
        try {
            nsd.unregisterService(listener)
        } catch (e: Exception) {
            Log.w(tag, "unregister: ${e.message}")
        }
        registeredName = null
    }
}
