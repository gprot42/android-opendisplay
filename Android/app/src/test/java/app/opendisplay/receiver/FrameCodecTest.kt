package app.opendisplay.receiver

import app.opendisplay.receiver.net.FrameCodec
import app.opendisplay.receiver.video.AnnexBParser
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class FrameCodecTest {
    @Test
    fun roundTrip() {
        val payload = """{"type":"hello","pv":2}""".toByteArray()
        val out = ByteArrayOutputStream()
        FrameCodec.writeFrame(out, payload)
        val decoded = FrameCodec.readFrame(ByteArrayInputStream(out.toByteArray()))
        assertArrayEquals(payload, decoded)
    }

    @Test
    fun emptyStreamReturnsNull() {
        assertNull(FrameCodec.readFrame(ByteArrayInputStream(ByteArray(0))))
    }

    @Test
    fun detectsJsonControl() {
        val json = """{"type":"pong","t":1.0,"mt":2.0}""".toByteArray()
        assertTrue(AnnexBParser.isJsonControl(json))
        val withNul = byteArrayOf('{'.code.toByte(), 0, '}'.code.toByte())
        assertFalse(AnnexBParser.isJsonControl(withNul))
    }

    @Test
    fun parsesAnnexBWithMeta() {
        val sps = byteArrayOf(0x67, 0x42)
        val slice = byteArrayOf(0x65, 0x01, 0x02)
        val meta = """{"cap":100.0,"snd":110.0}""".toByteArray()
        val payload = meta + startCode() + sps + startCode() + slice
        val parsed = AnnexBParser.parse(payload)
        assertEquals(100.0, parsed.captureMs!!, 0.01)
        assertEquals(110.0, parsed.sendMs!!, 0.01)
        assertEquals(2, parsed.nalus.size)
        assertEquals(7, AnnexBParser.naluType(parsed.nalus[0]))
        assertArrayEquals(slice, parsed.nalus[1])
    }

    private fun startCode() = byteArrayOf(0, 0, 0, 1)
}
