package com.soundq.android.playback.nativeengine

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import com.soundq.android.data.device.AndroidAudioAccess
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CancellationException

/** Finite Android platform decode to exact-length immutable source PCM. No output/player here.
 * Called only by source preparation on IO. Native's existing WorkerDeck reads bounded windows.
 * Preparation is whole-file and may take time; memory is bounded, disk admission is explicit.
 */
internal object AndroidPlatformAudioStage {
    const val MAX_PCM_BYTES = 16L * 1024 * 1024 * 1024
    const val MAX_DURATION_SECONDS = 24L * 60 * 60
    fun decode(encoded: File, directory: File, current: () -> Boolean): File {
        val stage = File.createTempFile("phone-pcm-", ".sqpcm", directory)
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var started = false
        var accepted = false
        fun checkCurrent() { if (!current()) throw CancellationException("Phone decode retired") }
        try {
            checkCurrent()
            extractor.setDataSource(encoded.absolutePath)
            val audio = (0 until extractor.trackCount).filter { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
            require(audio.size == 1) { "A single audio stream is required" }
            val track = audio.single(); extractor.selectTrack(track)
            val inputFormat = extractor.getTrackFormat(track)
            val mime = requireNotNull(inputFormat.getString(MediaFormat.KEY_MIME))
            require(mime in SUPPORTED_MIMES) { "Audio format not supported" }
            inputFormat.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(inputFormat, null, null, 0); codec.start(); started = true
            val info = MediaCodec.BufferInfo()
            var inputEnded = false; var outputEnded = false
            var rate = 0; var channels = 0; var encoding = AudioFormat.ENCODING_PCM_16BIT
            var frames = 0L
            var lastProgress = System.nanoTime()
            val floats = ByteBuffer.allocate(8192 * 8).order(ByteOrder.LITTLE_ENDIAN)
            RandomAccessFile(stage, "rw").use { output ->
                output.setLength(32); output.seek(32)
                while (!outputEnded) {
                    checkCurrent()
                    check(System.nanoTime() - lastProgress < 30_000_000_000L) { "Audio decoder made no progress" }
                    if (!inputEnded) {
                        val index = codec.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = requireNotNull(codec.getInputBuffer(index)); buffer.clear()
                            val count = extractor.readSampleData(buffer, 0)
                            if (count < 0) { codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnded = true }
                            else {
                                require(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED == 0) { "Protected audio is not supported" }
                                codec.queueInputBuffer(index, 0, count, extractor.sampleTime, 0); extractor.advance()
                            }
                            lastProgress = System.nanoTime()
                        }
                    }
                    val index = codec.dequeueOutputBuffer(info, 10_000)
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val format = codec.outputFormat
                        val nextRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        val nextChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        require(nextRate in 8000..192000 && nextChannels in 1..2)
                        require(rate == 0 || (rate == nextRate && channels == nextChannels)) { "Changing audio format is unsupported" }
                        rate = nextRate; channels = nextChannels
                        encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) format.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                        require(encoding in setOf(AudioFormat.ENCODING_PCM_16BIT, AudioFormat.ENCODING_PCM_FLOAT))
                        lastProgress = System.nanoTime()
                    } else if (index >= 0) {
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                require(rate > 0 && channels > 0)
                                val buffer = requireNotNull(codec.getOutputBuffer(index)).duplicate().order(ByteOrder.LITTLE_ENDIAN)
                                buffer.position(info.offset); buffer.limit(Math.addExact(info.offset, info.size))
                                val unit = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
                                require(info.size % (unit * channels) == 0)
                                val count = info.size / (unit * channels)
                                frames = Math.addExact(frames, count.toLong())
                                require(frames <= rate.toLong() * MAX_DURATION_SECONDS && frames * 8 <= MAX_PCM_BYTES)
                                require(directory.usableSpace > AndroidAudioAccess.DISK_RESERVE_BYTES + count.toLong() * 8)
                                while (buffer.hasRemaining()) {
                                    floats.clear()
                                    repeat(minOf(8192, buffer.remaining() / (unit * channels))) {
                                        fun sample(): Float = (if (unit == 4) buffer.float else buffer.short.toFloat() / 32768f).also { require(it.isFinite()) }
                                        val left = sample(); val right = if (channels == 1) left else sample()
                                        floats.putFloat(left); floats.putFloat(right)
                                    }
                                    output.write(floats.array(), 0, floats.position())
                                    checkCurrent()
                                }
                            }
                            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            lastProgress = System.nanoTime()
                        } finally { codec.releaseOutputBuffer(index, false) }
                    }
                }
                require(frames > 0 && rate > 0)
                val header = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN)
                    .put("SQP1".toByteArray(Charsets.US_ASCII)).putInt(32).putInt(rate).putInt(2).putLong(frames).putLong(0).array()
                output.seek(0); output.write(header); output.fd.sync()
                require(output.length() == 32 + frames * 8)
            }
            checkCurrent(); accepted = true; return stage
        } finally {
            try { if (started) runCatching { codec?.stop() }; codec?.release() }
            finally { extractor.release(); if (!accepted) stage.delete() }
        }
    }
    // Android decoder availability is device-dependent; no ALAC/AIFF/DRM/multichannel promise.
    private val SUPPORTED_MIMES = setOf("audio/mp4a-latm", "audio/aac", "audio/flac", "audio/raw", "audio/mpeg", "audio/opus", "audio/vorbis")
}
