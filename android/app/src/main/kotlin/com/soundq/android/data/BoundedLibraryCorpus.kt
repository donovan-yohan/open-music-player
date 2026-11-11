package com.soundq.android.data

import com.soundq.android.playback.QueuePolicy

/** Complete acknowledged offset scan, with raw identity and metadata bounds before publication. */
internal fun readBoundedLibraryCorpus(scope:AccountScope,query:LibraryQuery,fetch:(AccountScope,LibraryQuery,Int)->LibraryPage,current:()->Boolean):LibraryPage {
    var offset=0;var total:Int?=null;var bytes=0L
    val raw=mutableSetOf<Long>();val rows=mutableListOf<Track>();val facts=mutableMapOf<TrackId,LibraryAnalysisFacts>()
    do {
        check(current());val page=fetch(scope,query.copy(collection=null),offset);check(current())
        require(page.offset==offset&&page.total in 0..QueuePolicy.MAX_LOGICAL_TRACKS&&page.limit in 1..500&&page.scannedIds.size<=page.limit)
        if(total==null)total=page.total else require(total==page.total)
        require(page.scannedIds.all {it>0&&raw.add(it)})
        require(page.scannedIds==page.tracks.map {it.id.value}&&page.tracks.distinctBy {it.id}.size==page.tracks.size)
        page.tracks.forEach {track->
            bytes+=QueuePolicy.metadataBytes("00000000-0000-0000-0000-000000000000",track.title,track.artist);require(bytes<=QueuePolicy.MAX_METADATA_BYTES)
            if((!query.liked||track.liked==true)&&query.collection?.contains(track)!=false){rows+=track;page.analysis[track.id]?.let {facts[track.id]=it}}
        }
        val next=Math.addExact(offset,page.scannedIds.size);require(next<=total&&(next>offset||next==total));offset=next
    }while(offset<total)
    check(current());return LibraryPage(rows.toList(),rows.size,rows.size.coerceAtLeast(1),0,analysis=facts.toMap())
}
