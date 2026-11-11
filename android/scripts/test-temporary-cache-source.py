#!/usr/bin/env python3
"""Compile exact signed source body with host Uri/DataSpec/HTTP boundary facades."""
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
source=Path(sys.argv[2]).read_text() if len(sys.argv)>2 else (root/'app/src/main/kotlin/com/soundq/android/playback/SignedAudioDataSource.kt').read_text()
start=source.index('internal class MediaGrant')
source=source[start:]
source=source.replace('@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)\n','').replace('AppGraph','CacheGraph')
prelude=r'''
package com.soundq.android.cacheprobe
import com.soundq.android.data.*
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.data.cache.*
import com.soundq.android.data.preferences.*
import com.soundq.android.data.offline.LocalAudioLease
import java.util.concurrent.ConcurrentHashMap
import okhttp3.*
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
object C {const val LENGTH_UNSET=-1;const val RESULT_END_OF_INPUT=-1}
class Uri private constructor(val value:String) {val scheme get()=value.substringBefore(':');override fun toString()=value;companion object {fun parse(v:String)=Uri(v)}}
class DataSpec(val uri:Uri,val position:Long=0,val length:Long=-1,val httpRequestHeaders:Map<String,String> = emptyMap()) {
 fun withUri(uri:Uri)=DataSpec(uri,position,length,httpRequestHeaders)
 fun withRequestHeaders(headers:Map<String,String>)=DataSpec(uri,position,length,headers)
}
interface TransferListener
interface DataSource {fun addTransferListener(l:TransferListener);fun open(s:DataSpec):Long;fun read(b:ByteArray,o:Int,n:Int):Int;fun getUri():Uri?;fun close()}
object HttpDataSource {class InvalidResponseCodeException(val responseCode:Int):java.io.IOException()}
class OkHttpDataSource(private val client:OkHttpClient):DataSource {
 class Factory(private val client:OkHttpClient){fun createDataSource()=OkHttpDataSource(client)}
 private var response:Response?=null
 override fun addTransferListener(l:TransferListener){}
 override fun open(s:DataSpec):Long {
  val b=Request.Builder().url(s.uri.toString());if(s.position>0)b.header("Range","bytes=${s.position}-")
  val r=client.newCall(b.build()).execute();response=r
  if(!r.isSuccessful)throw HttpDataSource.InvalidResponseCodeException(r.code)
  return r.body.contentLength()
 }
 override fun read(b:ByteArray,o:Int,n:Int)=response!!.body.byteStream().read(b,o,n)
 override fun getUri():Uri?=null
 override fun close(){response?.close();response=null}
}
class Downloads {fun load(s:AccountScope){};fun acquire(s:AccountScope,t:TrackId):LocalAudioLease?=null}
class CachePhone {val authorityVersion=0L;fun current(version:Long)=false;internal fun observed(ref:com.soundq.android.playback.PlaybackRef.Device):com.soundq.android.data.deviceaudio.DeviceAudio?=null}
class CacheGraph(val directory:File,val session:AccountSession,val mediaClient:OkHttpClient) {val phoneAudio=CachePhone();
 val api=SoundQApi(session,mediaClient);val downloads=Downloads()
 val storagePreferences=StoragePreferences(File(directory,"storage")).also {it.load()}
 val temporaryAudio=TemporaryAudioCache(File(directory,"cache"),session)
}
'''
test=r'''
class TemporaryCacheSourceTest {
 @org.junit.Test fun actualSourceReadsPopulateCacheAndFutureSourceUsesExactBytesWithoutNetwork() {
  HttpsFixture().use {tls->
   val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"actual-cache-source").toFile().canonicalFile
   try {
    val s=AccountSession(tls.endpoint,MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","A"))
    val g=CacheGraph(dir,s,tls.client);val scope=s.capture()!!;val grants=ConcurrentHashMap<String,MediaGrant>()
    val uri=Uri.parse("soundq://track/7/occurrence");grants[uri.toString()]=MediaGrant(scope,TrackId(7))
    val bytes=ByteArray(1024){(it%127).toByte()}
    fun enqueue(){tls.reply("""{"urls":[{"trackId":7,"url":"${tls.server.url("/media/cached.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":1024}]}""");tls.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(bytes)).build())}
    fun read(source:SignedAudioDataSource):ByteArray {val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(79);while(true){val n=source.read(buffer,0,buffer.size);if(n<0)break;out.write(buffer,0,n)};source.close();return out.toByteArray()}
    enqueue();val source=SignedAudioDataSource(g,grants);assertEquals(1024L,source.open(DataSpec(uri)));assertArrayEquals(bytes,read(source));assertEquals(1024L,g.temporaryAudio.status().bytes)
    assertEquals(2,tls.server.requestCount);assertNotNull(tls.server.takeRequest().headers["Authorization"]);assertNull(tls.server.takeRequest().headers["Authorization"])
    val cached=SignedAudioDataSource(g,grants);assertEquals(1024L,cached.open(DataSpec(uri)));assertArrayEquals(bytes,read(cached));assertEquals(2,tls.server.requestCount)
    val held=SignedAudioDataSource(g,grants);held.open(DataSpec(uri));assertEquals(1,g.temporaryAudio.clear().deferredFiles);assertArrayEquals(bytes,read(held));assertEquals(0L,g.temporaryAudio.status().bytes)
    enqueue();val late=SignedAudioDataSource(g,grants);late.open(DataSpec(uri));val prefix=ByteArray(37);assertEquals(37,late.read(prefix,0,37));g.temporaryAudio.clear();assertArrayEquals(bytes.copyOfRange(37,1024),read(late));assertEquals(0L,g.temporaryAudio.status().bytes)
    assertTrue(g.storagePreferences.setTemporaryAudio(g.storagePreferences.capture()!!,false){true})
    enqueue();val disabled=SignedAudioDataSource(g,grants);disabled.open(DataSpec(uri));assertArrayEquals(bytes,read(disabled));assertEquals(0L,g.temporaryAudio.status().bytes)
    assertEquals(6,tls.server.requestCount)
   }finally {dir.deleteRecursively()}
  }
 }
}
'''
(out/'TemporaryCacheSourceTest.kt').write_text(prelude+'\n'+source+'\n'+test)
