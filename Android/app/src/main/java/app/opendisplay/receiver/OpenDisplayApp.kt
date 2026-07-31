package app.opendisplay.receiver

import android.app.Application
import android.content.Context
import java.util.UUID

class OpenDisplayApp : Application() {
    val installId: String by lazy { loadOrCreateInstallId(this) }

    companion object {
        private const val PREFS = "opendisplay"
        private const val KEY_INSTALL_ID = "installID"

        fun loadOrCreateInstallId(context: Context): String {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val existing = prefs.getString(KEY_INSTALL_ID, null)
            if (existing != null) return existing
            val fresh = UUID.randomUUID().toString()
            prefs.edit().putString(KEY_INSTALL_ID, fresh).apply()
            return fresh
        }
    }
}
