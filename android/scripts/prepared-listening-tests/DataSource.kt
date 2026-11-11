package androidx.media3.datasource
import android.net.Uri
interface TransferListener
class DataSpec(val uri:Uri,val position:Long=0,val length:Long=-1)
interface DataSource {fun addTransferListener(transferListener:TransferListener);fun open(dataSpec:DataSpec):Long;fun read(buffer:ByteArray,offset:Int,length:Int):Int;fun getUri():Uri?;fun close();fun interface Factory {fun createDataSource():DataSource}}
class FileDataSource:DataSource {private var f:java.io.RandomAccessFile?=null;override fun open(dataSpec:DataSpec):Long {f=java.io.RandomAccessFile(java.io.File(java.net.URI(dataSpec.uri.toString())),"r");f!!.seek(dataSpec.position);return f!!.length()-dataSpec.position};override fun read(buffer:ByteArray,offset:Int,length:Int)=f!!.read(buffer,offset,length);override fun close(){f?.close();f=null};override fun getUri():Uri?=null;override fun addTransferListener(transferListener:TransferListener){} }
