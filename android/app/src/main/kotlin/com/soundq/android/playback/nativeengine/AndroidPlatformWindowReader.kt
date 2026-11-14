package com.soundq.android.playback.nativeengine

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.roundToLong

/** One native WorkerDeck owns this peer. No output device, PCM file or recording-sized buffer.
 * Platform timestamp mapping is anchored by a bounded first output at source zero.
 * Seek uses the extractor index plus <=2 seconds of decoded preroll, never origin replay.
 */
@androidx.annotation.Keep
internal class AndroidPlatformWindowReader(private val source:OriginalAudioReadLease):NativePcmReader {
    private var extractor:MediaExtractor?=null
    private var codec:MediaCodec?=null
    private var started=false
    private var worker:Thread?=null
    @Volatile private var closed=false
    private var rate=0
    private var channels=0
    private var encoding=AudioFormat.ENCODING_PCM_16BIT
    private var inputEnded=false
    private var outputEnded=false
    private var originUs:Long?=null
    private var encodedOriginUs=0L
    private var gaplessTrim=0L
    private var traversalFirst=0L
    private var mp3Frames:Mp3OriginalFrames?=null
    private var nextDecoded:Long?=null
    private var cursor=0L
    @Volatile private var exactEnd=0L
    @Volatile private var confirmedLong=false
    private var pendingIndex=-1
    private var pending:ByteBuffer?=null
    private var pendingFirst=0L
    private var pendingFrames=0
    private var pendingEos=false
    private val info=MediaCodec.BufferInfo()
    private var deadline=0L
    private var operationDecoded=0L
    private var maximumDecoded=0L
    override fun open():Int {
        check(worker==null && !closed);worker=Thread.currentThread()
        begin(4L*192000)
        try {
            val ex=MediaExtractor().also {extractor=it};ex.setDataSource(source)
            val tracks=(0 until ex.trackCount).filter {ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/")==true}
            require(tracks.size==1) {"A single audio stream is required"}
            val track=tracks.single();ex.selectTrack(track)
            val format=ex.getTrackFormat(track)
            val mime=requireNotNull(format.getString(MediaFormat.KEY_MIME))
            require(mime in SUPPORTED_MIMES) {"Audio format not supported"}
            rate=format.getInteger(MediaFormat.KEY_SAMPLE_RATE);channels=format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            require(rate in 8000..192000 && channels in 1..2)
            encodedOriginUs=ex.sampleTime
            val delay=if(format.containsKey(MediaFormat.KEY_ENCODER_DELAY))format.getInteger(MediaFormat.KEY_ENCODER_DELAY)else 0
            val padding=if(format.containsKey(MediaFormat.KEY_ENCODER_PADDING))format.getInteger(MediaFormat.KEY_ENCODER_PADDING)else 0
            if(mime=="audio/mpeg")require(encodedOriginUs>=0 && delay>=0 && padding>=0 && delay.toLong()+padding<=rate*2L) {"Unbounded gapless trim is unsupported"}
            gaplessTrim=if(mime=="audio/mpeg")delay.toLong()+padding else 0
            if(gaplessTrim>0)mp3Frames=Mp3OriginalFrames(source.length,source::readAt,rate,channels)
            format.setInteger(MediaFormat.KEY_PCM_ENCODING,AudioFormat.ENCODING_PCM_16BIT)
            val decoder=MediaCodec.createDecoderByType(mime).also {codec=it}
            decoder.configure(format,null,null,0);decoder.start();started=true
            check(nextBuffer()) {"Audio source has no decoded samples"}
            // Strict >10min bookmark eligibility without decoding the prefix or
            // trusting container duration. One bounded indexed sample witness.
            val thresholdFrame=rate*600L+(rate+999)/1000-1
            confirmedLong=readWindow(thresholdFrame,1,ByteBuffer.allocateDirect(8),eligibilityWitness=true)==1
            seek(0)
            source.checkCurrent();return rate
        } catch(error:Throwable) {closeReader();throw error}
    }
    private fun begin(frames:Long) {
        source.beginOperation();deadline=System.nanoTime()+15_000_000_000L
        operationDecoded=0;maximumDecoded=frames
    }
    private fun checkWorker() {
        check(worker===Thread.currentThread() && !closed)
        // Full original/version/route checks are IO: beginOperation, every
        // positioned read, mapped EOS and the final pre-publication check own
        // those fences. Do not issue provider/stat IPC per codec buffer. Cheap
        // retirement/failure flags still abort promptly, preserving its error.
        if(!source.active)source.checkCurrent()
    }
    override fun read(first:Long,count:Int,destination:ByteBuffer):Int=readWindow(first,count,destination)
    private fun readWindow(first:Long,count:Int,destination:ByteBuffer,eligibilityWitness:Boolean=false):Int {
        checkWorker();require(first>=0 && count in 1..48000 && destination.isDirect && destination.capacity()>=count*8)
        require(first<=rate.toLong()*24*60*60) {"Source seek exceeds supported duration"}
        begin(count.toLong()+rate*3L)
        if(exactEnd>0 && first>=exactEnd)return 0
        if(first!=cursor)seek(first)
        val out=destination.duplicate().order(ByteOrder.nativeOrder());out.clear()
        var written=0;var skipped=0L
        while(written<count) {
            checkWorker();check(System.nanoTime()<deadline) {"Audio decoder window deadline exceeded"}
            if(pending==null && !nextBuffer(eligibilityWitness))break
            val buffer=requireNotNull(pending)
            val wanted=first+written
            require(pendingFirst<=wanted) {"Platform seek skipped requested source samples"}
            val skip=minOf(pendingFrames.toLong(),wanted-pendingFirst).toInt()
            if(skip>0) {
                skipped+=skip;check(skipped<=rate*2L) {"Platform seek preroll exceeds two seconds"}
                buffer.position(buffer.position()+skip*channels*unit());pendingFirst+=skip;pendingFrames-=skip
            }
            val take=minOf(count-written,pendingFrames)
            repeat(take) {
                fun sample():Float=(if(encoding==AudioFormat.ENCODING_PCM_FLOAT)buffer.float else buffer.short.toFloat()/32768f).also {require(it.isFinite())}
                val left=sample();val right=if(channels==1)left else sample()
                out.putFloat(left);out.putFloat(right)
            }
            written+=take;pendingFirst+=take;pendingFrames-=take;cursor=first+written
            if(pendingFrames==0)releasePending()
        }
        source.checkCurrent()
        // An empty out-of-range witness establishes neither a lower bound nor an
        // exact endpoint. Only open's private probe may accept this outcome; its
        // following seek(0) resets the exhausted decoder before ordinary reads.
        val emptyWitness=eligibilityWitness && written==0 && outputEnded && nextDecoded==null
        check(written==count || emptyWitness || exactEnd>0 && (first+written==exactEnd || written==0 && first>=exactEnd)) {"Short PCM read without qualified decoded EOS"}
        return written
    }
    private fun unit()=if(encoding==AudioFormat.ENCODING_PCM_FLOAT)4 else 2
    private fun seek(first:Long) {
        releasePending(discard=true)
        val ex=requireNotNull(extractor);val decoder=requireNotNull(codec)
        // PREVIOUS_SYNC is not a sample-accurate floor for every extractor (MP3
        // can round forward or report EOS near its tail). Start inside the existing
        // bounded preroll allowance; requested samples still require mapped PCM.
        val indexedFirst=maxOf(0L,first-rate)
        val packets=mp3Frames
        if(packets!=null) {packets.seek(indexedFirst);traversalFirst=packets.sampleFrame}
        else ex.seekTo(indexedFirst*1_000_000L/rate,MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        decoder.flush();inputEnded=false;outputEnded=false;nextDecoded=null;cursor=first
    }
    private fun releasePending(discard:Boolean=false) {
        if(pendingIndex>=0)requireNotNull(codec).releaseOutputBuffer(pendingIndex,false)
        pendingIndex=-1;pending=null;pendingFrames=0
        if(pendingEos && !discard)seal()
        pendingEos=false
    }
    private fun seal() {
        source.checkCurrent()
        val end=requireNotNull(nextDecoded) {"EOS after an unmapped seek is not an exact source endpoint"}
        require(end>0 && (exactEnd==0L || exactEnd==end)) {"Decoded source endpoint changed"}
        exactEnd=end;outputEnded=true
    }
    private fun nextBuffer(eligibilityWitness:Boolean=false):Boolean {
        if(outputEnded)return false
        val ex=requireNotNull(extractor);val decoder=requireNotNull(codec)
        while(true) {
            checkWorker();check(System.nanoTime()<deadline) {"Audio decoder made no bounded progress"}
            if(!inputEnded) {
                val index=decoder.dequeueInputBuffer(1000)
                if(index>=0) {
                    val buffer=requireNotNull(decoder.getInputBuffer(index));buffer.clear()
                    val packets=mp3Frames
                    val count=packets?.read(buffer) ?: ex.readSampleData(buffer,0)
                    if(count<0) {decoder.queueInputBuffer(index,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM);inputEnded=true}
                    else {
                        require(ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED==0) {"Protected audio is not supported"}
                        val time=packets?.sampleFrame?.let {encodedOriginUs+it*1_000_000L/rate} ?: ex.sampleTime
                        decoder.queueInputBuffer(index,0,count,time,0)
                        if(packets!=null)packets.advance()else ex.advance()
                    }
                }
            }
            val index=decoder.dequeueOutputBuffer(info,1000)
            if(index==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val format=decoder.outputFormat
                val nextRate=format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val nextChannels=format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                require(nextRate in 8000..192000 && nextChannels in 1..2)
                require(originUs==null || nextRate==rate && nextChannels==channels) {"Changing audio format is unsupported"}
                rate=nextRate;channels=nextChannels
                encoding=if(format.containsKey(MediaFormat.KEY_PCM_ENCODING))format.getInteger(MediaFormat.KEY_PCM_ENCODING)else AudioFormat.ENCODING_PCM_16BIT
                require(encoding==AudioFormat.ENCODING_PCM_16BIT || encoding==AudioFormat.ENCODING_PCM_FLOAT)
            } else if(index>=0) {
                if(info.size>0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG==0) {
                    require(info.size<=1024*1024 && info.size%(unit()*channels)==0)
                    val buffer=requireNotNull(decoder.getOutputBuffer(index)).duplicate().order(ByteOrder.LITTLE_ENDIAN)
                    buffer.position(info.offset);buffer.limit(Math.addExact(info.offset,info.size))
                    val frames=info.size/(unit()*channels)
                    operationDecoded+=frames;check(operationDecoded<=maximumDecoded) {"Platform decoded-window budget exceeded"}
                    if(originUs==null)originUs=info.presentationTimeUs
                    // Framework SkipCutBuffer trims/rebuffers PCM but retains the raw
                    // codec buffer's timestamp. Its first nonempty output can therefore
                    // start earlier than that PTS. clear()/flush re-arms the same trim.
                    // Map this declared delay+padding in the extractor's source view;
                    // only the initial partial buffer is floored at the indexed start.
                    val previous=nextDecoded
                    val mapped=if(gaplessTrim>0) {
                        val timestampFrame=((info.presentationTimeUs-encodedOriginUs).toDouble()*rate/1_000_000.0).roundToLong()-gaplessTrim
                        if(previous==null)maxOf(traversalFirst,timestampFrame)else timestampFrame
                    }
                    else ((info.presentationTimeUs-requireNotNull(originUs)).toDouble()*rate/1_000_000.0).roundToLong()
                    require(mapped>=0 && (previous==null || abs(mapped-previous)<=2)) {"Unqualified platform source timestamp discontinuity"}
                    pendingFirst=previous ?: mapped;pendingFrames=frames
                    nextDecoded=Math.addExact(pendingFirst,frames.toLong())
                    pending=buffer;pendingIndex=index;pendingEos=info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0
                    return true
                }
                decoder.releaseOutputBuffer(index,false)
                if(info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM!=0) {
                    if(eligibilityWitness && nextDecoded==null) {
                        source.checkCurrent();outputEnded=true
                    } else seal()
                    return false
                }
            }
        }
    }
    override fun endFrames()=exactEnd
    override fun longFormConfirmed()=confirmedLong
    override fun revoke()=source.revoke()
    override fun closeReader():Boolean {
        if(closed)return true
        // A failed native close cannot transfer a live codec to another thread.
        if(worker!=null && worker!==Thread.currentThread())return false
        var success=true
        try {releasePending(discard=true)}catch(_:Throwable){success=false}
        val decoder=codec
        if(decoder!=null) {
            if(started)runCatching {decoder.stop()}
            try {decoder.release();codec=null;started=false}catch(_:Throwable){success=false}
        }
        try {extractor?.release();extractor=null}catch(_:Throwable){success=false}
        if(success)try {source.close();closed=true}catch(_:Throwable){success=false}
        return success
    }
    companion object {
        private val SUPPORTED_MIMES=setOf("audio/mp4a-latm","audio/aac","audio/flac","audio/raw","audio/mpeg","audio/opus","audio/vorbis")
    }
}
