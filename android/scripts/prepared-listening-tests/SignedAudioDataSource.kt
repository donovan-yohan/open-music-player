package com.soundq.android.playback
import android.net.Uri
import androidx.media3.datasource.*
import com.soundq.android.AppGraph
import java.util.concurrent.ConcurrentHashMap
class MediaGrant
class SignedAudioDataSource(private val graph:AppGraph,grants:ConcurrentHashMap<String,MediaGrant>):DataSource {
 private var input:java.io.InputStream?=null
 override fun open(dataSpec:DataSpec):Long {graph.opens.add(dataSpec.uri.toString());val f=graph.inputs.getValue(dataSpec.uri.toString());input=if(graph.extraBytes>0)java.io.SequenceInputStream(f.inputStream(),object:java.io.InputStream(){var remaining=graph.extraBytes;override fun read():Int=if(remaining-- >0)0 else -1;override fun read(b:ByteArray,o:Int,n:Int):Int{if(remaining<=0)return -1;val count=minOf(n,remaining);b.fill(0,o,o+count);remaining-=count;return count}})else f.inputStream();return graph.announced ?: f.length()}
 override fun read(buffer:ByteArray,offset:Int,length:Int)=input!!.read(buffer,offset,length)
 override fun close(){
  graph.closeAttempts++
  val captured=input
  if(captured==null){graph.closeNoops++;return}
  check(!graph.closeFailure){"acquisition cleanup failed"} // Retained repeated-throw control.
  try {
   val failure=graph.oneShotCloseFailure
   if(failure!=null){graph.oneShotCloseFailure=null;graph.closeFailures.add(failure);throw failure}
   captured.close();graph.closes++
  } finally {input=null} // Production clears handles even when the first close throws.
 }
 override fun getUri():Uri?=null
 override fun addTransferListener(transferListener:TransferListener){}
}
