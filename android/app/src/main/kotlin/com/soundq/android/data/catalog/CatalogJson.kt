package com.soundq.android.data.catalog

import com.soundq.android.data.SafeFailure
import kotlinx.serialization.json.*

/** Exact Go MusicBrainz DTOs, not the local /search/artists `data` envelope. */
object CatalogJson {
    fun resolution(body:JsonObject,expected:RecordingMbid,account:String):CatalogResolution=checked {
        fun canonical(s:String) {require(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").matches(s) && s!="00000000-0000-0000-0000-000000000000")}
        canonical(expected.value);canonical(account)
        val recording=body.text("recordingMbid");val user=body.text("userId")
        canonical(recording);canonical(user);require(recording==expected.value && user==account)
        require(integer(body.getValue("limit"))==20L)
        val truncated=body.flag("truncated")
        val candidates=body.getValue("candidates").jsonArray.map {element->val row=element.jsonObject
            CatalogResolutionCandidate(integer(row.getValue("trackId")).also {require(it>0)},row.flag("mbVerified"),row.flag("inLibrary"))}
        require(candidates.size<=20 && candidates.zipWithNext().all {(a,b)->a.trackId<b.trackId})
        require(!truncated || candidates.size==20)
        val status=body.text("status")
        val actual=when {truncated||candidates.size>1->"ambiguous";candidates.isEmpty()->"missing";!candidates.single().mbVerified->"needs_review";candidates.single().inLibrary->"owned";else->"stored_unowned"}
        require(status==actual)
        CatalogResolution(expected,user,status,candidates,truncated)
    }
    fun releases(body:JsonObject,offset:Int):CatalogAlbums=checked {
        val total=integer(body.getValue("total")).also {require(it<=Int.MAX_VALUE)}.toInt()
        require(integer(body.getValue("limit"))==20L && integer(body.getValue("offset"))==offset.toLong())
        val rows=body.getValue("data").jsonArray.map {element->val row=element.jsonObject
            val localId=integer(row.getValue("id")).also {require(it>0)}
            val count=integer(row.getValue("trackCount")).also {require(it<=Int.MAX_VALUE)}.toInt()
            CatalogAlbumRow(localId,row.optional("mbReleaseId")?.let(::ReleaseMbid),row.text("name"),row.optional("artist"),count)
        }
        require(rows.size<=20 && rows.size<=total && rows.map {it.localId}.distinct().size==rows.size)
        CatalogAlbums(rows,total,offset,20)
    }
    private fun text(value:JsonElement):String=value.jsonPrimitive.let {require(it.isString);it.content.also {s->require(s.length<=16384 && s.none {c->c.code<32 && c !in "\n\t"})}}
    private fun JsonObject.text(key:String):String=text(getValue(key)).also {require(it.isNotBlank())}
    private fun JsonObject.optional(key:String):String?=get(key)?.let(::text)
    private fun integer(value:JsonElement):Long=value.jsonPrimitive.let {require(!it.isString);it.long.also {n->require(n>=0)}}
    private fun JsonObject.number(key:String):Long?=get(key)?.let(::integer)
    private fun JsonObject.flag(key:String):Boolean=getValue(key).jsonPrimitive.let {require(!it.isString);it.boolean}
    private fun JsonObject.rows(key:String):List<JsonObject> = get(key)?.jsonArray?.map {it.jsonObject}.orEmpty()
    private fun <T> checked(block:()->T):T=try {block()}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    fun search(body:JsonObject,offset:Int):CatalogSearch=checked {
        val total=integer(body.getValue("total")).also {require(it<=Int.MAX_VALUE)}.toInt()
        val limit=integer(body.getValue("limit")).also {require(it==20L)}.toInt()
        require(integer(body.getValue("offset"))==offset.toLong())
        val rows=body.getValue("results").jsonArray.map {element -> val row=element.jsonObject
            row.number("score")?.let {require(it<=100)}
            CatalogArtistRow(ArtistMbid(row.text("mbid")),row.text("name"),listOfNotNull(row.optional("type"),row.optional("country"),row.optional("disambiguation")).joinToString(" · "))
        }
        require(rows.size<=limit && rows.size<=total && rows.map {it.id}.distinct().size==rows.size)
        CatalogSearch(rows,total,offset,limit)
    }
    fun artist(body:JsonObject,expected:ArtistMbid):CatalogArtist=checked {
        val id=ArtistMbid(body.text("id"));require(id==expected)
        listOf("sortName","beginDate","endDate").forEach {body.optional(it)}
        val row=CatalogArtistRow(id,body.text("name"),listOfNotNull(body.optional("type"),body.optional("country"),body.optional("disambiguation")).joinToString(" · "))
        val releases=body.rows("releases").map {CatalogReleaseGroup(ReleaseGroupMbid(it.text("id")),it.text("title"),it.optional("date"))}
        require(releases.map {it.id}.distinct().size==releases.size)
        CatalogArtist(row,releases)
    }
    fun album(body:JsonObject,expected:ReleaseMbid):CatalogAlbum=checked {
        val id=ReleaseMbid(body.text("id"));require(id==expected)
        body.optional("artistId")?.let(::ArtistMbid)
        val tracks=body.rows("tracks").map {row ->
            row.optional("artistId")?.let(::ArtistMbid);row.optional("albumId")?.let {require(ReleaseMbid(it)==id)};row.optional("album")
            CatalogRecording(RecordingMbid(row.text("id")),row.text("title"),row.optional("artist"),row.number("duration"),row.number("position")?.also {require(it<=Int.MAX_VALUE)}?.toInt(),row.flag("inLibrary"),row.flag("downloadable"))
        }
        val count=body.number("trackCount")?.also {require(it<=Int.MAX_VALUE && it>=tracks.size)}?.toInt()
        // Repeated recording IDs/positions across discs are legal; retain source order.
        body.optional("coverArtUrl") // Validated as text only; never fetched by this feature.
        CatalogAlbum(id,body.text("title"),body.optional("artist"),body.optional("date"),count,tracks)
    }
}
