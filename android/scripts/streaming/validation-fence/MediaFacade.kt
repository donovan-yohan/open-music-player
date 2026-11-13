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
    val trackCount=1
    fun setDataSource(source:Any){}
    fun getTrackFormat(i:Int)=MediaFormat()
    fun selectTrack(i:Int){}
    fun readSampleData(b:ByteBuffer,offset:Int)=2
    val sampleFlags=0
    val sampleTime get()=MediaCodec.first*125
    fun advance()=true
    fun seekTo(us:Long,mode:Int){MediaCodec.first=us/125}
    fun release(){}
    companion object {const val SAMPLE_FLAG_ENCRYPTED=2;const val SEEK_TO_PREVIOUS_SYNC=0}
}
class MediaCodec {
    class BufferInfo {var size=0;var offset=0;var flags=0;var presentationTimeUs=0L}
    var format=false
    val outputFormat=MediaFormat()
    fun configure(f:MediaFormat,a:Any?,b:Any?,flags:Int){}
    fun start(){};fun stop(){};fun release(){}
    fun flush(){format=true}
    fun dequeueInputBuffer(timeout:Long)=0
    fun getInputBuffer(i:Int)=ByteBuffer.allocate(8)
    fun queueInputBuffer(i:Int,offset:Int,count:Int,time:Long,flags:Int){}
    fun dequeueOutputBuffer(info:BufferInfo,timeout:Long):Int {
        if(!format){format=true;return INFO_OUTPUT_FORMAT_CHANGED}
        info.offset=0;info.size=chunk*2;info.flags=0;info.presentationTimeUs=first*125
        first+=chunk;onBuffer();return 0
    }
    fun getOutputBuffer(i:Int)=ByteBuffer.allocate(chunk*2).order(ByteOrder.LITTLE_ENDIAN).apply {repeat(chunk){putShort(8192)};flip()}
    fun releaseOutputBuffer(i:Int,render:Boolean){}
    companion object {
        const val BUFFER_FLAG_END_OF_STREAM=4;const val BUFFER_FLAG_CODEC_CONFIG=2;const val INFO_OUTPUT_FORMAT_CHANGED=-2
        var first=0L;var chunk=96;var onBuffer:()->Unit={}
        fun createDecoderByType(mime:String)=MediaCodec()
    }
}
