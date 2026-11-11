package com.soundq.android.playback.listening

import android.content.Context
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink

/** Media3 1.11.1 XingFrame expresses trims in delayed-decoder PCM coordinates. Android's
 * c2.android.mp3.decoder instead removes its 529-frame synthesis delay and appends 529 zeros.
 * Translate the same half-open source interval, never a duration or measured output count.
 * Other codec contracts stay untouched. This is not qualification of vendor decoder behavior.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun mp3DecoderTrimFormat(format: androidx.media3.common.Format, codecName: String?): androidx.media3.common.Format {
    if (codecName != "c2.android.mp3.decoder" || format.sampleMimeType != androidx.media3.common.MimeTypes.AUDIO_MPEG ||
        (format.encoderDelay == 0 && format.encoderPadding == 0)) return format
    // AOSP C2SoftMp3Dec::process kPVMP3DecoderDelay and pinned XingFrame's
    // LAME_TO_DECODED_PCM_TRIM_OFFSET_SAMPLES are both 528 + 1, not a fitted sample shift.
    val synthesisDelay = 528 + 1
    require(format.encoderDelay >= synthesisDelay && format.encoderPadding >= 0) {
        "MP3 trim interval precedes C2 decoder output"
    }
    return format.buildUpon().setEncoderDelay(format.encoderDelay - synthesisDelay)
        .setEncoderPadding(Math.addExact(format.encoderPadding, synthesisDelay)).build()
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun actualLaneSink(context: Context, memory: ListeningMemoryOutput, sonic: SonicAudioProcessor): AudioSink {
    val channels = ChannelMixingAudioProcessor().apply {
        // Explicit constant-power mono expansion. PCM16 quantization is intentional, not lossless.
        putChannelMixingMatrix(ChannelMixingMatrix.createForConstantPower(1, 2))
        putChannelMixingMatrix(ChannelMixingMatrix.createForConstantPower(2, 2))
    }
    return FinalStreamAudioSink(DefaultAudioSink.Builder(context).setEnableFloatOutput(false)
        .setEnableAudioOutputPlaybackParameters(false).setAudioProcessors(arrayOf(channels, sonic))
        .setAudioOutputProvider(memory.provider).build())
}

/** One finite stream. configure at terminal EOS declares a real gapless boundary to Media3's
 * trimming processor. It only stages configuration. Never flush or submit another buffer afterward,
 * so accepted PCM, Sonic phase and pending output survive every backpressured EOS retry.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private class FinalStreamAudioSink(sink: AudioSink) : androidx.media3.exoplayer.audio.ForwardingAudioSink(sink) {
    private var config: AudioSink.AudioSinkConfig? = null
    private var terminal = false

    override fun configure(audioSinkConfig: AudioSink.AudioSinkConfig) {
        check(!terminal) { "Finite stream already ended" }
        super.configure(audioSinkConfig)
        config = audioSinkConfig
    }

    override fun handleBuffer(buffer: java.nio.ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
        check(!terminal) { "Finite stream already ended" }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
    }

    override fun playToEndOfStream() {
        if (!terminal) {
            val current = checkNotNull(config) { "Finite stream not configured" }
            if (current.format.encoderPadding > 0) super.configure(current)
            terminal = true
        }
        super.playToEndOfStream()
    }
}
