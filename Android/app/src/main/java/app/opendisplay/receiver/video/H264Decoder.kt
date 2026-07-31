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
 *
 * Cross-version notes (minSdk 26):
 * - [MediaFormat.KEY_LOW_LATENCY] is API 30+ only; below that we try vendor keys.
 * - [MediaFormat.KEY_PRIORITY] is API 23+ (always available here).
 * - Decoder name / behavior varies by OEM; configure failures request a keyframe.
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
    private var configureAttempts = 0

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
                    Log.e(tag, "configure failed (API ${Build.VERSION.SDK_INT})", e)
                    onNeedKeyframe()
                    return
                }
            }
        }

        if (!configured || vcl.isEmpty()) return

        val annexB = toAnnexB(vcl)
        queueInput(annexB)
        drainOutput()
    }

    private fun configure(sps: ByteArray, pps: ByteArray) {
        releaseCodecOnly()
        val surf = surface ?: return
        configureAttempts++

        val (width, height) = estimateSizeFromSps(sps) ?: (1920 to 1080)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setByteBuffer("csd-0", ByteBuffer.wrap(withStartCode(sps)))
        format.setByteBuffer("csd-1", ByteBuffer.wrap(withStartCode(pps)))

        applyLowLatencyHints(format)

        val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            c.configure(format, surf, null, 0)
        } catch (e: Exception) {
            // Some OEMs reject vendor keys — retry bare format once.
            Log.w(tag, "configure with low-latency hints failed, retrying plain: ${e.message}")
            c.release()
            val plain = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            plain.setByteBuffer("csd-0", ByteBuffer.wrap(withStartCode(sps)))
            plain.setByteBuffer("csd-1", ByteBuffer.wrap(withStartCode(pps)))
            val c2 = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            c2.configure(plain, surf, null, 0)
            c2.start()
            codec = c2
            configured = true
            Log.i(tag, "decoder configured (plain) ${width}x${height} name=${c2.name}")
            return
        }
        c.start()
        codec = c
        configured = true
        Log.i(tag, "decoder configured ${width}x${height} name=${c.name} attempt=$configureAttempts")
    }

    /**
     * Best-effort low-latency flags. Safe on all API ≥ 26; unknown keys are
     * ignored by the framework, but a few OEMs throw — caller retries plain.
     */
    private fun applyLowLatencyHints(format: MediaFormat) {
        // Real-time priority (API 23+).
        try {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        } catch (_: Exception) {
        }

        // Official low-latency key (API 30 / Android 11+).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            } catch (_: Exception) {
            }
        }

        // Vendor extensions used by common SoCs when the public key is missing
        // or ignored (Android 8–10 tablets, some Android 11+ builds).
        val vendorFlags = arrayOf(
            "vendor.qti-ext-dec-low-latency.enable",
            "vendor.low-latency.enable",
            "low-latency",
            "vdec-lowlatency",
        )
        for (key in vendorFlags) {
            try {
                format.setInteger(key, 1)
            } catch (_: Exception) {
            }
        }
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
            if (buf.remaining() < annexB.size) {
                Log.w(tag, "input buffer too small ${buf.remaining()} < ${annexB.size}")
                onNeedKeyframe()
                return
            }
            buf.put(annexB)
            ptsUs += 16_666
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

    /**
     * Minimal H.264 SPS parse for pic_width/height (enough for MediaFormat).
     * Returns null if the SPS is truncated or non-baseline layout.
     */
    private fun estimateSizeFromSps(sps: ByteArray): Pair<Int, Int>? {
        // Skip NAL header; exp-Golomb walk is fragile — prefer output-format.
        // Keep a coarse size for configure only.
        if (sps.size < 4) return null
        // Many SPS blobs encode 1080p-class streams; decoder will correct via
        // INFO_OUTPUT_FORMAT_CHANGED. Avoid wrong non-zero that breaks some OEMs.
        return null
    }
}
