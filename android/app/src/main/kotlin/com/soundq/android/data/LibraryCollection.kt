package com.soundq.android.data

/** Literal metadata membership, not a search expression or recording identity. */
data class LibraryCollection(val artist:String?=null,val album:String?=null) {
    init {require(artist!=null||album!=null)}
    fun contains(track:Track):Boolean=(artist==null||track.artist==artist)&&(album==null||track.album==album)
}

/** Full server-refined corpus first, exact local membership second. Never title/artist dedupe.
 * Offset advances by raw scanned rows, including ineligible rows. There is no page/selection cap.
 */
internal fun readLibraryCorpus(scope:AccountScope,query:LibraryQuery,fetch:(AccountScope,LibraryQuery,Int)->LibraryPage,valid:()->Boolean):LibraryPage {
    var offset=0
    var total:Int?=null
    val rows=mutableListOf<Track>()
    val ids=mutableSetOf<TrackId>()
    val scannedIds=mutableSetOf<Long>()
    val analysis=mutableMapOf<TrackId,LibraryAnalysisFacts>()
    do {
        if(!valid())throw SafeFailure(SafeFailure.Reason.Retired)
        val page=fetch(scope,query.copy(collection=null),offset)
        if(!valid())throw SafeFailure(SafeFailure.Reason.Retired)
        // A changing corpus must be reloaded, never presented as a complete selection.
        if(page.offset!=offset||page.total<0||(total!=null&&page.total!=total))throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        total=page.total
        // Repeated raw identities reveal an inconsistent scan even when totals match.
        // Check before membership filtering, including rows excluded by the API parser.
        if(page.scannedIds.any {!scannedIds.add(it)})throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        page.tracks.forEach {track->
            if((!query.liked||track.liked==true)&&(query.collection?.contains(track)!=false)&&ids.add(track.id)) {
                rows+=track;page.analysis[track.id]?.let {analysis[track.id]=it}
            }
        }
        val next=offset.toLong()+page.scannedIds.size
        if(next>Int.MAX_VALUE||(next<=offset&&offset<page.total))throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        offset=next.toInt()
    }while(offset<total!!)
    return LibraryPage(rows.toList(),rows.size,rows.size.coerceAtLeast(1),0,analysis=analysis.toMap())
}
