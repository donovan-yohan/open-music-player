package android.media
import java.nio.ByteBuffer
import java.nio.ByteOrder
object AudioFormat {const val ENCODING_PCM_16BIT=2;const val ENCODING_PCM_FLOAT=4}
class MediaFormat {
    private val values=mutableMapOf<String,Any>(KEY_MIME to "audio/raw",KEY_SAMPLE_RATE to 8000,KEY_CHANNEL_COUNT to 1,KEY_PCM_ENCODING to 2)
    fun getString(k:String)=values[k] as? String
    fun getInteger(k:String)=values[k] as Int
    fun setInteger(k:String,v:Int){values[k]=v}
    fun containsKey(k:String)=values.containsKey(k)
    companion object {const val KEY_MIME="mime";const val KEY_SAMPLE_RATE="rate";const val KEY_CHANNEL_COUNT="channels";const val KEY_PCM_ENCODING="pcm";const val KEY_ENCODER_DELAY="encoder-delay";const val KEY_ENCODER_PADDING="encoder-padding"}
}
class MediaExtractor {
    private var source:com.soundq.android.playback.nativeengine.OriginalAudioReadLease?=null
    val trackCount=1
    fun setDataSource(source:Any){this.source=source as com.soundq.android.playback.nativeengine.OriginalAudioReadLease}
    fun getTrackFormat(i:Int)=MediaFormat()
    fun selectTrack(i:Int){}
    fun readSampleData(b:ByteBuffer,offset:Int):Int {
        if(MediaCodec.lastSeekUs>0 && MediaCodec.scenario=="failure-read")error("fixture source read budget exceeded")
        return if(MediaCodec.lastSeekUs>0 && MediaCodec.scenario!="long" && MediaCodec.scenario!="failure-decoded-budget")-1 else 2
    }
    val sampleFlags=0
    val sampleTime get()=MediaCodec.lastSeekUs
    fun advance()=true
    fun seekTo(us:Long,mode:Int){
        MediaCodec.lastSeekUs=us
        if(us>0 && MediaCodec.scenario=="failure-cancel")requireNotNull(source).revoke()
    }
    fun release(){}
    companion object {const val SAMPLE_FLAG_ENCRYPTED=2;const val SEEK_TO_PREVIOUS_SYNC=0}
}
class MediaCodec {
    class BufferInfo {var size=0;var offset=0;var flags=0;var presentationTimeUs=0L}
    private var step=0
    val outputFormat=MediaFormat()
    fun configure(f:MediaFormat,a:Any?,b:Any?,flags:Int){}
    fun start(){};fun stop(){};fun release(){releases++}
    fun flush(){step=1}
    fun dequeueInputBuffer(timeout:Long)=0
    fun getInputBuffer(i:Int)=ByteBuffer.allocate(8)
    fun queueInputBuffer(i:Int,offset:Int,count:Int,time:Long,flags:Int){}
    fun dequeueOutputBuffer(info:BufferInfo,timeout:Long):Int {
        step++
        if(step==1)return INFO_OUTPUT_FORMAT_CHANGED
        if(scenario!="long") {
            info.offset=0;info.presentationTimeUs=lastSeekUs
            if(lastSeekUs>0 && scenario=="failure-decoded-budget") {
                info.size=60000;info.flags=0
                info.presentationTimeUs+=(step-2)*1_000_000L
            } else {
                info.size=if(lastSeekUs==0L && step==2)4 else 0
                info.flags=if(info.size==0)BUFFER_FLAG_END_OF_STREAM else 0
            }
            return 0
        }
        check(step==2) {tailRequested=true;"Tail held: requested EOS before returning initial PCM"}
        info.offset=0;info.size=4;info.flags=0;info.presentationTimeUs=lastSeekUs;return 0
    }
    fun getOutputBuffer(i:Int)=if(scenario=="failure-decoded-budget" && lastSeekUs>0)ByteBuffer.allocate(60000) else ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putShort(8192).putShort(16384).apply{flip()}
    fun releaseOutputBuffer(i:Int,render:Boolean){}
    companion object {
        const val BUFFER_FLAG_END_OF_STREAM=4;const val BUFFER_FLAG_CODEC_CONFIG=2;const val INFO_OUTPUT_FORMAT_CHANGED=-2
        var tailRequested=false;var lastSeekUs=0L;var releases=0
        var scenario="long"
        fun createDecoderByType(mime:String)=MediaCodec()
    }
}
