package app.opendisplay.receiver.net

import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Length-prefixed framing: [uint32 BE length][payload].
 * Shared by video and control on the same TCP connection.
 */
object FrameCodec {
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024

    fun writeFrame(out: OutputStream, payload: ByteArray) {
        require(payload.size <= MAX_FRAME_BYTES) { "frame too large: ${payload.size}" }
        val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size).array()
        out.write(header)
        out.write(payload)
        out.flush()
    }

    fun writeJsonFrame(out: OutputStream, json: String) {
        writeFrame(out, json.toByteArray(Charsets.UTF_8))
    }

    /**
     * Blocking read of one full frame.
     * @return null on clean EOF before any header bytes
     */
    fun readFrame(input: InputStream): ByteArray? {
        val header = ByteArray(4)
        val headerRead = readFullyOrEof(input, header)
        if (headerRead == 0) return null
        if (headerRead < 4) throw EOFException("truncated frame header")
        val len = ByteBuffer.wrap(header).order(ByteOrder.BIG_ENDIAN).int
        if (len <= 0 || len > MAX_FRAME_BYTES) {
            throw IllegalArgumentException("invalid frame length: $len")
        }
        val payload = ByteArray(len)
        val bodyRead = readFullyOrEof(input, payload)
        if (bodyRead < len) throw EOFException("truncated frame body")
        return payload
    }

    /** @return number of bytes read; 0 means EOF with nothing read */
    private fun readFullyOrEof(input: InputStream, buf: ByteArray): Int {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) return off
            off += n
        }
        return off
    }
}
