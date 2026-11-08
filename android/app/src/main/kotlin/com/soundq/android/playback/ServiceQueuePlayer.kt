package com.soundq.android.playback

import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ShuffleOrder
import kotlin.random.Random

/** Application-looper mutation boundary over the sole ExoPlayer, never another queue.
 *
 * Media3 1.11.1 consumes cloneAndInsert/Set/Remove/Move before dispatching the new
 * timeline to its playback thread. Supply the final permutation there, not from
 * a later timeline listener. Snapshots below live only for one synchronous call.
 */
@androidx.annotation.OptIn(UnstableApi::class)
internal class ServiceQueuePlayer(private val output:ExoPlayer,private val random:Random=Random.Default):ForwardingPlayer(output) {
    private var mutationOrder:IntArray?=null
    private val applicationThread=Thread.currentThread()
    private fun plannedOrder()=if(Thread.currentThread()===applicationThread)mutationOrder else null
    var changingTraversal=false
        private set
    init {output.setShuffleOrder(OccurrenceShuffleOrder(IntArray(output.mediaItemCount){it}) {plannedOrder()})}

    private fun rows()=(0 until mediaItemCount).map(::getMediaItemAt)
    private fun order():List<Int> {
        val timeline=currentTimeline
        val result=mutableListOf<Int>()
        var index=timeline.getFirstWindowIndex(true)
        while(index!=C.INDEX_UNSET) {
            check(index !in result && index in 0 until mediaItemCount)
            result.add(index)
            index=timeline.getNextWindowIndex(index,Player.REPEAT_MODE_OFF,true)
        }
        check(result.size==mediaItemCount)
        return result
    }
    private fun permutation(length:Int,current:Int):IntArray {
        if(length==0)return intArrayOf()
        val selected=current.coerceIn(0,length-1)
        val natural=(0 until length).filter {it!=selected}
        val future=natural.shuffled(random).toMutableList()
        if(length>2 && future==natural) {val first=future[0];future[0]=future[1];future[1]=first}
        return (listOf(selected)+future).toIntArray()
    }
    private inline fun mutate(order:IntArray,action:()->Unit) {
        check(mutationOrder==null)
        mutationOrder=order
        try {action()}finally {mutationOrder=null}
    }
    override fun setShuffleModeEnabled(shuffleModeEnabled:Boolean) {
        if(shuffleModeEnabled==getShuffleModeEnabled())return
        val next=if(shuffleModeEnabled)permutation(mediaItemCount,currentMediaItemIndex) else IntArray(mediaItemCount){it}
        changingTraversal=true
        try {output.setShuffleOrder(OccurrenceShuffleOrder(next) {plannedOrder()})}finally {changingTraversal=false}
        super.setShuffleModeEnabled(shuffleModeEnabled)
    }

    // Saved-mode restoration is distinct from a newly selected canonical context.
    private var restoredShuffle:Boolean?=null
    fun <T> restoringShuffle(enabled:Boolean,action:()->T):T {
        check(restoredShuffle==null)
        restoredShuffle=enabled
        return try {action()}finally {restoredShuffle=null}
    }
    // Flutter installs a new context in canonical order, even with shuffle already on.
    override fun setMediaItems(mediaItems:List<MediaItem>,startIndex:Int,startPositionMs:Long) {
        require(startIndex==C.INDEX_UNSET || startIndex in mediaItems.indices || mediaItems.isEmpty() && startIndex==0)
        val next=if(restoredShuffle==true)permutation(mediaItems.size,startIndex) else IntArray(mediaItems.size){it}
        mutate(next) {super.setMediaItems(mediaItems,startIndex,startPositionMs)}
    }
    override fun setMediaItems(mediaItems:List<MediaItem>,resetPosition:Boolean) {
        mutate(IntArray(mediaItems.size){it}) {super.setMediaItems(mediaItems,resetPosition)}
    }
    override fun setMediaItems(mediaItems:List<MediaItem>)=setMediaItems(mediaItems,true)
    override fun setMediaItem(mediaItem:MediaItem)=setMediaItems(listOf(mediaItem),true)
    override fun setMediaItem(mediaItem:MediaItem,startPositionMs:Long)=setMediaItems(listOf(mediaItem),0,startPositionMs)
    override fun setMediaItem(mediaItem:MediaItem,resetPosition:Boolean)=setMediaItems(listOf(mediaItem),resetPosition)

    private fun insertion(index:Int,items:List<MediaItem>):IntArray {
        val old=rows()
        if(!getShuffleModeEnabled() || old.isEmpty())return IntArray(old.size+items.size){it}
        // Occurrences, not recording IDs. The surviving traversal must not replay history.
        val oldOrder=order().map {old[it].mediaId}
        val next=old.toMutableList().apply {addAll(index,items)}
        val indices=next.mapIndexed {i,item -> item.mediaId to i}.toMap()
        require(indices.size==next.size)
        val retained=oldOrder.map {indices.getValue(it)}.toMutableList()
        var slot=retained.size
        val continuation=items.all {it.mediaMetadata.extras?.getString("origin")=="Continuation"}
        if(!continuation && items.all {it.mediaMetadata.extras?.getBoolean("manual")==true}) {
            val current=old.getOrNull(currentMediaItemIndex)?.mediaId
            slot=oldOrder.indexOf(current)+1
            while(slot<retained.size && retained[slot]<index && next[retained[slot]].mediaMetadata.extras?.getBoolean("manual")==true)slot++
        } else if(!continuation && index<old.size)slot=retained.indexOf(index+items.size)
        retained.addAll(slot,(index until index+items.size).toList())
        return retained.toIntArray()
    }
    override fun addMediaItems(index:Int,mediaItems:List<MediaItem>) {
        require(index in 0..mediaItemCount)
        if(mediaItems.isEmpty())return
        mutate(insertion(index,mediaItems)) {super.addMediaItems(index,mediaItems)}
    }
    override fun addMediaItems(mediaItems:List<MediaItem>)=addMediaItems(mediaItemCount,mediaItems)
    override fun addMediaItem(index:Int,mediaItem:MediaItem)=addMediaItems(index,listOf(mediaItem))
    override fun addMediaItem(mediaItem:MediaItem)=addMediaItems(listOf(mediaItem))

    private fun rebuilt(next:List<MediaItem>,fallback:Int):IntArray {
        val current=currentMediaItem?.mediaId
        val selected=next.indexOfFirst {it.mediaId==current}.takeIf {it>=0} ?: fallback
        return if(getShuffleModeEnabled())permutation(next.size,selected) else IntArray(next.size){it}
    }
    override fun removeMediaItems(fromIndex:Int,toIndex:Int) {
        require(fromIndex in 0..toIndex && toIndex<=mediaItemCount)
        if(fromIndex==toIndex)return
        val next=rows().toMutableList().apply {subList(fromIndex,toIndex).clear()}
        mutate(rebuilt(next,fromIndex.coerceAtMost((next.size-1).coerceAtLeast(0)))) {super.removeMediaItems(fromIndex,toIndex)}
    }
    override fun removeMediaItem(index:Int)=removeMediaItems(index,index+1)
    override fun clearMediaItems()=removeMediaItems(0,mediaItemCount)
    override fun moveMediaItems(fromIndex:Int,toIndex:Int,newIndex:Int) {
        require(fromIndex in 0..toIndex && toIndex<=mediaItemCount && newIndex in 0..mediaItemCount-(toIndex-fromIndex))
        if(fromIndex==toIndex || fromIndex==newIndex)return
        val next=rows().toMutableList().apply {val moved=subList(fromIndex,toIndex).toList();subList(fromIndex,toIndex).clear();addAll(newIndex,moved)}
        mutate(rebuilt(next,0)) {super.moveMediaItems(fromIndex,toIndex,newIndex)}
    }
    override fun moveMediaItem(currentIndex:Int,newIndex:Int)=moveMediaItems(currentIndex,currentIndex+1,newIndex)
    override fun replaceMediaItems(fromIndex:Int,toIndex:Int,mediaItems:List<MediaItem>) {
        require(fromIndex in 0..toIndex && toIndex<=mediaItemCount)
        if(fromIndex==toIndex && mediaItems.isEmpty())return
        val next=rows().toMutableList().apply {subList(fromIndex,toIndex).clear();addAll(fromIndex,mediaItems)}
        mutate(rebuilt(next,fromIndex.coerceAtMost((next.size-1).coerceAtLeast(0)))) {super.replaceMediaItems(fromIndex,toIndex,mediaItems)}
    }
    override fun replaceMediaItem(index:Int,mediaItem:MediaItem)=replaceMediaItems(index,index+1,listOf(mediaItem))
}

/** Immutable index traversal. No metadata, playback state or second queue retained. */
@androidx.annotation.OptIn(UnstableApi::class)
internal class OccurrenceShuffleOrder(indices:IntArray,private val mutation:()->IntArray?):ShuffleOrder {
    private val delegate=ShuffleOrder.DefaultShuffleOrder(indices.copyOf(),0L)
    override fun getLength()=delegate.length
    override fun getNextIndex(index:Int)=delegate.getNextIndex(index)
    override fun getPreviousIndex(index:Int)=delegate.getPreviousIndex(index)
    override fun getFirstIndex()=delegate.firstIndex
    override fun getLastIndex()=delegate.lastIndex
    private fun next(fallback:ShuffleOrder):ShuffleOrder {
        val planned=mutation()?.takeIf {it.size==fallback.length}
        val indices=planned ?: IntArray(fallback.length).also {result ->
            var index=fallback.firstIndex
            for(i in result.indices) {result[i]=index;index=fallback.getNextIndex(index)}
        }
        return OccurrenceShuffleOrder(indices,mutation)
    }
    override fun cloneAndInsert(insertionIndex:Int,insertionCount:Int)=next(delegate.cloneAndInsert(insertionIndex,insertionCount))
    override fun cloneAndRemove(indexFrom:Int,indexToExclusive:Int)=next(delegate.cloneAndRemove(indexFrom,indexToExclusive))
    override fun cloneAndMove(fromIndex:Int,toIndex:Int,newIndex:Int)=next(delegate.cloneAndMove(fromIndex,toIndex,newIndex))
    override fun cloneAndSet(length:Int,startIndex:Int)=next(ShuffleOrder.DefaultShuffleOrder(IntArray(length){it},0L))
    // Called by Media3's playback thread only for an unplanned clear/mismatch.
    // Never consult the transient application-looper mutation on that path.
    override fun cloneAndClear()=OccurrenceShuffleOrder(intArrayOf(),mutation)
}
