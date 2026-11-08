package com.soundq.android.playback

import com.soundq.android.data.*
import kotlin.random.Random

/** Literal Flutter selector: fixed first total, 100-row pages, fresh shuffle then oldest recent. */
internal class LibraryShuffleContinuationSource(private val api:SoundQApi,private val random:Random=Random.Default) {
    fun fetch(scope:AccountScope,excluded:Set<Long>,recent:List<Long>,limit:Int,deadline:Long,valid:()->Boolean):List<Track> {
        if(limit<=0)return emptyList()
        val candidates=linkedMapOf<Long,Track>()
        val seen=hashSetOf<Long>()
        var offset=0
        var total:Int?=null
        fun current()=valid() && System.nanoTime()<deadline
        do {
            if(!current())throw SafeFailure(SafeFailure.Reason.Retired)
            val page=api.ownedLibraryPage(scope,LibraryQuery(),offset,100,::current)
            require(page.limit<=100 && page.scannedIds.size<=100)
            if(!current())throw SafeFailure(SafeFailure.Reason.Retired)
            if(total==null)total=page.total
            if(page.scannedIds.isEmpty())break
            var progressed=false
            val rows=page.tracks.distinctBy {it.id.value}.associateBy {it.id.value}
            page.scannedIds.forEach {id ->
                if(seen.add(id)) {
                    progressed=true
                    val track=rows[id]
                    if(id>0 && track!=null && track.durationMs>=1000 && id !in excluded)candidates[id]=track
                }
            }
            offset+=page.scannedIds.size
            if(!progressed)break
        }while(offset<total)
        val fresh=candidates.keys.filter {it !in recent}.shuffled(random)
        return (fresh+recent.filter(candidates::containsKey)).distinct().take(limit).map(candidates::getValue)
    }
}
