package app.opendisplay.receiver

import android.content.Context

/**
 * Preferred Mac path (UI hint only). The receiver **always** listens on
 * TCP :9000 for both USB (adb forward / tether) and Wi‑Fi while the app is open.
 *
 * - Network: prefer discovery / LAN IP on the Mac.
 * - USB: prefer adb forward (keeps Mac internet); tether is a fallback.
 */
enum class ConnectionMode {
    NETWORK,
    USB,
    ;

    val label: String
        get() = when (this) {
            NETWORK -> "Network"
            USB -> "USB"
        }

    companion object {
        private const val PREFS = "opendisplay"
        private const val KEY = "connectionMode"

        fun load(context: Context): ConnectionMode {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY, NETWORK.name)
            return entries.firstOrNull { it.name == raw } ?: NETWORK
        }

        fun save(context: Context, mode: ConnectionMode) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY, mode.name)
                .apply()
        }
    }
}
