package com.soundq.android.playback.listening

import android.content.Context
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Timeline
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.Clock
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import androidx.media3.decoder.DecoderInputBuffer
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.LoadingInfo
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.RendererConfiguration
import androidx.media3.exoplayer.analytics.PlayerId
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import java.nio.ByteBuffer
import androidx.media3.exoplayer.source.BundledExtractorsAdapter
import androidx.media3.exoplayer.source.MediaPeriod
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaExtractor
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.SampleStream
import androidx.media3.exoplayer.trackselection.ExoTrackSelection
import androidx.media3.exoplayer.trackselection.FixedTrackSelection
import androidx.media3.exoplayer.upstream.BandwidthMeter
import androidx.media3.exoplayer.upstream.DefaultAllocator
import androidx.media3.extractor.DefaultExtractorsFactory
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Sequential, one-source MP3 experiment. Not a Player, public clock, random-seek API or service.
 * Caller supplies an already authorized factory and a thread-safe captured validity predicate.
 * Ordinary callers must supply SignedAudioDataSource unchanged. Only one next() may be outstanding.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class Media3ListeningLane(
    context: Context,
    private val uri: Uri,
    private val factory: DataSource.Factory,
    private val capturedValid: () -> Boolean,
    capacityFrames: Int = 32768,
) {
    data class Evidence(
        val inputRate: Int, val inputChannels: Int, val encoderDelay: Int, val encoderPadding: Int,
        val decoderOutput: String?, val sonicInputBytes: Long, val normalizedFrames: Long,
        val ringHighWaterFrames: Int, val encodedAllocatorHighWaterBytes: Int,
        val decoderPcmFrames: Long, val decoderOnlyFrames: Long, val sonicInputFrameCount: Long,
    )
    data class DrainReceipt(val extractorReleases: Int, val openSources: Int, val readsInFlight: Int)
    private val retired = AtomicBoolean(false)
    init { require(capacityFrames in 1..32768) } // Validate before starting any owned thread.
    private val readPending = AtomicBoolean(false)
    private val openSources = AtomicInteger()
    private val readsInFlight = AtomicInteger()
    private val extractors = AtomicInteger()
    private val extractorReleases = AtomicInteger()
    private val drained = CompletableFuture<DrainReceipt>()
    private var cleanupFailure: Throwable? = null
    private val worker = object : HandlerThread("soundq-mp3-memory-lane") {
        override fun run() {
            try { super.run() } finally {
                val failure = cleanupFailure
                if (failure == null) drained.complete(DrainReceipt(extractorReleases.get(), openSources.get(), readsInFlight.get()))
                else drained.completeExceptionally(failure)
            }
        }
    }.also { it.start() }
    private val handler = Handler(worker.looper)
    private val memory = ListeningMemoryOutput(capacityFrames) { !retired.get() && capturedValid() }
    private val allocator = DefaultAllocator(true, 16384)
    private val sonic = SonicAudioProcessor().apply { setOutputSampleRateHz(48000); setSpeed(1f); setPitch(1f) }
    private var source: MediaSource? = null
    private var period: MediaPeriod? = null
    private var renderer: MediaCodecAudioRenderer? = null
    private var inputFormat: Format? = null
    private var decoderOutput: String? = null
    private var decoderPcmFrames = 0L
    private var decoderOnlyFrames = 0L
    private var decoderBytesPerFrame = 0
    private var codecBufferIndex = -1
    private var codecBufferRemaining = 0
    private var ready = false
    private var ended = false
    private var cleanupStarted = false
    private var allocatorHighWater = 0
    private var consumedSourceUs = C.TIME_UNSET
    private var pending: CompletableFuture<ListeningMemoryOutput.Window?>? = null
    private var requestedFrames = 0
    private var terminalFailure: Throwable? = null
    private val caller = MediaSource.MediaSourceCaller { _, timeline -> guarded { onTimeline(timeline) } }
    private val pumpTask = Runnable { guarded { pump() } }

    init { handler.post { guarded { prepare(context.applicationContext) } } }

    @Synchronized
    fun next(maxFrames: Int = minOf(2048, memory.capacityFrames)): CompletableFuture<ListeningMemoryOutput.Window?> {
        require(maxFrames in 1..memory.capacityFrames)
        check(!retired.get() && capturedValid()) { "Decode owner retired" }
        check(readPending.compareAndSet(false, true)) { "Only one sequential read may be outstanding" }
        val result = CompletableFuture<ListeningMemoryOutput.Window?>()
        handler.post {
            if (terminalFailure != null) {
                readPending.set(false); result.completeExceptionally(terminalFailure!!)
            } else if (retired.get() || !capturedValid()) {
                readPending.set(false); result.completeExceptionally(IllegalStateException("Decode owner retired"))
                retireAndDrain()
            } else {
                pending = result; requestedFrames = maxFrames
                guarded { pump() }
            }
        }
        return result
    }

    /** Evidence read on the same lane worker. It does not certify a playable extent. */
    @Synchronized
    fun evidence(): CompletableFuture<Evidence> {
        check(!retired.get())
        val result = CompletableFuture<Evidence>()
        handler.post {
            val f = inputFormat
            if (f == null) result.completeExceptionally(IllegalStateException("No admitted input format"))
            else result.complete(Evidence(f.sampleRate, f.channelCount, f.encoderDelay, f.encoderPadding,
                decoderOutput, sonic.processedInputBytes, memory.acceptedFrames, memory.highWaterFrames, allocatorHighWater,
                decoderPcmFrames, decoderOnlyFrames, sonic.processedInputBytes / 4))
        }
        return result
    }

    /** Revokes synchronously. Completion is after real extractor/read/close and worker termination. */
    @Synchronized
    fun retireAndDrain(): CompletableFuture<DrainReceipt> {
        if (retired.compareAndSet(false, true)) handler.post { cleanup() }
        return drained
    }

    private inline fun guarded(body: () -> Unit) {
        if (retired.get()) return
        try {
            check(capturedValid()) { "Decode owner retired" }
            body()
        } catch (failure: Exception) {
            terminalFailure = failure
            pending?.completeExceptionally(failure); pending = null; readPending.set(false)
            retireAndDrain()
        }
    }

    private fun prepare(context: Context) {
        val sink = actualLaneSink(context, memory, sonic)
        renderer = object : MediaCodecAudioRenderer(context, MediaCodecSelector.DEFAULT, handler, null, sink) {
            override fun onOutputFormatChanged(format: Format, mediaFormat: MediaFormat?) {
                decoderOutput = mediaFormat?.toString() ?: format.toString()
                val outputChannels = mediaFormat?.getInteger(MediaFormat.KEY_CHANNEL_COUNT) ?: format.channelCount
                val encoding = if (mediaFormat?.containsKey(MediaFormat.KEY_PCM_ENCODING) == true)
                    mediaFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) else C.ENCODING_PCM_16BIT
                decoderBytesPerFrame = outputChannels * when (encoding) {
                    C.ENCODING_PCM_16BIT -> 2
                    C.ENCODING_PCM_FLOAT, C.ENCODING_PCM_32BIT -> 4
                    C.ENCODING_PCM_24BIT -> 3
                    C.ENCODING_PCM_8BIT -> 1
                    else -> error("Unsupported decoder PCM encoding $encoding")
                }
                // Normalize only this decoder's native PCM coordinate contract. The renderer
                // still configures DefaultAudioSink and owns trim exactly once before Sonic.
                super.onOutputFormatChanged(mp3DecoderTrimFormat(format, codecInfo?.name), mediaFormat)
            }
            override fun processOutputBuffer(
                positionUs: Long, elapsedRealtimeUs: Long, codec: MediaCodecAdapter?, buffer: ByteBuffer?,
                bufferIndex: Int, bufferFlags: Int, sampleCount: Int, presentationTimeUs: Long,
                isDecodeOnlyBuffer: Boolean, isLastBuffer: Boolean, format: Format,
            ): Boolean {
                if (codecBufferIndex != bufferIndex) {
                    codecBufferIndex = bufferIndex; codecBufferRemaining = buffer?.remaining() ?: 0
                }
                val consumed = super.processOutputBuffer(positionUs, elapsedRealtimeUs, codec, buffer,
                    bufferIndex, bufferFlags, sampleCount, presentationTimeUs, isDecodeOnlyBuffer, isLastBuffer, format)
                if (consumed) {
                    check(decoderBytesPerFrame > 0 && codecBufferRemaining % decoderBytesPerFrame == 0)
                    val frames = codecBufferRemaining / decoderBytesPerFrame
                    decoderPcmFrames += frames
                    if (isDecodeOnlyBuffer) decoderOnlyFrames += frames
                    codecBufferIndex = -1
                }
                return consumed
            }
        }.apply { init(0, PlayerId.UNSET, Clock.DEFAULT) }
        val extractorsFactory = ProgressiveMediaExtractor.Factory {
            extractors.incrementAndGet()
            val actual = BundledExtractorsAdapter(DefaultExtractorsFactory())
            object : ProgressiveMediaExtractor by actual {
                override fun release() {
                    actual.release()
                    extractorReleases.incrementAndGet(); extractors.decrementAndGet()
                    handler.post { finishDrainIfReady() }
                }
            }
        }
        source = ProgressiveMediaSource.Factory(DataSource.Factory { trackedSource() }, extractorsFactory)
            .setContinueLoadingCheckIntervalBytes(16384).setLoadOnlySelectedTracks(true)
            .createMediaSource(MediaItem.fromUri(uri))
        source!!.prepareSource(caller, PlayerId.UNSET, BandwidthMeter.NO_OP)
    }

    private fun onTimeline(timeline: Timeline) {
        if (period != null || timeline.isEmpty) return
        val id = MediaSource.MediaPeriodId(timeline.getUidOfPeriod(0))
        val p = source!!.createPeriod(id, allocator, 0)
        period = p
        p.prepare(object : MediaPeriod.Callback {
            override fun onPrepared(mediaPeriod: MediaPeriod) = guarded {
                val groups = mediaPeriod.trackGroups
                check(groups.length == 1 && groups[0].length == 1) { "Expected one MP3 audio track" }
                val f = groups[0].getFormat(0)
                check(f.sampleMimeType == MimeTypes.AUDIO_MPEG && f.sampleRate in 8000..48000 &&
                    f.channelCount in 1..2 && f.drmInitData == null) { "Only clear mono/stereo MP3 admitted" }
                inputFormat = f
                val streams = arrayOfNulls<SampleStream>(1)
                mediaPeriod.selectTracks(arrayOf<ExoTrackSelection?>(FixedTrackSelection(groups[0], 0)),
                    booleanArrayOf(false), streams, booleanArrayOf(false), 0)
                val selected = checkNotNull(streams[0])
                val consumedStream = object : SampleStream by selected {
                    override fun readData(holder: FormatHolder, buffer: DecoderInputBuffer, readFlags: Int): Int {
                        val result = selected.readData(holder, buffer, readFlags)
                        // Source-domain consumption only. Format, peek and EOS reads confer no watermark.
                        if (result == C.RESULT_BUFFER_READ && readFlags and SampleStream.FLAG_PEEK == 0 &&
                            !buffer.isEndOfStream && buffer.timeUs != C.TIME_UNSET) {
                            consumedSourceUs = if (consumedSourceUs == C.TIME_UNSET) buffer.timeUs
                                else maxOf(consumedSourceUs, buffer.timeUs)
                        }
                        return result
                    }
                }
                renderer!!.setTimeline(timeline)
                renderer!!.enable(RendererConfiguration.DEFAULT, arrayOf(f), consumedStream,
                    0, false, true, 0, 0, id)
                renderer!!.setCurrentStreamFinal()
                renderer!!.start()
                ready = true
                if (pending != null) pump()
            }
            override fun onContinueLoadingRequested(mediaPeriod: MediaPeriod) = guarded {
                // Preparation needs metadata. Thereafter demand and encoded high-water own loading.
                if (!ready || pending != null) continueLoading()
                if (pending != null) schedulePump(0)
            }
        }, 0)
    }

    private fun continueLoading() {
        allocatorHighWater = maxOf(allocatorHighWater, allocator.totalBytesAllocated)
        // Pinned ProgressiveMediaPeriod stops enabled queues at their read position and retains
        // the sample at/before this timestamp. Release only earlier consumed allocations, on worker.
        // This private retirement watermark is neither renderer position nor a playable clock.
        if (consumedSourceUs != C.TIME_UNSET) period?.discardBuffer(consumedSourceUs, false)
        if (allocator.totalBytesAllocated < 262144) period?.continueLoading(
            LoadingInfo.Builder().setPlaybackPositionUs(0).setPlaybackSpeed(1f).build())
    }

    private fun pump() {
        val result = pending ?: return
        if (result.isCancelled) { pending = null; readPending.set(false); retireAndDrain(); return }
        source?.maybeThrowSourceInfoRefreshError()
        period?.maybeThrowPrepareError()
        if (ready && !ended) {
            continueLoading()
            check(period!!.readDiscontinuity() == C.TIME_UNSET) { "Sequential decode encountered a source discontinuity" }
            renderer!!.maybeThrowStreamError()
            // Never advance position to decode PTS. That could mark requested source samples decode-only.
            renderer!!.render(0, SystemClock.elapsedRealtime() * 1000)
            ended = renderer!!.isEnded
        }
        synchronized(this) {
            val window = memory.take(requestedFrames)
            if (window != null || ended) {
                check(!retired.get() && capturedValid()) { "Decode owner retired before publication" }
                pending = null; readPending.set(false); result.complete(window)
            } else {
                // MediaCodec offers no public synchronous output-ready callback to this renderer driver.
                // Bounded delayed retry only while demand exists; ring-full never spins.
                schedulePump(5)
            }
        }
    }

    private fun schedulePump(delayMs: Long) {
        handler.removeCallbacks(pumpTask)
        handler.postDelayed(pumpTask, delayMs)
    }

    private fun trackedSource(): DataSource {
        val actual = factory.createDataSource()
        return object : DataSource by actual {
            private var opened = false
            override fun open(dataSpec: DataSpec): Long {
                check(!retired.get() && capturedValid()) { "Decode owner retired before source open" }
                check(!opened)
                opened = true; openSources.incrementAndGet()
                return actual.open(dataSpec) // failed open still owes close.
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                check(!retired.get() && capturedValid()) { "Decode owner retired before source read" }
                readsInFlight.incrementAndGet()
                try { return actual.read(buffer, offset, length) } finally {
                    readsInFlight.decrementAndGet(); handler.post { finishDrainIfReady() }
                }
            }
            override fun close() {
                actual.close() // failed close retains custody and cannot issue a success receipt.
                if (opened) { opened = false; openSources.decrementAndGet() }
                handler.post { finishDrainIfReady() }
            }
        }
    }

    private fun cleanup() {
        cleanupStarted = true
        handler.removeCallbacks(pumpTask)
        pending?.completeExceptionally(IllegalStateException("Decode owner retired")); pending = null; readPending.set(false)
        memory.retire()
        fun release(body: () -> Unit) {
            try { body() } catch (failure: Exception) {
                if (cleanupFailure == null) cleanupFailure = failure else cleanupFailure!!.addSuppressed(failure)
            }
        }
        renderer?.let { r ->
            if (r.state == Renderer.STATE_STARTED) release { r.stop() }
            if (r.state == Renderer.STATE_ENABLED) release { r.disable() }
            release { r.reset() }; release { r.release() }
        }
        period?.let { p -> release { source!!.releasePeriod(p) } }
        source?.let { s -> release { s.releaseSource(caller) } }
        memory.release()
        finishDrainIfReady()
    }

    private fun finishDrainIfReady() {
        if (cleanupStarted && extractors.get() == 0 && openSources.get() == 0 && readsInFlight.get() == 0) {
            allocator.reset()
            worker.quitSafely()
        }
    }
}
