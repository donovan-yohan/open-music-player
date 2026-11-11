package com.soundq.android.playback.system

import com.soundq.android.data.*

/** Stable browser IDs are not playback occurrence IDs or signed source capabilities. */
internal data class SystemTrack(val track:Track,val localOnly:Boolean) {
    val mediaId:String get()=(if(localOnly) "device:" else "library:")+track.id.value
}
internal data class SystemPage(val tracks:List<SystemTrack>,val total:Int)
internal class SystemMediaCatalog(private val session:AccountSession,
    private val remote:(AccountScope,LibraryQuery,Int)->LibraryPage,
    private val local:(AccountScope)->List<Track>) {
    private var owner:AccountScope?=null
    private val admitted=linkedMapOf<String,SystemTrack>()
    @Synchronized private fun accept(scope:AccountScope,rows:List<SystemTrack>) {
        session.checkScope(scope)
        if(owner?.let {it.owner!==scope.owner || it.epoch!=scope.epoch}!=false){owner=scope;admitted.clear()}
        rows.forEach {row -> admitted.remove(row.mediaId);admitted[row.mediaId]=row}
        while(admitted.size>500)admitted.remove(admitted.keys.first())
    }
    fun page(scope:AccountScope,device:Boolean,query:String,page:Int,size:Int):SystemPage {
        require(page>=0 && size in 1..100 && page.toLong()*size<=100_000 && query.length<=200 && query.none {it.code<32})
        session.checkScope(scope)
        val offset=page*size
        if(device || !session.remoteCurrent(scope)) {
            val rows=local(scope).filter {query.isBlank() || it.title.contains(query,true) || it.artist.contains(query,true) || it.album.contains(query,true)}
            val selected=rows.drop(offset).take(size).map {SystemTrack(it,true)}
            accept(scope,selected);return SystemPage(selected,rows.size)
        }
        val selected=mutableListOf<SystemTrack>();var total=0;var next=offset
        do {
            session.checkRemote(scope)
            val result=remote(scope,LibraryQuery(text=query),next)
            session.checkRemote(scope)
            total=result.total
            selected+=result.tracks.take(size-selected.size).map {SystemTrack(it,false)}
            next+=result.tracks.size
            if(result.tracks.isEmpty())break
        } while(selected.size<size && next<total)
        accept(scope,selected)
        return SystemPage(selected,total)
    }
    @Synchronized fun item(scope:AccountScope,id:String):SystemTrack? {
        if(!session.current(scope)||owner?.let {it.owner===scope.owner && it.epoch==scope.epoch}!=true || !Regex("(?:library|device):[1-9][0-9]{0,18}").matches(id))return null
        return admitted[id]?.takeIf {it.localOnly||session.remoteCurrent(scope)}
    }
}
