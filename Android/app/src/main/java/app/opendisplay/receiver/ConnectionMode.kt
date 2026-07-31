package app.opendisplay.receiver

import android.content.Context

/**
 * How the Mac reaches this receiver. Network (Wi‑Fi / LAN) is the default;
 * USB uses a cable + `adb forward` (or USB tethering) on the Mac side.
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
