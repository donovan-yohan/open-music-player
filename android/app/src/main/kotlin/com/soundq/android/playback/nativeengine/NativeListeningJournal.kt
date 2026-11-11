package com.soundq.android.playback.nativeengine

import androidx.media3.common.MediaItem
import com.soundq.android.AppGraph
import com.soundq.android.playback.MediaGrant
import com.soundq.android.data.deviceaudio.*
import kotlinx.coroutines.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Adapter owned by the canonical callback Player, never by a composable or another player.
 * Store work is serialized on repository IO; queued polls carry the independently current
 * assignment and synchronous seek stamp. Both ordinary decks are observed during overlap.
 */
internal class NativeListeningJournal(private val graph:AppGraph,private val jobs:CoroutineScope) {
    private data class Bound(val binding:NativeListeningBinding,val owner:ContentOwner,val current:()->Boolean)
    private val bindings=mutableMapOf<Int,Bound>()
    private var tail:Job?=null
    private var lastPublication=0L
    suspend fun bind(item:MediaItem,grant:MediaGrant,file:File,deck:NativeCallbackDeck,slot:Int,current:()->Boolean):Long {
        val revision=if(grant.device!=null)null else withContext(Dispatchers.IO) {
            val digest=MessageDigest.getInstance("SHA-256")
            file.inputStream().use {input->val buffer=ByteArray(65536);while(true){check(current());val n=input.read(buffer);if(n<0)break;digest.update(buffer,0,n)}}
            ContentRevision(digest.digest().joinToString(""){"%02x".format(it)},file.length())
        }
        check(current())
        val peers=bindings.filterKeys {it!=slot}.values.filter {it.current()}.map {it.owner}
        val bound=graph.phoneAudio.journal {store,access->
            check(current())
            val source=if(grant.device!=null)requireNotNull(grant.phoneAdmission).source else {
                val key=HistoryKey.Server(ServerAccount(graph.endpoint.identity,grant.scope.accountId),ServerAudioId(grant.track.value))
                requireNotNull(store.bindServerContent(access,key,requireNotNull(revision),deck.durationMs))
            }
            // A simultaneous duplicate is a replay, not a paused-source restoration. Never cache
            // the outgoing cursor in a prepared deck: its completion may reset the source meanwhile.
            val saved=if(deck.durationMs>600000&&source.owner !in peers)store.bookmark(source)?.positionMs ?: 0 else 0
            Bound(NativeListeningBinding(store,source,UUID.fromString(item.mediaId),deck.generation,slot,saved,deck.durationMs,{grant.current(graph)}),source.owner,current)
        } ?: error("Listening journal unavailable")
        check(current());bindings[slot]=bound
        return bound.binding.resumeMs
    }
    fun observe(snapshot:NativeCallbackSnapshot,allowNatural:Boolean=true) {
        if(snapshot.scheduleRevision!=0L||snapshot.error!=0)return
        val captured=bindings.toMap().filterValues {it.current()}.mapNotNull {(slot,b)->snapshot.decks.getOrNull(slot)?.let {Triple(b,it,b.binding.stamp() to b.binding.intentStamp())}}
        val at=System.currentTimeMillis();val before=tail
        val publish=at-lastPublication>=1000;if(publish)lastPublication=at
        tail=jobs.launch {before?.join();graph.phoneAudio.journal(publish) {_,_->captured.forEach {(b,d,stamp)->
            val natural=allowNatural&&stamp.second==b.binding.intentStamp()
            // A revoked terminal cannot become an endpoint checkpoint instead of completion.
            // Nonterminal native advancement still belongs to the retained cursor traversal.
            if(d.naturalEnd==null||natural)b.binding.observe(d,at,stamp.first,natural)
        }}}
    }
    fun transportIntent(playing:Boolean) {
        val captured=bindings.values.map {it to it.binding.fenceIntent()};val before=tail
        tail=jobs.launch {before?.join();graph.phoneAudio.journal {_,_->captured.forEach {(b,stamp)->b.binding.adoptIntent(stamp,playing)}}}
    }
    /** Automatic repeat is a successor traversal, not newer user seek intent. Drain
     * the already qualified outgoing crossing before fencing/minting its successor.
     * A user seek/replacement while IO is held still wins through the independent stamp.
     */
    suspend fun fenceNaturalRepeat(slot:Int,expectedStamp:Long,current:()->Boolean):Boolean {
        val b=bindings[slot] ?: return current()
        val stamp=expectedStamp;val before=tail
        before?.join()
        if(!current()||bindings[slot]!==b||b.binding.intentStamp()!=stamp)return false
        b.binding.fenceSeek();return true
    }
    fun stamp(slot:Int)=bindings[slot]?.binding?.intentStamp() ?: -1L
    fun fenceSeek(slot:Int) {bindings[slot]?.binding?.fenceSeek()}
    suspend fun beginSeek(slot:Int,identity:Long,baseline:Long):Boolean {
        val b=bindings[slot] ?: return true
        return graph.phoneAudio.journal {_,_->b.current()&&b.binding.beginSeek(identity,b.binding.consumedCount())}==true
    }
    fun acknowledgeSeek(slot:Int,revision:Long,position:Long) {
        val b=bindings[slot] ?: return;val before=tail
        tail=jobs.launch {before?.join();graph.phoneAudio.journal {_,_->if(b.current())b.binding.acknowledgeSeek(revision,position)}}
    }
    fun retire(slot:Int?=null,drain:Boolean=false) {
        val removed=if(slot==null)bindings.values.toList().also {bindings.clear()}else listOfNotNull(bindings.remove(slot))
        if(!drain)removed.forEach {it.binding.fenceRetirement()}
        val before=tail
        tail=jobs.launch {before?.join();graph.phoneAudio.journal {_,_->removed.forEach {it.binding.fenceRetirement();it.binding.finish(null)}}}
    }
    fun freeze() {bindings.values.forEach {it.binding.fenceRetirement()}}
    suspend fun finalCursor(snapshot:NativeCallbackSnapshot?) {
        val removed=bindings.values.toList();bindings.clear()
        tail?.join();removed.forEach {it.binding.fenceRetirement()}
        graph.phoneAudio.journal {_,_->removed.forEach {it.binding.finish(snapshot?.decks?.getOrNull(it.binding.deck))}}
    }
}
