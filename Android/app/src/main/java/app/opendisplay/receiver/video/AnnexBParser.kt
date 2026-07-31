package app.opendisplay.receiver.video

/**
 * Split a Mac video payload into optional JSON meta + Annex B NALUs.
 * Start codes are 00 00 00 01 only (see WIRE.md).
 */
object AnnexBParser {
    data class ParsedFrame(
        val captureMs: Double?,
        val sendMs: Double?,
        val nalus: List<ByteArray>,
    )

    fun isJsonControl(payload: ByteArray): Boolean {
        // Cursor sprites are base64 PNG (Mac caps raw PNG at 24KB ≈ ~32KB b64).
        // Leave headroom so cursorImg never falls through as video.
        if (payload.isEmpty() || payload.size >= 64 * 1024) return false
        if (payload[0] != '{'.code.toByte()) return false
        for (b in payload) {
            if (b == 0.toByte()) return false
        }
        return true
    }

    fun parse(payload: ByteArray): ParsedFrame {
        val startCodes = findStartCodes(payload)
        var captureMs: Double? = null
        var sendMs: Double? = null
        val bodyStart = startCodes.firstOrNull() ?: payload.size

        if (bodyStart > 0) {
            val meta = payload.copyOfRange(0, bodyStart).toString(Charsets.UTF_8)
            // Lightweight parse — avoid full JSON dependency on the hot path.
            captureMs = extractDouble(meta, "cap")
            sendMs = extractDouble(meta, "snd")
        }

        val nalus = ArrayList<ByteArray>(startCodes.size)
        for (i in startCodes.indices) {
            val dataStart = startCodes[i] + 4
            val dataEnd = if (i + 1 < startCodes.size) startCodes[i + 1] else payload.size
            if (dataStart < dataEnd) {
                nalus.add(payload.copyOfRange(dataStart, dataEnd))
            }
        }
        return ParsedFrame(captureMs, sendMs, nalus)
    }

    fun naluType(nalu: ByteArray): Int {
        if (nalu.isEmpty()) return -1
        return nalu[0].toInt() and 0x1F
    }

    private fun findStartCodes(payload: ByteArray): List<Int> {
        val out = ArrayList<Int>()
        var i = 0
        while (i + 3 < payload.size) {
            if (payload[i] == 0.toByte() &&
                payload[i + 1] == 0.toByte() &&
                payload[i + 2] == 0.toByte() &&
                payload[i + 3] == 1.toByte()
            ) {
                out.add(i)
                i += 4
            } else {
                i++
            }
        }
        return out
    }

    private fun extractDouble(json: String, key: String): Double? {
        val needle = "\"$key\":"
        val idx = json.indexOf(needle)
        if (idx < 0) return null
        var i = idx + needle.length
        while (i < json.length && json[i].isWhitespace()) i++
        val start = i
        while (i < json.length && (json[i].isDigit() || json[i] == '.' || json[i] == '-')) i++
        if (i == start) return null
        return json.substring(start, i).toDoubleOrNull()
    }
}
