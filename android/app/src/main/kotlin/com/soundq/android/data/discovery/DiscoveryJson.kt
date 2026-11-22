package com.soundq.android.data.discovery

import com.soundq.android.data.SafeFailure
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import java.time.Instant

/** Exact Go wire scalars: do not coerce identifiers, booleans or numbers. */
object DiscoveryJson {
    const val SEARCH_SURFACE_LIMIT=12
    // Go combines ytsearch + YouTube Music, then SoundCloud; session snapshots cap at 50.
    private val maxOrdinaryResults=minOf(SEARCH_SURFACE_LIMIT*3,50)
    private fun string(e:JsonElement):String=e.jsonPrimitive.let {require(it.isString);it.content}
    private fun text(o:JsonObject,key:String)=string(o.getValue(key))
    private fun bool(o:JsonObject,key:String)=o.getValue(key).jsonPrimitive.let {require(!it.isString);it.boolean}
    private fun uuid(value:String):String {ImportJobId(value);return value}
    private inline fun <T> parse(block:()->T):T=try {block()}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    fun search(o:JsonObject,query:String,provider:SourceProvider?=null):SourceResults=parse {
        require(text(o,"query")==query)
        val top=o.getValue("results").jsonArray.map {candidate(it.jsonObject)}
        val entities=mutableListOf<DiscoveryEntity>()
        require(top.size<=maxOrdinaryResults && top.map {it.id}.distinct().size==top.size)
        val grouped=mutableListOf<SourceCandidate>()
        o["sections"]?.jsonArray?.forEach {e->val section=e.jsonObject
            val kind=text(section,"kind")
            section.getValue("items").jsonArray.forEach {item->val i=item.jsonObject
                val c=i["candidate"]?.takeIf {it!=JsonNull}
                if(c!=null)grouped+=candidate(c.jsonObject)
                else DiscoveryResultType.entries.firstOrNull {it.catalogKind!=null&&it.section==kind}?.let {type->
                    require(text(i,"kind")==type.catalogKind)
                    entities+=DiscoveryEntity(type,i["id"]?.let(::string).orEmpty(),text(i,"title"),i["subtitle"]?.let(::string).orEmpty(),i["artist"]?.let(::string).orEmpty(),i["releaseDate"]?.let(::string).orEmpty())
                }
            }
        }
        val rows=(top+grouped).distinctBy {it.id}
        require(rows.size<=maxOrdinaryResults && rows.map {it.id}.distinct().size==rows.size)
        val providers=o.getValue("providers").jsonArray.map {e->val p=e.jsonObject
            ProviderObservation(DiscoveryProvider.entries.single {it.wire==text(p,"provider")},text(p,"status").also {require(it in setOf("ok","timeout","failed","disabled","unsupported"))},p["resultCount"]?.jsonPrimitive?.let {require(!it.isString);it.int.also {n->require(n>=0)}})}
        require(providers.isNotEmpty() && providers.map {it.provider}.distinct().size==providers.size)
        val selection=if(o.containsKey("selectionSessionId"))SourceSession(uuid(text(o,"selectionSessionId")),Instant.parse(text(o,"selectionExpiresAt"))) else null
        require(rows.isEmpty() || selection!=null)
        if(provider!=null) {
            val observation=providers.single()
            val limit=SEARCH_SURFACE_LIMIT * if(provider==SourceProvider.YouTube)2 else 1
            require(observation.provider.wire==provider.wire&&entities.isEmpty()&&rows.all {it.provider==provider})
            // The server persists only the flat candidates in the selection session.
            require(rows.size==top.size&&top.size<=limit&&(top.isEmpty()||observation.status=="ok"))
        }
        SourceResults(query,rows,selection,providers,entities)
    }
    internal fun catalog(o:JsonObject,type:DiscoveryResultType):DiscoveryCatalogPage=parse {
        val kind=requireNotNull(type.catalogKind)
        val rows=o.getValue("results").jsonArray.also {require(it.size<=8)}.map {item->
            val row=item.jsonObject
            require(text(row,"kind")==kind)
            fun optional(key:String)=row[key]?.takeUnless {it==JsonNull}?.let(::string)
            val id=uuid(text(row,"id"))
            val title=text(row,"title").also {require(it.isNotBlank())}
            val artistMbid=optional("artistMbid")?.let(::uuid)
            val score=row["score"]?.takeUnless {it==JsonNull}?.jsonPrimitive?.let {require(!it.isString);it.int}
            DiscoveryEntity(type,id,title,optional("subtitle").orEmpty(),optional("artist").orEmpty(),
                optional("releaseDate").orEmpty(),artistMbid,score).also {require(it.catalogTarget!=null)}
        }
        require(rows.distinctBy {it.id}.size==rows.size)
        val more=bool(o,"hasMore")
        require(!more||rows.isNotEmpty())
        DiscoveryCatalogPage(rows,more)
    }
    fun resolved(o:JsonObject,query:String):SourceResults=parse {
        require(bool(o,"selectionRequired"))
        val row=candidate(o.getValue("candidate").jsonObject)
        val selection=SourceSession(uuid(text(o,"selectionSessionId")),Instant.parse(text(o,"selectionExpiresAt")))
        SourceResults(query,listOf(row),selection,listOf(ProviderObservation(row.provider,"ok")))
    }
    private val videoPreviewKey=Regex("https://(?:www|music)\\.youtube\\.com/watch\\?v=[A-Za-z0-9_-]{11}")
    private val cloudPreviewKey=Regex("https://(?:soundcloud\\.com/[A-Za-z0-9_-]{3,25}/[A-Za-z0-9_-]+|api\\.soundcloud\\.com/tracks/[1-9][0-9]*)")
    private val nonTrackCloudOwners=setOf("pages","settings","discover","stream","you","search","upload","people","groups","tags","popular","charts","terms-of-use","privacy")
    private val nonTrackCloudSections=setOf("sets","likes","tracks","albums","playlists","reposts","followers","following","popular-tracks")
    private fun previewSource(value:JsonElement?,provider:SourceProvider):ImportSource? {
        val key=(value as? JsonPrimitive)?.takeIf {it.isString}?.content ?: return null
        val canonical=if(provider==SourceProvider.YouTube)videoPreviewKey else cloudPreviewKey
        if(key.startsWith("https://soundcloud.com/")) {
            val path=key.removePrefix("https://soundcloud.com/").lowercase()
            if(path.substringBefore('/') in nonTrackCloudOwners||path.substringAfter('/') in nonTrackCloudSections)return null
        }
        return ImportSource.parse(key)?.takeIf {it.provider==provider.wire&&it.url==key&&canonical.matches(key)}
    }
    fun candidate(o:JsonObject):SourceCandidate {
        val id=text(o,"candidateId");require(id.isNotBlank()&&id.length<=1024&&id.none {it.code<32})
        val provider=SourceProvider.entries.single {it.wire==text(o,"provider")}
        val source=ImportSource.parse(text(o,"sourceUrl")) ?: error("unsupported source")
        require(source.provider==provider.wire)
        val duration=o["durationMs"]?.jsonPrimitive?.let {require(!it.isString);it.long.also {n->require(n>=0)}} ?: 0
        return SourceCandidate(id,provider,source,text(o,"title"),o["artist"]?.let(::string).orEmpty(),duration,bool(o,"downloadable"),o["uploader"]?.let(::string).orEmpty(),o["metadata"]?.jsonObject?.get("album")?.let(::string).orEmpty(),
            o["sourceId"]?.let(::string).orEmpty(),o["thumbnailUrl"]?.takeUnless {it==JsonNull}?.let(::string),
            o["playable"]?.let {bool(o,"playable")} ?: false,o["explicit"]?.takeUnless {it==JsonNull}?.let {bool(o,"explicit")},previewSource(o["previewSourceUrl"],provider))
    }
    fun decision(o:JsonObject,session:String,candidate:String,knownId:String?=null):SourceDecision=parse {
        // Only an exact previously acknowledged ID can survive the server's session-link purge.
        val linkedSession=o["sessionId"]?.takeIf {it!=JsonNull}?.let(::string)
        require(if(linkedSession==null)knownId!=null else linkedSession==session)
        require(knownId==null || text(o,"id")==knownId)
        require(text(o,"selectedCandidateId")==candidate && text(o,"action")=="selected")
        require(candidate(o.getValue("selectedCandidate").jsonObject).id==candidate)
        SourceDecision(uuid(text(o,"id")),session,candidate,o["downloadJobId"]?.takeIf {it!=JsonNull}?.let {ImportJobId(string(it))})
    }
    fun decisions(o:JsonObject,session:String,candidate:String,offset:Int):Pair<List<SourceDecision>,Int> = parse {
        require(o.getValue("limit").jsonPrimitive.let {!it.isString&&it.int==100} && o.getValue("offset").jsonPrimitive.let {!it.isString&&it.int==offset})
        val rows=o.getValue("items").jsonArray;require(rows.size<=100)
        rows.mapNotNull {e->val d=e.jsonObject
            if(d["sessionId"]?.let(::string)==session && d["selectedCandidateId"]?.let(::string)==candidate)decision(d,session,candidate) else null} to rows.size
    }
    fun queued(o:JsonObject):ImportAcknowledgement=parse {
        // /queue/items returns 202 (new) or 200 (published); queue is not the native listening queue.
        o.getValue("queue").jsonObject
        o.getValue("idempotent").jsonPrimitive.let {require(!it.isString);it.boolean}
        ImportAcknowledgement(ImportJobId(text(o,"downloadJobId")),ImportStatus.Queued)
    }
}
