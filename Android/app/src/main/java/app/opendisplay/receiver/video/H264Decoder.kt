package app.opendisplay.receiver.video

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hardware H.264 decode into a Surface. Configures from in-band SPS/PPS.
 * Call [release] on the session thread when the surface or connection ends.
 */
class H264Decoder(
    private val onNeedKeyframe: () -> Unit,
    private val onVideoSize: (width: Int, height: Int) -> Unit,
) {
    private val tag = "H264Decoder"
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var configured = false
    private val released = AtomicBoolean(false)
    private var ptsUs = 0L

    fun setSurface(surface: Surface?) {
        this.surface = surface
        // Surface changed — force reconfigure with next SPS/PPS.
        if (configured) {
            releaseCodecOnly()
            configured = false
        }
    }

    fun feed(payload: ByteArray) {
        if (released.get()) return
        if (AnnexBParser.isJsonControl(payload)) return

        val parsed = AnnexBParser.parse(payload)
        var formatChanged = false
        val vcl = ArrayList<ByteArray>()

        for (nalu in parsed.nalus) {
            when (AnnexBParser.naluType(nalu)) {
                7 -> { // SPS
                    if (sps == null || !sps.contentEquals(nalu)) {
                        sps = nalu
                        formatChanged = true
                    }
                }
                8 -> { // PPS
                    if (pps == null || !pps.contentEquals(nalu)) {
                        pps = nalu
                        formatChanged = true
                    }
                }
                6 -> Unit // SEI
                else -> vcl.add(nalu)
            }
        }

        if (formatChanged || !configured) {
            val s = sps
            val p = pps
            if (s != null && p != null) {
                try {
                    configure(s, p)
                } catch (e: Exception) {
                    Log.e(tag, "configure failed", e)
                    onNeedKeyframe()
                    return
                }
            }
        }

        if (!configured || vcl.isEmpty()) return

        // One MediaCodec buffer: Annex B start codes re-prefixed per NALU.
        val annexB = toAnnexB(vcl)
        queueInput(annexB)
        drainOutput()
    }

    private fun configure(sps: ByteArray, pps: ByteArray) {
        releaseCodecOnly()
        val surf = surface ?: return

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(withStartCode(sps)))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(withStartCode(pps)))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        // Prefer real-time path when vendors honor it.
        format.setInteger(MediaFormat.KEY_PRIORITY, 0)

        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        c.configure(format, surf, null, 0)
        c.start()
        codec = c
        configured = true
        Log.i(tag, "decoder configured")
        // Size comes from output format change.
    }

    private fun queueInput(annexB: ByteArray) {
        val c = codec ?: return
        try {
            val inIndex = c.dequeueInputBuffer(2_000)
            if (inIndex < 0) {
                Log.w(tag, "no input buffer — requesting keyframe")
                onNeedKeyframe()
                return
            }
            val buf = c.getInputBuffer(inIndex) ?: return
            buf.clear()
            buf.put(annexB)
            ptsUs += 16_666 // ~60fps placeholder; low-latency ignore display timestamps
            c.queueInputBuffer(inIndex, 0, annexB.size, ptsUs, 0)
        } catch (e: Exception) {
            Log.e(tag, "queueInput failed", e)
            releaseCodecOnly()
            configured = false
            onNeedKeyframe()
        }
    }

    private fun drainOutput() {
        val c = codec ?: return
        val info = MediaCodec.BufferInfo()
        try {
            while (true) {
                val outIndex = c.dequeueOutputBuffer(info, 0)
                when {
                    outIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val fmt = c.outputFormat
                        val w = fmt.getInteger(MediaFormat.KEY_WIDTH)
                        val h = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                        Log.i(tag, "output format $w x $h")
                        onVideoSize(w, h)
                    }
                    outIndex >= 0 -> {
                        // Render to surface immediately.
                        c.releaseOutputBuffer(outIndex, true)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "drainOutput failed", e)
            releaseCodecOnly()
            configured = false
            onNeedKeyframe()
        }
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        releaseCodecOnly()
    }

    private fun releaseCodecOnly() {
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        codec = null
        configured = false
    }

    private fun withStartCode(nalu: ByteArray): ByteArray {
        val out = ByteArray(4 + nalu.size)
        out[0] = 0
        out[1] = 0
        out[2] = 0
        out[3] = 1
        System.arraycopy(nalu, 0, out, 4, nalu.size)
        return out
    }

    private fun toAnnexB(nalus: List<ByteArray>): ByteArray {
        var size = 0
        for (n in nalus) size += 4 + n.size
        val out = ByteArray(size)
        var o = 0
        for (n in nalus) {
            out[o++] = 0
            out[o++] = 0
            out[o++] = 0
            out[o++] = 1
            System.arraycopy(n, 0, out, o, n.size)
            o += n.size
        }
        return out
    }
}
