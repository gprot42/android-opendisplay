package app.opendisplay.receiver.compat

import android.media.MediaCodecList
import android.os.Build
import android.util.Log

/**
 * Runtime environment snapshot for support / multi-version debugging.
 * Log once at startup; also shown on the idle screen.
 */
object DeviceReport {
    private const val TAG = "DeviceReport"

    data class Info(
        val androidRelease: String,
        val sdkInt: Int,
        val manufacturer: String,
        val model: String,
        val abis: String,
        val hasAvcDecoder: Boolean,
        val avcDecoderName: String?,
    ) {
        /** One line for the idle UI. */
        fun summaryLine(): String =
            "Android $androidRelease (API $sdkInt) · $model"

        fun detailLines(): List<String> = listOf(
            summaryLine(),
            "$manufacturer · ABI $abis",
            if (hasAvcDecoder) {
                "H.264 decoder: ${avcDecoderName ?: "yes"}"
            } else {
                "H.264 decoder: MISSING — streaming will fail"
            },
        )
    }

    fun collect(): Info {
        val (hasAvc, name) = findAvcDecoder()
        return Info(
            androidRelease = Build.VERSION.RELEASE ?: "?",
            sdkInt = Build.VERSION.SDK_INT,
            manufacturer = Build.MANUFACTURER ?: "?",
            model = Build.MODEL ?: "?",
            abis = Build.SUPPORTED_ABIS.joinToString(","),
            hasAvcDecoder = hasAvc,
            avcDecoderName = name,
        )
    }

    fun logOnce() {
        val info = collect()
        Log.i(TAG, "—— OpenDisplay receiver environment ——")
        info.detailLines().forEach { Log.i(TAG, it) }
        Log.i(TAG, "minSdk=26 target features: MediaCodec AVC, NSD, TCP cleartext LAN")
        Log.i(TAG, "lowLatency flag (API 30+): ${Build.VERSION.SDK_INT >= 30}")
    }

    private fun findAvcDecoder(): Pair<Boolean, String?> {
        return try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val name = list.codecInfos
                .firstOrNull { !it.isEncoder && it.supportedTypes.any { t ->
                    t.equals("video/avc", ignoreCase = true)
                } }
                ?.name
            (name != null) to name
        } catch (e: Exception) {
            Log.w(TAG, "codec probe failed: ${e.message}")
            false to null
        }
    }
}
