#!/usr/bin/env python3
"""Run exact native queue mutation/controller bodies with declared host boundaries.
No decoder, MediaSession, Android composition or audible playback is claimed.
"""
import os, subprocess, tempfile
from pathlib import Path
R=Path(__file__).resolve().parents[1]
P=R/'app/src/main/kotlin/com/soundq/android'
native=(P/'playback/nativeengine/NativeCallbackPlayer.kt').read_text()
controller=(P/'playback/ControllerProjection.kt').read_text()
service=(P/'playback/SoundQLibraryService.kt').read_text()

def block(source,marker):
    start=source.index(marker); opening=source.index('{',start); depth=1; end=opening+1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]

methods='\n'.join(block(native,m).replace('override fun','fun') for m in [
    '    private fun mutate(', '    override fun handleAddMediaItems(', '    private fun rebuilt(',
    '    override fun handleRemoveMediaItems(', '    override fun handleMoveMediaItems(', '    override fun handleSetMediaItems('])
commands='\n'.join(block(controller,m) for m in ['    fun enqueue(', '    fun select(', '    fun moveTo(', '    fun remove(', '    fun clear('])
undo=service[service.index('            val saved=undo ?:'):service.index('\n        private fun folder(')].rsplit('\n        }',1)[0]
capture_start=service.index('                undoScope=scope')
capture=service[capture_start:service.index('                transport.pause()',capture_start)+len('                transport.pause()')]
# Compile production pure confirmation plus DTOs. Compose shell is not remounted here.
panel=(P/'product/QueuePanel.kt').read_text()
confirmation=block(panel,'internal class QueueClearCapture(')
dtos=controller.split('@kotlinx.serialization.Serializable ',1)[1].split('/** Disposable immutable projection',1)[0]
fixture='''package com.soundq.android.playback.nativeengine
import kotlin.random.Random
import com.soundq.android.playback.*
import com.soundq.android.product.*
class ListenableFuture<T>
object Player {const val STATE_IDLE=1}
object C {const val INDEX_UNSET=-1;const val TIME_UNSET=-9223372036854775807L}
class Bundle(val track:Long=7) {val values=mutableMapOf<String,Boolean>();fun putBoolean(k:String,v:Boolean){values[k]=v};fun getBoolean(k:String)=values[k]==true;fun getString(k:String):String?=null;fun getLong(k:String)=track}
class Request(val extras:Bundle) {class Builder {var extras=Bundle();fun setExtras(e:Bundle)=apply{extras=e};fun build()=Request(extras)}}
class Metadata(val extras:Bundle)
class Uri(val value:String) {val scheme="soundq";override fun toString()=value}
class Local(val uri:Uri)
class MediaItem(val mediaId:String,val localConfiguration:Local?=Local(Uri(mediaId)),val manual:Boolean=false,val track:Long=7) {
 val mediaMetadata=Metadata(Bundle(track).apply{putBoolean("manual",manual)})
 object RequestMetadata {class Builder {private val delegate=Request.Builder();fun setExtras(e:Bundle)=apply{delegate.setExtras(e)};fun build()=delegate.build()}}
 class Builder {var id="";var request=Request(Bundle());fun setMediaId(v:String)=apply{id=v};fun setRequestMetadata(r:Request)=apply{request=r};fun build()=MediaItem(id,manual=request.extras.getBoolean("manual"))}
}
class Grant(val scope:Int=1,val track:TrackId=TrackId(7),val localOnly:Boolean=false)
typealias MediaGrant=Grant
class TrackId(val value:Long)
class Track(val id:TrackId)
class NativeBoundary {
 var items=listOf<MediaItem>();var index=0;var position=4300L;var order=listOf<Int>();var shuffle=false;val random=Random(19)
 var selectedLoaded=true;var pending:Any?=null;var playback=3;var error:String?=null;var queueScope:Int?=1;var intent=false;var retirements=0
 var restoredShuffle:Boolean?=null;var modeRestored=false
 val durations=mutableMapOf<String,Long>();val grants=mutableMapOf<String,Grant>()
 fun validate(rows:List<MediaItem>){check(rows.map{it.mediaId}.distinct().size==rows.size);rows.forEach{grants.putIfAbsent(it.localConfiguration!!.uri.toString(),Grant())}}
 fun selected()=items.getOrNull(index)
 fun bounded(item:MediaItem,value:Long)=value.coerceIn(0,12000)
 fun done()=ListenableFuture<Unit>()
 fun retireSelection(){retirements++;selectedLoaded=false;pending=null}
 fun clearQueue(){retireSelection();items=emptyList();order=emptyList();index=0;position=0;intent=false}
 fun handlePrepare(){check(!intent){"Paused mutation must not manufacture Play"}}
 METHODS
 val mediaItemCount get()=items.size
 val currentMediaItemIndex get()=index
 val currentPosition get()=position
 fun getMediaItemAt(i:Int)=items[i]
 fun addMediaItem(i:Int,item:MediaItem)=handleAddMediaItems(i,listOf(item))
 fun moveMediaItem(f:Int,t:Int)=handleMoveMediaItems(f,f+1,t)
 fun removeMediaItem(i:Int)=handleRemoveMediaItems(i,i+1)
 fun clearMediaItems()=handleRemoveMediaItems(0,items.size)
 fun pause(){intent=false}
 fun seekTo(i:Int,p:Long){index=i;position=p}
 fun setMediaItems(items:List<MediaItem>,index:Int,position:Long)=handleSetMediaItems(items,index,position)
}
object SessionError {const val ERROR_BAD_VALUE=-3;const val ERROR_PERMISSION_DENIED=-4}
class SessionResult(val resultCode:Int) {companion object {const val RESULT_SUCCESS=0}}
object Futures {fun immediateFuture(value:SessionResult)=value}
class Session {fun current(scope:Int)=scope==1}
class Graph {val session=Session()}
class Transport(val player:NativeBoundary) {fun pause(){player.pause()};fun retire(){};fun rejectSelection(){};fun selectionCommitted(){}}
class UndoBoundary(val player:NativeBoundary) {
 val graph=Graph();var account:Int?=1;val grants=player.grants;val transport=Transport(player)
 var undo:List<MediaItem>?=null;var undoScope:Int?=null;var undoIndex=0;var undoPosition=0L;var selectionEpoch=0L
 fun publishSessionExtras(){}
 fun validateSelection(saved:List<MediaItem>,index:Int,position:Long){check(saved.isEmpty()||index in saved.indices);check(position>=0)}
 fun capture(){val scope=1
 CAPTURE
 }
 fun restore():SessionResult {
 UNDO
 }
}
class Controller(val controller:NativeBoundary?) {
 fun retireScratch(){}
 COMMANDS
}
fun main() {
 val p=NativeBoundary();p.items=listOf(MediaItem("a-first"),MediaItem("b",track=8),MediaItem("a-second"));p.order=listOf(0,1,2);p.index=2;p.validate(p.items)
 val c=Controller(p)
 val recovery=UndoBoundary(p);recovery.capture()
 c.moveTo("a-first",2)
 check(p.items.map{it.mediaId}==listOf("b","a-second","a-first"));check(p.selected()!!.mediaId=="a-second");check(p.position==4300L);check(!p.intent);check(p.retirements==0)
 check(recovery.restore().resultCode==0);check(p.items.map{it.mediaId}==listOf("a-first","b","a-second"));check(p.selected()!!.mediaId=="a-second");check(p.position==4300L);check(!p.intent)
 recovery.capture()
 c.remove("a-first");check(p.items.map{it.mediaId}==listOf("b","a-second"));check(p.selected()!!.mediaId=="a-second");check(p.position==4300L);check(!p.intent)
 check(recovery.restore().resultCode==0);check(p.items.map{it.mediaId}==listOf("a-first","b","a-second"));check(p.selected()!!.mediaId=="a-second");check(p.position==4300L);check(!p.intent)
 recovery.capture();c.clear();check(p.items.isEmpty());check(recovery.restore().resultCode==0);check(p.items.map{it.mediaId}==listOf("a-first","b","a-second"));check(p.selected()!!.mediaId=="a-second");check(p.position==4300L);check(!p.intent)
 c.select("b");check(p.selected()!!.mediaId=="b");check(p.position==0L);check(!p.intent)
 p.position=2700;c.enqueue(Track(TrackId(7)),false);check(p.position==2700L);check(!p.intent)
 // Play next inserts before existing manual items. Add inserts after the manual run.
 p.items=listOf(MediaItem("current"),MediaItem("manual",manual=true),MediaItem("context"));p.index=0;p.order=listOf(0,1,2);p.position=4300;p.validate(p.items)
 c.enqueue(Track(TrackId(11)),true);check(p.items.map{it.mediaId}==listOf("current","11","manual","context"));check(p.position==4300L)
 c.enqueue(Track(TrackId(12)),false);check(p.items.map{it.mediaId}==listOf("current","11","manual","12","context"));check(p.position==4300L);check(!p.intent)
 c.clear();check(p.items.isEmpty());check(!p.intent)
 val shuffled=NativeCallbackTraversal.permutation(5,2,Random(19))
 check(shuffled.first()==2);check(shuffled.sorted()==(0..4).toList());check(shuffled.drop(1)!=listOf(0,1,3,4))
 check(NativeCallbackTraversal.next(shuffled,2,1,true)==2)
 check(NativeCallbackTraversal.next(shuffled,2,1,false)==shuffled[1])
 check(NativeCallbackTraversal.next(shuffled,shuffled.last(),0,true)==null)
 check(NativeCallbackTraversal.next(shuffled,shuffled.last(),2,true)==2)
 check(NativeCallbackTraversal.previous(shuffled,2,2)==shuffled.last())
 println("PASS production native shuffle/next/previous/repeat off/all/one traversal policy (not audible transition)")
 println("PASS exact native A/B/A move/remove/clear + service Undo cursor, controller select and manual Play next/Add boundary (host boundaries only)")
}
'''.replace('METHODS',methods).replace('COMMANDS',commands).replace('CAPTURE',capture).replace('UNDO',undo)
with tempfile.TemporaryDirectory(prefix='ordinary-queue-',dir=os.environ['TMPDIR']) as out:
 d=Path(out)
 (d/'Probe.kt').write_text(fixture)
 source=Path(os.environ.get('SOUNDQ_PLAYER_RETURN_SOURCE',str(P/'product/ProductApp.kt'))).read_text()
 app=source.split('"Player"->{',1)[1].split('"Queue"->QueuePanel',1)[0]
 close=block(app,'onClose=')[len('onClose='):]
 queue=block(app,'onQueue=')[len('onQueue='):]
 queue_call=source.split('"Queue"->QueuePanel',1)[1]
 dismiss=block(queue_call,'{')
 open_player=block(queue_call[queue_call.index(dismiss)+len(dismiss):],'{')
 root_entry=block(next(line for line in source.splitlines() if 'if(playback.title!=null)SoundQCompactPlayer' in line),'{')
 (d/'Return.kt').write_text('package ordinaryreturn\nfun main(){var panel:String?="Queue";var transportReturn:String?=null;val openPlayer:()->Unit='+open_player+';openPlayer();check(panel=="Player");check(transportReturn=="Queue"){"Queue entry lost invoking queue return target"};val close:()->Unit='+close+';close();check(panel=="Queue"){"Closing Now playing lost invoking Queue"};check(transportReturn==null);panel="Player";val queue:()->Unit='+queue+';queue();check(panel=="Queue");check(transportReturn=="Player"){"Queue dismissal must return to invoking player"};val dismiss:()->Unit='+dismiss+';dismiss();check(panel=="Player");check(transportReturn==null);transportReturn="Queue";val root:()->Unit='+root_entry+';root();check(panel=="Player");check(transportReturn==null){"Fresh compact entry revived an old parent"};close();check(panel==null);println("PASS extracted actual mini/full/queue return callbacks without transport commands")}')
 (d/'Projection.kt').write_text('package com.soundq.android.playback\nobject Player {const val REPEAT_MODE_OFF=0}\nenum class QueueOrigin {Manual,Context}\nclass AcceptedArrangement\nclass PerformanceDeck\nclass TempoPreviewState\n'+dtos)
 (d/'Clear.kt').write_text('package com.soundq.android.product\nimport com.soundq.android.playback.*\n'+confirmation)
 # Run the same JUnit methods as the ordinary Gradle test, not a parallel assertion list.
 tests=(R/'app/src/test/kotlin/com/soundq/android/product/QueueClearCaptureTest.kt').read_text()
 (d/'ClearTest.kt').write_text(tests.replace('import org.junit.Assert.*','').replace('import org.junit.Test','').replace('@Test ','')+'\nfun main(){QueueClearCaptureTest().apply{cancelDoesNotIssueAnyCommandAndConfirmedAbaClearsOnce();ticksAreNotQueueChangesButAbaReorderAndSelectionAre();accountServiceQueueSourceDisposalAndConnectionChangesRefuse()};println("PASS production clear capture regression methods")}\nfun assertTrue(v:Boolean){check(v)}\nfun assertFalse(v:Boolean){check(!v)}\nfun assertEquals(a:Any?,b:Any?){check(a==b){"$a != $b"}}\n')
 compiler=Path.home()/'.gradle/caches/modules-2/files-2.1'
 def jar(group,name,version):return next((compiler/group/name/version).glob('*/*.jar'))
 std=jar('org.jetbrains.kotlin','kotlin-stdlib','2.3.21')
 cp=[jar('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.3.21'),std,jar('org.jetbrains.kotlin','kotlin-script-runtime','2.3.21'),next((compiler/'org.jetbrains.kotlin/kotlin-reflect').glob('*/*/*.jar')),next((compiler/'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm').glob('*/*/*.jar')),jar('org.jetbrains','annotations','23.0.0')]
 java=str(Path(os.environ['JAVA_HOME'])/'bin/java')
 subprocess.run([java,'-XX:ActiveProcessorCount=1','-Xmx512m','-cp',':'.join(map(str,cp)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',str(std),'-d',str(d/'classes'),*map(str,d.glob('*.kt')),str(P/'playback/nativeengine/NativeCallbackTraversal.kt'),str(P/'playback/QueuePolicy.kt')],check=True)
 for name in ['com.soundq.android.playback.nativeengine.ProbeKt','com.soundq.android.product.ClearTestKt','ordinaryreturn.ReturnKt']:
  subprocess.run([java,'-XX:ActiveProcessorCount=1','-cp',str(d/'classes')+':'+str(std),name],check=True)
