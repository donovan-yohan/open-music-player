package com.soundq.android.data.playlists

import com.soundq.android.data.*
import kotlinx.serialization.json.*

internal object QueuePlaylistJson {
    fun add(body:JsonObject,id:PlaylistId,submitted:List<TrackId>):PlaylistAddAck = try {
        fun ids(key:String)=body.getValue(key).jsonArray.map {it.jsonPrimitive.let {p->require(!p.isString&&p!==JsonNull);TrackId(p.long)}}
        val added=ids("added");val skipped=ids("skipped")
        // Go walks submitted occurrences in order. Only first occurrences can
        // be added. Each repeat must appear in the ordered skipped report.
        require(added.distinct()==added && added.all {it in submitted})
        val first=mutableSetOf<TrackId>()
        val expectedAdded=mutableListOf<TrackId>();val expectedSkipped=mutableListOf<TrackId>()
        submitted.forEach {track ->
            if(first.add(track) && track in added)expectedAdded.add(track) else expectedSkipped.add(track)
        }
        require(added==expectedAdded && skipped==expectedSkipped)
        val playlist=PlaylistJson.summary(body.getValue("playlist").jsonObject)
        require(playlist.id==id&&!playlist.draft.isPublic&&playlist.trackCount>=submitted.distinct().size)
        PlaylistAddAck(playlist,added,skipped)
    } catch(_:Exception) {throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
}
