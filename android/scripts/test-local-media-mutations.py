#!/usr/bin/env python3
"""Real queue mutation handlers and traversal; Media3/capability validation are facades."""
from pathlib import Path
import argparse, hashlib, json
p=argparse.ArgumentParser();p.add_argument('--generate',required=True,type=Path);a=p.parse_args()
b=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android'
t=(b/'playback/nativeengine/NativeCallbackPlayer.kt').read_text()
def block(marker):
 start=t.index(marker);i=t.index('{',start)+1;d=1
 while d:d+=(t[i]=='{')-(t[i]=='}');i+=1
 return t[start:i].replace('override fun','fun').replace('private fun mutate','fun mutate')
markers=['    private fun validate(','    private fun mutate(','    override fun handleAddMediaItems(','    private fun rebuilt(','    override fun handleRemoveMediaItems(','    override fun handleMoveMediaItems(','    override fun handleReplaceMediaItems(']
methods='\n'.join(map(block,markers))
text='''package com.soundq.android.localmediamutationprobe
import com.soundq.android.playback.nativeengine.NativeCallbackTraversal
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.QueuePolicy
import com.soundq.android.data.TrackId
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import kotlin.random.Random
private class ListenableFuture<T>
private class Uri(val raw:String) {val scheme get()=raw.substringBefore(':');override fun toString()=raw}
private data class Config(val uri:Uri)
private class Extras(val ref:String?,val track:Long,val local:Boolean) {fun getLong(k:String)=if(k=="trackId")track else 0L;fun getBoolean(k:String)=k=="localOnly"&&local;fun getString(k:String):String?=if(k=="playbackRef")ref else null}
private class Metadata(val extras:Extras?=null,val title:String?="fixture",val artist:String?="artist")
private class MediaItem(val mediaId:String,val localConfiguration:Config?,val mediaMetadata:Metadata=Metadata())
private data class AccountScope(val accountId:String,val epoch:Long=1)
private class Graph {class Endpoint {val identity="fixture"};val endpoint=Endpoint()}
private class Grant(val device:PlaybackRef.Device?,val account:String="server",var current:Boolean=true) {val track=TrackId(1);val localOnly=device!=null;val scope:AccountScope get()=if(device!=null)error("Phone audio has no server scope")else AccountScope(account);fun current(graph:Graph)=current}
private class Probe {
 val grants=mutableMapOf<String,Grant>();var items=emptyList<MediaItem>();var index=0;var selectedLoaded=false;var pending:Any?=null;var playback=0;var queueScope:AccountScope?=null;val graph=Graph();var position=0;var error:Any?=null;var order=emptyList<Int>();val durations=mutableMapOf<String,Long>();var shuffle=false;val random=Random(7);var cancelled=0;var retired=0;var prepares=0
 object Player {const val STATE_IDLE=0}
 fun cancelSuccessor(){cancelled++};fun clearQueue(){items=emptyList();order=emptyList();queueScope=null};fun done()=ListenableFuture<Unit>();fun selected()=items.getOrNull(index);fun retireSelection(){retired++};fun handlePrepare(){prepares++}
METHODS
 fun row(id:String,device:Boolean=true,account:String="server"):MediaItem {val uri=Uri(if(device)"soundqdevice:$id" else "soundq:$id");val ref=if(device)PlaybackRef.Device(UUID.nameUUIDFromBytes(id.toByteArray()).toString(),"a".repeat(64),64,1)else PlaybackRef.Server("fixture",account,1);grants[uri.toString()]=Grant(ref as? PlaybackRef.Device,account);return MediaItem(id,Config(uri),Metadata(Extras(ref.wire(),if(device)0 else 1,device)))}
 fun install(vararg rows:MediaItem){items=rows.toList();order=items.indices.toList();selectedLoaded=true;queueScope=grants.getValue(items.first().localConfiguration!!.uri.toString()).let{if(it.device==null)it.scope else null}}
}
class LocalMediaMutationConsumersTest {
 @Test fun phoneFirstAppendRetainsSelectionAndOrder(){val p=Probe();val a=p.row("a");val b=p.row("b",false);p.install(a);p.handleAddMediaItems(1,listOf(b));assertEquals(listOf(a,b),p.items);assertEquals(listOf(0,1),p.order);assertNull(p.queueScope);assertEquals(0,p.retired)}
 @Test fun phoneFirstMoveRetainsOccurrence(){val p=Probe();val a=p.row("a");val b=p.row("b");val c=p.row("c",false);p.install(a,b,c);p.handleMoveMediaItems(2,3,1);assertEquals(listOf(a,c,b),p.items);assertEquals(0,p.index);assertNull(p.queueScope)}
 @Test fun phoneFirstRemoveSiblingRetainsPlayback(){val p=Probe();val a=p.row("a");val b=p.row("b",false);p.install(a,b);p.handleRemoveMediaItems(1,2);assertEquals(listOf(a),p.items);assertNull(p.queueScope);assertEquals(0,p.prepares)}
 @Test fun phoneFirstReplaceSelectedPreparesOnce(){val p=Probe();val a=p.row("a");val b=p.row("b");p.install(a);p.handleReplaceMediaItems(0,1,listOf(b));assertEquals(listOf(b),p.items);assertNull(p.queueScope);assertEquals(1,p.retired);assertEquals(1,p.prepares)}
 @Test fun removingLeadingServerExposesPhoneAndPrepares(){val p=Probe();val s=p.row("server",false);val d=p.row("phone");p.install(s,d);p.handleRemoveMediaItems(0,1);assertEquals(listOf(d),p.items);assertNull(p.queueScope);assertEquals(1,p.prepares)}
 @Test fun movingPhoneBeforeServerKeepsSelectedServer(){val p=Probe();val s=p.row("server",false);val d=p.row("phone");p.install(s,d);p.handleMoveMediaItems(1,2,0);assertEquals(listOf(d,s),p.items);assertEquals(1,p.index);assertNull(p.queueScope);assertEquals(0,p.prepares)}
 @Test fun serverFirstAppendRetainsServerScope(){val p=Probe();val s=p.row("server",false);val d=p.row("phone");p.install(s);p.handleAddMediaItems(1,listOf(d));assertEquals("server",p.queueScope?.accountId);assertEquals(listOf(s,d),p.items)}
 @Test fun incompatibleServerScopeRefusesBeforeAnyMutation(){val p=Probe();val a=p.row("a");val b=p.row("b",false);val c=p.row("c",false,"other");p.install(a,b);assertTrue(runCatching{p.handleAddMediaItems(2,listOf(c))}.isFailure);assertEquals(listOf(a,b),p.items);assertEquals(0,p.cancelled);assertEquals(0,p.retired)}
 @Test fun staleServerGrantRefusesBeforeAnyMutation(){val p=Probe();val s=p.row("server",false);val d=p.row("phone");p.install(s);p.grants.getValue(s.localConfiguration!!.uri.toString()).current=false;assertTrue(runCatching{p.handleAddMediaItems(1,listOf(d))}.isFailure);assertEquals(listOf(s),p.items);assertEquals(0,p.cancelled)}
}
'''.replace('METHODS',methods)
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'LocalMediaMutationConsumersTest.kt').write_text(text)
(a.generate/'mutation-source-blocks.json').write_text(json.dumps({m:hashlib.sha256(block(m).encode()).hexdigest() for m in markers},indent=2))
