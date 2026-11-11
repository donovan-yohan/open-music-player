package com.soundq.android.playback.system

import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi

/** The session-facing boundary of the same service player, not another timeline/output.
 *
 * Media3 1.11.1 resumes even on a failed resumption future, and queues commands behind
 * onSetMediaItems. Hand off those callbacks synchronously; retain only prepare/play intent
 * here while the service reads. Pause can then execute (Play/Pause share an admission code).
 * All methods and read completions run on the player's application looper.
 */
@androidx.annotation.OptIn(UnstableApi::class)
internal class ServiceTransportPlayer(player:Player,private val current:()->Boolean):ForwardingPlayer(player) {
    internal class Read(val current:()->Boolean) {
        var prepare=false
        var play=false
        var handoff=true
    }
    private var read:Read?=null
    private var selectionRefused=false
    /** A rejected Set cannot lend its queued Prepare/Play to the previous queue. */
    fun rejectSelection(){selectionRefused=true;retire();super.pause()}
    /** Only an accepted service-owned raw timeline commit may reopen admission. */
    fun selectionCommitted(){retire();selectionRefused=false}
    private val intent=java.util.concurrent.atomic.AtomicLong()
    val revision:Long get()=intent.get()
    var onIntentChanged:()->Unit = {}
    val resolving:Boolean get()=read!=null

    fun begin(current:()->Boolean):Read {
        retire()
        super.pause()
        return Read(current).also {read=it}
    }
    /** Called before returning the immediate empty callback result. */
    fun handoff():List<MediaItem> {read?.handoff=true;return emptyList()}
    fun accepts(owner:Read)=read===owner && current() && owner.current()
    fun complete(owner:Read,items:List<MediaItem>,index:Int,position:Long) {
        if(!accepts(owner)){fail(owner);return}
        if(items.isEmpty()){fail(owner);return}
        installSelection {super.setMediaItems(items,index,position)}
        if(owner.prepare || owner.play)super.prepare()
        if(owner.play)super.play()
    }
    fun fail(owner:Read) {if(read===owner)rejectSelection()}
    private fun installSelection(install:()->Unit) {
        retire()
        selectionRefused=true
        try {install();selectionRefused=false}
        catch(failure:RuntimeException){super.pause();throw failure}
    }
    /** Retiring a read never grants a later completion authority over a new selection. */
    fun retire() {intent.incrementAndGet();onIntentChanged();val pending=read;read=null;if(pending!=null)super.pause()}
    private fun callbackHandoff(items:List<MediaItem>):Boolean {
        val owner=read ?: return false
        if(!owner.handoff || items.isNotEmpty())return false
        owner.handoff=false
        return true
    }
    override fun setMediaItems(mediaItems:List<MediaItem>) {
        if(callbackHandoff(mediaItems))return
        installSelection {super.setMediaItems(mediaItems)}
    }
    override fun setMediaItem(mediaItem:MediaItem) {installSelection {super.setMediaItem(mediaItem)}}
    override fun setMediaItem(mediaItem:MediaItem,startPositionMs:Long) {installSelection {super.setMediaItem(mediaItem,startPositionMs)}}
    override fun setMediaItem(mediaItem:MediaItem,resetPosition:Boolean) {installSelection {super.setMediaItem(mediaItem,resetPosition)}}
    override fun setMediaItems(mediaItems:List<MediaItem>,startIndex:Int,startPositionMs:Long) {
        if(callbackHandoff(mediaItems))return
        installSelection {super.setMediaItems(mediaItems,startIndex,startPositionMs)}
    }
    override fun setMediaItems(mediaItems:List<MediaItem>,resetPosition:Boolean) {
        if(callbackHandoff(mediaItems))return
        installSelection {super.setMediaItems(mediaItems,resetPosition)}
    }
    private fun insertSelection(nonempty:Boolean,insert:()->Unit) {
        retire()
        try {insert();if(nonempty && mediaItemCount>0)selectionRefused=false}
        catch(failure:RuntimeException){rejectSelection();throw failure}
    }
    override fun addMediaItem(mediaItem:MediaItem) {insertSelection(true) {super.addMediaItem(mediaItem)}}
    override fun addMediaItem(index:Int,mediaItem:MediaItem) {insertSelection(true) {super.addMediaItem(index,mediaItem)}}
    override fun addMediaItems(mediaItems:List<MediaItem>) {insertSelection(mediaItems.isNotEmpty()) {super.addMediaItems(mediaItems)}}
    override fun addMediaItems(index:Int,mediaItems:List<MediaItem>) {insertSelection(mediaItems.isNotEmpty()) {super.addMediaItems(index,mediaItems)}}
    override fun prepare() {
        if(!current())return
        val owner=read
        if(owner!=null){if(owner.current())owner.prepare=true else fail(owner);return}
        if(selectionRefused)return
        super.prepare()
    }
    override fun play() {
        if(!current())return
        val owner=read
        if(owner!=null){if(owner.current()){owner.prepare=true;owner.play=true}else fail(owner);return}
        if(selectionRefused)return
        super.play()
    }
    override fun setPlayWhenReady(playWhenReady:Boolean) {if(playWhenReady)play() else pause()}
    override fun pause() {retire();super.pause()}
    override fun stop() {retire();super.stop()}
    override fun clearMediaItems() {retire();super.clearMediaItems()}
}
