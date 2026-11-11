#!/usr/bin/env python3
"""Execute exact LibraryArtwork production logic with a host-only bitmap hardware facade.
Real TLS/OkHttp, real AccountSession and acknowledged LibraryRepository. ImageIO is NOT Android decode.
"""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--designsystem-root',type=Path);a=p.parse_args()
r=Path(__file__).resolve().parents[1]
s=(r/'app/src/main/kotlin/com/soundq/android/product/artwork/LibraryArtwork.kt').read_text()
s=s.replace('package com.soundq.android.product.artwork','package com.soundq.android.artworkfixture').replace('import android.graphics.Bitmap\n','').replace('import android.graphics.BitmapFactory\n','')
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'LibraryArtworkExtracted.kt').write_text(s)
(a.generate/'BitmapHardwareFacade.kt').write_text('''package com.soundq.android.artworkfixture
// Hardware-only facade. This executes ImageIO, not Android BitmapFactory or Compose painting.
class Bitmap(val width:Int,val height:Int,val allocationByteCount:Int=width*height*4) {enum class Config {ARGB_8888}}
object BitmapFactory {
 class Options {var inJustDecodeBounds=false;var outWidth=0;var outHeight=0;var inSampleSize=1;var inPreferredConfig:Bitmap.Config?=null}
 fun decodeByteArray(data:ByteArray,offset:Int,length:Int,o:Options):Bitmap? {
  val input=javax.imageio.ImageIO.createImageInputStream(java.io.ByteArrayInputStream(data,offset,length))
  input.use {
   val readers=javax.imageio.ImageIO.getImageReaders(input)
   if(!readers.hasNext())return null
   val reader=readers.next()
   try {reader.input=input;o.outWidth=reader.getWidth(0);o.outHeight=reader.getHeight(0)
    return if(o.inJustDecodeBounds)null else Bitmap((o.outWidth+o.inSampleSize-1)/o.inSampleSize,(o.outHeight+o.inSampleSize-1)/o.inSampleSize)
   } finally {reader.dispose()}
  }
 }
}
''')
(a.generate/'LibraryArtworkTlsTest.kt').write_text('''package com.soundq.android.artworkfixture
import com.soundq.android.data.*
import mockwebserver3.*
import okhttp3.*
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

class LibraryArtworkTlsTest {
 private class Fixture:AutoCloseable {
  val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
  val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
  val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
  val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
  val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),MemoryStore())
  init {account("A")}
  fun account(id:String){session.accept(session.beginIntent(),SecretTokens("synthetic-access-"+id,"synthetic-refresh",id))}
  fun capture(url:String?=server.url("/owned.png?signature=synthetic-private").toString()):com.soundq.android.data.playlists.LibraryTrackCapture {
   val track=Track(TrackId(1),"Owned image",artwork=url)
   val library=LibraryRepository(session,{_,_,_->LibraryPage(listOf(track),1,20,0)},{_,_,_->})
   library.refine(LibraryQuery());return library.captureTrack(track)!!
  }
  override fun close(){server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
 }
 private fun png(width:Int=8,height:Int=6):ByteArray {
  val out=java.io.ByteArrayOutputStream();javax.imageio.ImageIO.write(java.awt.image.BufferedImage(width,height,java.awt.image.BufferedImage.TYPE_INT_ARGB),"png",out);return out.toByteArray()
 }
 private fun response(bytes:ByteArray)=MockResponse.Builder().code(200).body(Buffer().write(bytes)).build()
 private fun await(test:()->Boolean) {val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);while(!test()){if(System.nanoTime()>deadline)fail("Artwork did not settle");Thread.sleep(2)}}
 private fun drain(f:Fixture,loader:LibraryArtwork) {
  f.server.enqueue(response(png()));val row=loader.open(f.capture()){true};row.start();await {row.bitmap()!=null};row.close()
 }
 @Test fun actualTlsNoBearerAndSampledPixelsPublishThroughAcknowledgedRow() {
  Fixture().use {f ->
   val inherited=f.client.newBuilder().addInterceptor {chain->chain.proceed(chain.request().newBuilder().header("Authorization","Bearer must-not-leak").header("Cookie","secret").build())}.build()
   var worker="";var size=0
   LibraryArtwork(f.session,inherited,{bytes->worker=Thread.currentThread().name;size=bytes.size;decodeLibraryArtwork(bytes)}).use {loader->
    val bytes=png(1537,769);f.server.enqueue(response(bytes));val capture=f.capture();val row=loader.open(capture){true}
    assertNull(row.bitmap());row.start();await {row.bitmap()!=null}
    val image=row.bitmap()!!;assertTrue(image.width<=192&&image.height<=192);assertTrue(image.allocationByteCount<=147456)
    assertEquals(bytes.size,size);assertEquals("soundq-library-artwork",worker)
    val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
    assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"]);assertEquals("/owned.png",request.url.encodedPath)
    row.close();assertNull(row.bitmap());assertFalse(row.current())
   }
  }
 }
 @Test fun missingUnsafeLockedDeviceOnlyAndOldAccountBeforeDispatchMakeNoArtworkRequest() {
  Fixture().use {f ->LibraryArtwork(f.session,f.client).use {loader->
   for(url in listOf(null,"http://localhost/unsafe","https://user:secret@localhost/a","https://localhost/a#fragment")) {
    val row=loader.open(f.capture(url)){true};row.start();assertFalse(row.current());assertNull(row.bitmap())
   }
   val old=f.capture();f.account("B");f.account("A")
   val retired=loader.open(old){true};retired.start();assertFalse(retired.current())
   val locked=f.capture();f.session.lockLocal();val blocked=loader.open(locked){true};blocked.start();assertFalse(blocked.current())
   f.session.completeLocalUnlock(f.session.localUnlockTicket()!!)
   // Capture while the canonical Library can acknowledge a remote row, then
   // retire remote authority before artwork dispatch. Device-only refinement
   // must not fabricate a new acknowledged capture merely for this fixture.
   val offlineCapture=f.capture()
   f.session.failure(f.session.version(),SafeFailure.Reason.Network);assertTrue(f.session.useDeviceDownloads())
   val offline=loader.open(offlineCapture){true};offline.start();assertFalse(offline.current())
   assertEquals(0,f.server.requestCount)
  }}
 }
 @Test fun redirectsOversizeAndCorruptKeepFallbackAndHealthySuccessorLoads() {
  Fixture().use {f ->val decodes=AtomicInteger();LibraryArtwork(f.session,f.client,{decodes.incrementAndGet();decodeLibraryArtwork(it)}).use {loader->
   val refused=listOf(MockResponse.Builder().code(302).addHeader("Location",f.server.url("/must-not-follow")).build(),
    MockResponse.Builder().code(200).body(Buffer().write(ByteArray(4_000_001))).build(),
    MockResponse.Builder().code(200).chunkedBody(Buffer().write(ByteArray(4_000_001)),8192).build(),response("not an image".toByteArray()))
   for((index,result) in refused.withIndex()) {
    f.server.enqueue(result);val row=loader.open(f.capture(f.server.url("/refused-$index").toString())){true};row.start()
    assertEquals("/refused-$index",f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath);await {loader.pendingWorkCount()==0}
    assertNull(row.bitmap());row.close()
    f.server.enqueue(response(png()));val fresh=loader.open(f.capture(f.server.url("/healthy-$index").toString())){true};fresh.start();await {fresh.bitmap()!=null};fresh.close()
    assertEquals("/healthy-$index",f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath)
    assertEquals((index+1)*2,f.server.requestCount)
   }
   assertEquals(5,decodes.get()) // Four healthy drains plus corrupt bytes; oversized/redirect bodies never decode.
  }}
 }
 @Test fun heldDecodeAccountAbaTerminallyRefusesOldThenHealthyAccountCanPublish() {
  Fixture().use {f ->val entered=CountDownLatch(1);val release=CountDownLatch(1);val calls=AtomicInteger()
   LibraryArtwork(f.session,f.client,{bytes->if(calls.incrementAndGet()==1){entered.countDown();while(release.count>0){try {release.await()}catch(_:InterruptedException){}}};decodeLibraryArtwork(bytes)}).use {loader->
    try {
     f.server.enqueue(response(png()));val old=loader.open(f.capture()){true};old.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
     f.account("B");f.account("A");assertFalse(old.current());assertNull(old.bitmap())
     f.server.enqueue(response(png()));val fresh=loader.open(f.capture()){true};fresh.start();release.countDown();await {fresh.bitmap()!=null}
     assertFalse(old.current());assertNull(old.bitmap());assertNotNull(fresh.bitmap())
    } finally {release.countDown()}
   }
  }
 }
 @Test fun heldUrlRowAbaCancellationDetachesOldAndBoundsLiveRowsWithoutCache() {
  Fixture().use {f ->val entered=CountDownLatch(1);val release=CountDownLatch(1)
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
    if(request.url.encodedPath=="/old"){entered.countDown();release.await()};return response(png())
   }}
   LibraryArtwork(f.session,f.client).use {loader->
    try {
     val a=f.capture(f.server.url("/old").toString());val old=loader.open(a){true};old.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
     old.close();val b=loader.open(f.capture(f.server.url("/new").toString())){true};b.start();await {b.bitmap()!=null};b.close()
     val returned=loader.open(a){true};release.countDown();returned.start();await {returned.bitmap()!=null};assertNull(old.bitmap());assertFalse(old.current());returned.close()
     val rows=(1..32).map {loader.open(f.capture()){true}};assertEquals(32,rows.count {it.current()})
     val overflow=loader.open(f.capture()){true};assertFalse(overflow.current());rows.first().close()
     val renewed=loader.open(f.capture()){true};assertTrue(renewed.current());assertFalse(overflow.current());renewed.close();rows.forEach {it.close()}
    } finally {release.countDown()}
   }
  }
 }
 @Test fun removedEligibilityClearsAcceptedImageImmediatelyAndNeverRevives() {
  Fixture().use {f ->LibraryArtwork(f.session,f.client).use {loader->
   var mounted=true;f.server.enqueue(response(png()));val row=loader.open(f.capture()){mounted};row.start();await {row.bitmap()!=null}
   mounted=false;assertNull(row.bitmap());mounted=true;assertFalse(row.current());assertNull(row.bitmap());drain(f,loader)
  }}
 }
}
''')

# Exact production visual pass-through bodies, with only Compose/hardware declarations facaded.
def block(text,marker):
 start=text.index(marker);opening=text.index('{',start);end=opening+1;depth=1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
ds=a.designsystem_root or r/'designsystem'
wrapper=block((ds/'src/main/kotlin/com/soundq/designsystem/RevealMediaRow.kt').read_text(),'@Composable fun SoundQRevealMediaRow(')
media=block((ds/'src/main/kotlin/com/soundq/designsystem/ProductComponents.kt').read_text(),'@Composable fun SoundQMediaRow(')
slot=block((ds/'src/main/kotlin/com/soundq/designsystem/PlayerComponents.kt').read_text(),'@Composable fun SoundQArtworkSlot(')
visual=(wrapper+'\n'+media+'\n'+slot).replace('@Composable ','')
(a.generate/'LibraryArtworkVisualSlotTest.kt').write_text('''package com.soundq.android.artworkvisualfixture
import org.junit.Assert.*
import org.junit.Test
// Layout/paint declarations only. They traverse slots but never invoke actions.
typealias Dp=Int
val Int.dp:Dp get()=this
class Density(val fontScale:Float=1f) {fun Int.toSp()=this}
object LocalDensity {val current=Density()}
data class TextStyle(val lineHeight:Int=0)
object IntrinsicSize {val Min=0;val Max=1}
class Local<T>(var current:T) {infix fun provides(value:T)=this to value}
val LocalMediaRowCompactMetadata=Local(false)
fun <T> CompositionLocalProvider(value:Pair<Local<T>,T>,content:()->Unit) {
 val previous=value.first.current
 try {value.first.current=value.second;content()} finally {value.first.current=previous}
}
class ImageBitmap
object ContentScale {val Crop=0}
object TextOverflow {val Ellipsis=0}
object Modifier {
 fun fillMaxWidth(fraction:Float=1f)=this
 fun fillMaxSize()=this
 fun fillMaxHeight()=this
 fun height(value:Int)=this
 fun width(value:Int)=this
 fun widthIn(max:Float)=this
 fun size(value:Int)=this
 fun heightIn(min:Int)=this
 fun clipToBounds()=this
 fun mediaRowBottomRule()=this
 fun align(alignment:Int)=this
 fun background(color:Int)=this
 fun semantics(mergeDescendants:Boolean,content:Semantics.()->Unit)=apply {Semantics().content()}
 fun clearAndSetSemantics(content:Semantics.()->Unit)=apply {Semantics().content()}
 fun clickable(role:Int,enabled:Boolean=true,onClick:()->Unit)=this
 fun testTag(value:String)=this
 fun padding(horizontal:Int=0,vertical:Int=0,start:Int=0)=this
 fun weight(value:Float,fill:Boolean=true)=this
}
class Semantics {var selected=false;var stateDescription="";var contentDescription="";var text=androidx.compose.ui.text.AnnotatedString("")}
object Role {val Button=0}
object Alignment {val CenterVertically=0;val CenterStart=0;val BottomCenter=0;val Center=0}
object Arrangement {val Center=0;fun spacedBy(value:Int)=0}
fun Box(modifier:Modifier=Modifier,contentAlignment:Int=0,content:()->Unit){content()}
// This slot-pass-through fixture has no constraint/font measurement model. Enlarged layout
// belongs to SharedPresentationRepairTest's real Compose host, never a fabricated size here.
class BoxConstraintsScope {val maxWidth:Float get()=error("Native constraint measurement outside slot fixture")}
fun BoxWithConstraints(modifier:Modifier,content:BoxConstraintsScope.()->Unit):Unit=error("Enlarged layout requires mounted Compose")
fun Column(modifier:Modifier=Modifier,verticalArrangement:Int=0,content:()->Unit){content()}
fun Row(modifier:Modifier=Modifier,verticalAlignment:Int=0,horizontalArrangement:Int=0,content:()->Unit){content()}
object SoundQIcon {val Note=0;val More=1}
var fallback=0
fun SoundQIcon(icon:Int,label:String?,tint:Int=0){if(icon==SoundQIcon.Note)fallback++}
fun Image(image:ImageBitmap,label:String?,modifier:Modifier,contentScale:Int){error("Decoded image painting outside host slot fixture")}
class RowRevealState {fun close(){}}
val text=mutableListOf<String>()
object SoundQ {
 object colors {val muted=0;val surface=0;val background=0;val primary=0;val text=0;val raised=0}
 object typography {val caption=TextStyle();val title=TextStyle()}
 object sizes {val row=0;val mediaRow=72}
 object spacing {val gutter=20;val medium=12}
}
fun Text(value:String,modifier:Modifier=Modifier,color:Int=0,style:TextStyle,maxLines:Int=Int.MAX_VALUE,softWrap:Boolean=true,overflow:Int=0){text.add(value)}
fun SoundQDivider(modifier:Modifier=Modifier){}
fun CellIcon(icon:Int,label:String,action:()->Unit,modifier:Modifier=Modifier){}
fun SoundQRow(title:String,subtitle:String,current:Boolean,onActivate:()->Unit,modifier:Modifier,leading:()->Unit,trailing:()->Unit,supportingContent:(()->Unit)?=null){text.add(subtitle);leading();supportingContent?.invoke();trailing()}
fun SoundQIconButton(icon:Int,label:String,action:()->Unit){}
fun mediaRowBackground(current:Boolean):Int=if(current)SoundQ.colors.surface else SoundQ.colors.background
fun SoundQSwipeQueue(title:String,state:RowRevealState,enabled:Boolean,onQueue:()->Unit,modifier:Modifier,liked:Boolean?,likeEnabled:Boolean,onLike:()->Unit,explicitQueue:()->Unit,current:Boolean=false,content:(Modifier,()->Boolean)->Unit){content(Modifier,{true})}
'''+visual+'''
class LibraryArtworkVisualSlotTest {
 @Test fun metadataSlotKeepsArtistThenMetadataThenSeparateLikeStatusWithoutActions() {
  var actions=0;text.clear()
  SoundQRevealMediaRow("Owned","Artist",false,RowRevealState(),true,false,true,{actions++},{actions++},{actions++},{actions++},supporting="Saving Like",metadata={text.add("3:42 · 128 BPM · 8A")})
  assertEquals(listOf("Owned","Artist","3:42 · 128 BPM · 8A","Saving Like"),text)
  assertEquals(0,actions)
 }
 @Test fun actualRevealAndMediaRowPassSlotWithoutActivatingAnyAction() {
  var art=0;var actions=0;fallback=0
  SoundQRevealMediaRow("Owned","Artist",false,RowRevealState(),true,false,true,{actions++},{actions++},{actions++},{actions++},artwork={art++})
  assertEquals(1,art);assertEquals(0,fallback);assertEquals(0,actions)
 }
 @Test fun omittedOptionalSlotRetainsExistingFallbackThroughBothActualBodies() {
  var actions=0;fallback=0
  SoundQRevealMediaRow("Absent","Artist",false,RowRevealState(),true,false,true,{actions++},{actions++},{actions++},{actions++})
  assertEquals(1,fallback);assertEquals(0,actions)
 }
}
''')
