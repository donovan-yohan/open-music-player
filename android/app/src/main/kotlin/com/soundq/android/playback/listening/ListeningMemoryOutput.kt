package com.soundq.android.playback.listening

import android.media.AudioDeviceInfo
import android.media.AudioFormat
import androidx.media3.common.C
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackParameters
import androidx.media3.exoplayer.audio.AudioOutput
import androidx.media3.exoplayer.audio.AudioOutputProvider
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Bounded destination for the sink's already trimmed/resampled stereo 48k PCM16.
 * No AudioTrack, clock, executor or decoded-source preload. All access is lane-worker confined.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ListeningMemoryOutput(
    val capacityFrames: Int = 32768,
    private val valid: () -> Boolean,
) : AudioOutput {
    internal class Window internal constructor(val startFrame: Long, private val bytes: ByteArray) {
        val frameCount: Int get() = bytes.size / 8
        val stereoFloatLE: ByteBuffer get() = ByteBuffer.wrap(bytes).asReadOnlyBuffer().order(ByteOrder.LITTLE_ENDIAN)
    }

    init { require(capacityFrames in 1..32768) }
    private val ring = FloatArray(capacityFrames * 2)
    private var head = 0
    var bufferedFrames = 0; private set
    var acceptedFrames = 0L; private set
    var highWaterFrames = 0; private set
    private var takenFrames = 0L
    private var outputFrames = 0L
    private var retired = false
    private var released = false
    private var initialized = false
    private val listeners = mutableSetOf<AudioOutput.Listener>()

    val provider: AudioOutputProvider = object : AudioOutputProvider {
        override fun getFormatSupport(config: AudioOutputProvider.FormatConfig): AudioOutputProvider.FormatSupport {
            val f = config.format
            if (f.sampleMimeType != MimeTypes.AUDIO_RAW || f.channelCount !in 1..2 || f.sampleRate <= 0 ||
                config.enableOffload || config.enableTunneling) return AudioOutputProvider.FormatSupport.UNSUPPORTED
            val level = when (f.pcmEncoding) {
                C.ENCODING_PCM_16BIT -> AudioOutputProvider.FORMAT_SUPPORTED_DIRECTLY
                C.ENCODING_PCM_FLOAT, C.ENCODING_PCM_24BIT, C.ENCODING_PCM_32BIT, C.ENCODING_PCM_8BIT ->
                    AudioOutputProvider.FORMAT_SUPPORTED_WITH_TRANSCODING
                else -> return AudioOutputProvider.FormatSupport.UNSUPPORTED
            }
            return AudioOutputProvider.FormatSupport.Builder().setFormatSupportLevel(level).build()
        }
        override fun getOutputConfig(config: AudioOutputProvider.FormatConfig): AudioOutputProvider.OutputConfig {
            val f = config.format
            if (f.sampleMimeType != MimeTypes.AUDIO_RAW || f.pcmEncoding != C.ENCODING_PCM_16BIT ||
                f.sampleRate != 48000 || f.channelCount != 2 || config.enableOffload || config.enableTunneling ||
                config.enablePlaybackParameters) throw AudioOutputProvider.ConfigurationException("Expected normalized stereo 48k PCM16")
            return AudioOutputProvider.OutputConfig.Builder().setEncoding(C.ENCODING_PCM_16BIT)
                .setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setBufferSize(capacityFrames * 4).setAudioAttributes(config.audioAttributes)
                .setAudioSessionId(C.AUDIO_SESSION_ID_UNSET).setIsOffload(false).setIsTunneling(false)
                .setUsePlaybackParameters(false).setUseOffloadGapless(false).build()
        }
        override fun getAudioOutput(config: AudioOutputProvider.OutputConfig): AudioOutput {
            check(!initialized && !retired && !released && valid()) { "Memory output cannot be rebound" }
            require(config.encoding == C.ENCODING_PCM_16BIT && config.sampleRate == 48000 &&
                config.channelMask == AudioFormat.CHANNEL_OUT_STEREO && !config.isOffload && !config.isTunneling)
            initialized = true
            return this@ListeningMemoryOutput
        }
        override fun addListener(listener: AudioOutputProvider.Listener) = Unit
        override fun removeListener(listener: AudioOutputProvider.Listener) = Unit
        override fun release() = this@ListeningMemoryOutput.release()
    }

    override fun write(buffer: ByteBuffer, accessUnitCount: Int, presentationTimeUs: Long): Boolean {
        check(!retired && !released && valid()) { "Decode owner retired" }
        require(buffer.remaining() % 4 == 0) { "Partial PCM frame" }
        // accessUnitCount is NOT a byte length. The pinned sink passes encoded access units.
        val frames = minOf(buffer.remaining() / 4, capacityFrames - bufferedFrames)
        val pcm = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        repeat(frames) { i ->
            val index = ((head + bufferedFrames + i) % capacityFrames) * 2
            ring[index] = pcm.short.toFloat() / 32768f
            ring[index + 1] = pcm.short.toFloat() / 32768f
        }
        check(valid()) { "Decode owner retired during write" }
        buffer.position(pcm.position())
        bufferedFrames += frames
        acceptedFrames = Math.addExact(acceptedFrames, frames.toLong())
        outputFrames += frames
        highWaterFrames = maxOf(highWaterFrames, bufferedFrames)
        return !buffer.hasRemaining()
    }

    fun take(maxFrames: Int): Window? {
        require(maxFrames in 1..capacityFrames)
        check(!retired && valid()) { "Decode owner retired" }
        val count = minOf(maxFrames, bufferedFrames)
        if (count == 0) return null
        val bytes = ByteArray(count * 8)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        repeat(count) { i ->
            val index = ((head + i) % capacityFrames) * 2
            b.putFloat(ring[index]).putFloat(ring[index + 1])
        }
        check(valid()) { "Decode owner retired during publication" }
        val window = Window(takenFrames, bytes)
        takenFrames += count
        head = (head + count) % capacityFrames
        bufferedFrames -= count
        return window
    }

    fun retire() { retired = true; ring.fill(0f); bufferedFrames = 0 }
    override fun play() = Unit
    override fun pause() = Unit
    override fun stop() = Unit // accepted memory is already consumed by this destination.
    override fun flush() { check(acceptedFrames == 0L || retired) { "Sequential lane cannot flush published PCM" }; outputFrames = 0 }
    override fun release() { if (!released) { released = true; listeners.toList().forEach { it.onReleased() }; listeners.clear() } }
    // Ceil to microseconds. The sink floors its inverse and would otherwise retain one pending frame.
    override fun getPositionUs(): Long = outputFrames / 48000 * 1_000_000L +
        (outputFrames % 48000 * 1_000_000L + 47999) / 48000 // NEVER heard time.
    override fun getBufferSizeInFrames(): Long = capacityFrames.toLong()
    override fun getSampleRate() = 48000
    override fun getAudioSessionId() = C.AUDIO_SESSION_ID_UNSET
    override fun isOffloadedPlayback() = false
    override fun isStalled() = false
    override fun getPlaybackParameters(): PlaybackParameters = PlaybackParameters.DEFAULT
    override fun setPlaybackParameters(parameters: PlaybackParameters) { require(parameters == PlaybackParameters.DEFAULT) }
    override fun setVolume(volume: Float) { require(volume == 1f) }
    override fun addListener(listener: AudioOutput.Listener) { listeners.add(listener) }
    override fun removeListener(listener: AudioOutput.Listener) { listeners.remove(listener) }
    override fun setOffloadDelayPadding(delay: Int, padding: Int) { error("Offload unsupported") }
    override fun setOffloadEndOfStream() { error("Offload unsupported") }
    override fun attachAuxEffect(effectId: Int) { require(effectId == 0) }
    override fun setAuxEffectSendLevel(level: Float) { require(level == 0f) }
    override fun setPreferredDevice(device: AudioDeviceInfo?) { require(device == null) }
}
