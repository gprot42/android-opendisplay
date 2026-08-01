package app.opendisplay.receiver.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Plays Mac → device PCM from wire `AUD1` frames (s16le mono @ 48 kHz).
 */
class AudioPlayer {
    private val tag = "AudioPlayer"
    private var track: AudioTrack? = null
    private val released = AtomicBoolean(false)
    private var sampleRate = 48_000
    private var channels = 1

    fun feed(payload: ByteArray) {
        if (released.get()) return
        if (payload.size < 12) return
        // "AUD1"
        if (payload[0] != 'A'.code.toByte() ||
            payload[1] != 'U'.code.toByte() ||
            payload[2] != 'D'.code.toByte() ||
            payload[3] != '1'.code.toByte()
        ) {
            return
        }
        val ver = payload[4].toInt() and 0xff
        if (ver != 1) return
        val ch = payload[5].toInt() and 0xff
        val sr = ((payload[6].toInt() and 0xff) shl 8) or (payload[7].toInt() and 0xff)
        val frameCount =
            ((payload[8].toInt() and 0xff) shl 24) or
                ((payload[9].toInt() and 0xff) shl 16) or
                ((payload[10].toInt() and 0xff) shl 8) or
                (payload[11].toInt() and 0xff)
        val pcmOffset = 12
        val expectedBytes = frameCount * ch * 2
        if (frameCount <= 0 || pcmOffset + expectedBytes > payload.size) return

        ensureTrack(sr, ch)
        val t = track ?: return
        try {
            t.write(payload, pcmOffset, expectedBytes, AudioTrack.WRITE_NON_BLOCKING)
        } catch (e: Exception) {
            Log.w(tag, "write failed: ${e.message}")
        }
    }

    private fun ensureTrack(sr: Int, ch: Int) {
        if (track != null && sampleRate == sr && channels == ch) return
        releaseTrackOnly()
        sampleRate = sr.coerceIn(8_000, 96_000)
        channels = ch.coerceIn(1, 2)
        val channelMask =
            if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBuf =
            AudioTrack.getMinBufferSize(
                sampleRate,
                channelMask,
                AudioFormat.ENCODING_PCM_16BIT,
            ).coerceAtLeast(sampleRate / 10 * channels * 2) // ~100ms
        try {
            val t =
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sampleRate)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(channelMask)
                            .build(),
                    )
                    .setBufferSizeInBytes(minBuf * 2)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
            t.play()
            track = t
            Log.i(tag, "AudioTrack ${sampleRate}Hz ch=$channels buf=$minBuf")
        } catch (e: Exception) {
            Log.e(tag, "AudioTrack create failed", e)
            track = null
        }
    }

    fun stop() {
        releaseTrackOnly()
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        releaseTrackOnly()
    }

    private fun releaseTrackOnly() {
        try {
            track?.pause()
            track?.flush()
            track?.stop()
            track?.release()
        } catch (_: Exception) {
        }
        track = null
    }

    companion object {
        fun isAudioFrame(payload: ByteArray): Boolean {
            if (payload.size < 4) return false
            return payload[0] == 'A'.code.toByte() &&
                payload[1] == 'U'.code.toByte() &&
                payload[2] == 'D'.code.toByte() &&
                payload[3] == '1'.code.toByte()
        }
    }
}
