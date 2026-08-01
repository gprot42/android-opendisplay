package app.opendisplay.receiver.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.util.Log
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Keeps a Wi‑Fi [Network] registered for this app process for the whole session.
 *
 * On GrapheneOS / modern Android, [ConnectivityManager.getActiveNetwork] is often
 * null until the app holds a [NetworkRequest]. Without that, outbound
 * `Socket.connect` fails with EACCES even though Wi‑Fi is up and ServerSocket
 * can still listen.
 */
object WifiNetworkHolder {
    private const val TAG = "WifiNetworkHolder"

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var registered = false

    private val networkRef = AtomicReference<Network?>(null)
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun start(context: Context) {
        val ctx = context.applicationContext
        appContext = ctx
        if (registered) return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                networkRef.set(network)
                Log.i(TAG, "Wi‑Fi network available: $network")
                // Keep process bound so later dials don't hit activeNetwork=null.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    try {
                        cm.bindProcessToNetwork(network)
                        Log.i(TAG, "process bound to Wi‑Fi (active=${cm.activeNetwork})")
                    } catch (e: Exception) {
                        Log.w(TAG, "bindProcessToNetwork: ${e.message}")
                    }
                }
            }

            override fun onLost(network: Network) {
                if (networkRef.get() == network) {
                    networkRef.set(null)
                    Log.i(TAG, "Wi‑Fi network lost")
                }
            }

            override fun onUnavailable() {
                Log.w(TAG, "Wi‑Fi request unavailable")
            }
        }
        callback = cb
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                cm.requestNetwork(request, cb)
            } else {
                @Suppress("DEPRECATION")
                cm.requestNetwork(request, cb)
            }
            registered = true
            Log.i(TAG, "Wi‑Fi NetworkRequest registered")
            // Seed from existing networks immediately.
            seedFromExisting(cm)
        } catch (e: SecurityException) {
            Log.w(TAG, "requestNetwork denied: ${e.message} — registerNetworkCallback")
            try {
                cm.registerNetworkCallback(request, cb)
                registered = true
                seedFromExisting(cm)
            } catch (e2: Exception) {
                Log.e(TAG, "registerNetworkCallback failed: ${e2.message}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "start failed: ${e.message}")
        }
    }

    fun stop() {
        val ctx = appContext ?: return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val cb = callback
        if (cm != null && cb != null) {
            try {
                cm.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && cm != null) {
            try {
                cm.bindProcessToNetwork(null)
            } catch (_: Exception) {
            }
        }
        callback = null
        networkRef.set(null)
        registered = false
        appContext = null
    }

    /** Best Wi‑Fi [Network] for this app, waiting briefly if still attaching. */
    fun network(timeoutMs: Long = 4_000): Network? {
        networkRef.get()?.let { return it }
        val ctx = appContext ?: return null
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return null
        seedFromExisting(cm)
        networkRef.get()?.let { return it }

        // Wait for onAvailable after start().
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (System.nanoTime() < deadline) {
            networkRef.get()?.let { return it }
            try {
                Thread.sleep(50)
            } catch (_: InterruptedException) {
                break
            }
        }
        return networkRef.get() ?: seedFromExisting(cm)
    }

    private fun seedFromExisting(cm: ConnectivityManager): Network? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        val active = cm.activeNetwork
        val activeCaps = active?.let { cm.getNetworkCapabilities(it) }
        if (activeCaps != null && activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            networkRef.compareAndSet(null, active)
            return active
        }
        for (n in cm.allNetworks) {
            val c = cm.getNetworkCapabilities(n) ?: continue
            if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                networkRef.compareAndSet(null, n)
                return n
            }
        }
        return networkRef.get()
    }
}
