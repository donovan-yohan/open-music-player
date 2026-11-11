#!/usr/bin/env python3
"""Exercise exact Settings/Downloads action bodies with real owners on the host.
Compose, Android focus, layout and lifecycle remain unqualified by this probe.
"""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--source-root',type=Path);a=p.parse_args()
r=a.source_root or Path(__file__).resolve().parents[1]
b=r/'app/src/main/kotlin/com/soundq/android'
settings=(b/'product/preferences/PreferencesScreen.kt').read_text()
downloads=(b/'product/offline/DownloadsScreen.kt').read_text()
appearance=(b/'product/preferences/AppearanceSetting.kt').read_text()
def braces(source,start):
    end=start+1;depth=1
    while depth:
        if source[end]=='{':depth+=1
        elif source[end]=='}':depth-=1
        end+=1
    return source[start:end]
def callback(source,marker):
    return braces(source,source.index('{',source.index(marker)+len(marker)))
open_clear=callback(settings,'SoundQButton("Clear temporary audio",')
clear_section=settings[settings.index('title={Text("Clear temporary audio?")}'):]
confirm=callback(clear_section,'TextButton(onClick=')
clear_decl=next(line.strip() for line in settings.splitlines() if 'var confirmClear by remember' in line)
clear_decl=clear_decl.replace('remember {','remember<Cell<CacheClearCapture?>> {' if 'CacheClearCapture?' in clear_decl else 'remember<Cell<Boolean>> {')
cancel=callback(downloads,'SoundQButton("Cancel download",')
status_start=downloads.index('            val status=')+len('            val status=')
status_expression=downloads[status_start:downloads.index('            val current=',status_start)].strip()
start=appearance.index('    val state by owner.state',appearance.index('fun AppearanceChoices('))
end=appearance.index('    LaunchedEffect(Unit)',start)
appearance_body=appearance[start:end]
# Strip the paint-only native focus requester map, not any action/lifetime statements.
appearance_body=appearance_body.replace('val requesters=remember {Appearance.entries.associateWith {FocusRequester()}}','')
appearance_body=appearance_body.replace('remember {mutableStateOf(false)}','remember<Cell<Boolean>> {mutableStateOf(false)}').replace('remember {mutableStateOf<Appearance?>(null)}','remember<Cell<Appearance?>> {mutableStateOf<Appearance?>(null)}')
pre='''package com.soundq.android.offlinesettingsfixture
import com.soundq.android.data.*
import com.soundq.android.data.cache.*
import com.soundq.android.data.offline.*
import com.soundq.android.data.preferences.*
import com.soundq.android.product.offline.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.StateFlow
import kotlin.reflect.KProperty
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
class Cell<T>(var value:T) {
 operator fun getValue(thisRef:Any?,property:KProperty<*>)=value
 operator fun setValue(thisRef:Any?,property:KProperty<*>,next:T){value=next}
}
fun <T> mutableStateOf(value:T)=Cell(value)
fun <T> remember(block:()->T)=block()
fun <T> StateFlow<T>.collectAsStateWithLifecycle()=Cell(value)
lateinit var work:CoroutineScope
fun rememberCoroutineScope()=work
val disposals=mutableListOf<()->Unit>()
class Disposal {fun onDispose(block:()->Unit){disposals.add(block)}}
fun DisposableEffect(key:Any?,block:Disposal.()->Unit){Disposal().block()}
fun appearanceAction(owner:AppearancePreferences):(Appearance)->Unit {
APPEARANCE
 return ::choose
}
class Graph(val temporaryAudio:TemporaryAudioCache)
class ClearBinding(val graph:Graph) {
 DECLARATION
 var cacheMessage:String?=null
 var live=true
 val valid={live}
 var refreshes=0
 fun refresh(){refreshes++}
 val open:()->Unit=OPEN
 fun confirmation():()->Unit {
 CAPTURE
 return CONFIRM
 }
}
class Model(val store:DeviceDownloads){fun cancelDownload(scope:AccountScope,row:DeviceDownload,valid:()->Boolean){if(valid())store.cancel(scope,row)}}
fun cancelAction(model:Model,scope:AccountScope,row:DeviceDownload,valid:()->Boolean,rowValid:()->Boolean):()->Unit {
 var menu=true
 return CANCEL
}
class OfflineSettingsActionsExtractedTest {
 private fun status(row:DeviceDownload):String=STATUS
 @Test fun downloadRowShowsReadableReceivedTotalWithoutInventingUnknownSize() {
  val track=Track(TrackId(7),"Fixture")
  assertEquals("Downloading · 1 MiB / 2 MiB",status(DeviceDownload(track,DownloadStatus.Downloading,1L shl 20,2L shl 20)))
  assertEquals("Downloading · 3 B / —",status(DeviceDownload(track,DownloadStatus.Downloading,3)))
  assertEquals("Available offline",status(DeviceDownload(track,DownloadStatus.Complete,2L shl 20)))
  assertEquals("Download failed",status(DeviceDownload(track,DownloadStatus.Failed)))
 }
 private fun drain()=runBlocking {work.coroutineContext[Job]!!.children.toList().joinAll()}
 private fun complete(cache:TemporaryAudioCache,s:AccountScope,id:Long) {val w=cache.begin(s,TrackId(id),4)!!;w.append(byteArrayOf(1,2,3,4),0,4);assertTrue(w.finish())}
 private fun fixture(test:(java.io.File,AccountSession,AccountScope)->Unit) {
  val dir=java.nio.file.Files.createTempDirectory("offline-settings-actions-").toFile()
  val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore()).also{it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
  work=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
  try {test(dir,session,session.capture()!!)}finally {work.cancel();disposals.forEach{it()};disposals.clear();dir.deleteRecursively()}
 }
 @Test fun clearConfirmationKeepsLaterAudioAndRetainsLeasedBytesUntilRelease()=fixture {dir,session,s->
  val cache=TemporaryAudioCache(dir.resolve("cache"),session);complete(cache,s,7)
  val lease=cache.acquire(s,TrackId(7))!!
  try {
   val binding=ClearBinding(Graph(cache));binding.open();val confirm=binding.confirmation()
   complete(cache,s,8);confirm();drain()
   assertNull(cache.acquire(s,TrackId(7)))
   assertNotNull("Audio created after the clear intent must survive",cache.acquire(s,TrackId(8))?.also{it.close()})
   assertEquals(1,cache.status().deferredFiles);assertEquals(8L,cache.status().bytes)
   val bytes=ByteArray(4);assertEquals(4,lease.read(bytes,0,4));assertArrayEquals(byteArrayOf(1,2,3,4),bytes)
  } finally {lease.close()}
  assertEquals(4L,cache.status().bytes)
 }
 @Test fun dismissedAccountCannotDispatchAConfirmedClear()=fixture {dir,session,s->
  val cache=TemporaryAudioCache(dir.resolve("cache"),session);complete(cache,s,7)
  val binding=ClearBinding(Graph(cache));binding.open();val confirm=binding.confirmation();binding.live=false;confirm();drain()
  assertNotNull(cache.acquire(s,TrackId(7))?.also{it.close()});assertEquals(4L,cache.status().bytes)
 }
 @Test fun cancelUsesTransferIncarnationAfterProgressRowRetiresButNotReplacementOrRoute()=fixture {dir,session,s->
  val client=okhttp3.OkHttpClient()
  try {
   val store=DeviceDownloads(dir.resolve("downloads"),session,SoundQApi(session,client),client).also{it.load(s)}
   val track=Track(TrackId(7),"Fixture");store.claim(s,track){true}!!;val old=store.state.value.rows.single()
   val model=Model(store);val cancel=cancelAction(model,s,old,{true},{false})
   cancel();assertEquals("Progress replacement is not transfer replacement",DownloadStatus.Cancelled,store.state.value.rows.single().status)
   store.claim(s,track){true}!!;cancel();assertEquals(DownloadStatus.Downloading,store.state.value.rows.single().status)
   val current=store.state.value.rows.single();cancelAction(model,s,current,{false},{true})();assertEquals(DownloadStatus.Downloading,store.state.value.rows.single().status)
   assertEquals(0,client.dispatcher.runningCallsCount());assertEquals(0,client.dispatcher.queuedCallsCount())
  }finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
 }
 @Test fun retainedAppearanceChoiceCannotAcquireFreshAuthorityAfterReload()=fixture {dir,_,_->
  val file=dir.resolve("appearance");val owner=AppearancePreferences(file).also{it.load()}
  val old=appearanceAction(owner)
  owner.load();old(Appearance.Dark);drain()
  assertEquals("Reload retires composed choice callbacks",Appearance.System,owner.state.value.choice);assertFalse(file.exists())
  appearanceAction(owner)(Appearance.Dark);drain();assertEquals(Appearance.Dark,owner.state.value.choice)
  val bytes=file.readBytes();disposals.toList().forEach{it()};old(Appearance.Light);drain();assertArrayEquals(bytes,file.readBytes())
 }
}
'''
pre=pre.replace('APPEARANCE',appearance_body).replace('DECLARATION',clear_decl).replace('OPEN',open_clear).replace('CONFIRM',confirm).replace('CANCEL',cancel)
pre=pre.replace('STATUS',status_expression)
if not (b/'product/offline/DeviceCopyPresentation.kt').exists():
    pre=pre.replace('import com.soundq.android.product.offline.*\n','')
pre=pre.replace('CAPTURE','val captured=confirmClear ?: error("No clear intent")' if 'CacheClearCapture?' in clear_decl else '')
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'OfflineSettingsActionsExtractedTest.kt').write_text(pre)
print('Extracted actual clear, transfer cancellation and appearance callbacks')
