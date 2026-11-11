package com.soundq.android.data

import kotlinx.serialization.json.*
import com.soundq.android.data.imports.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant
import java.util.concurrent.TimeUnit

/** Only authenticated HTTP path. Response bodies/credentials/signed URLs never enter errors or logs. */
class SoundQApi(val session: AccountSession, client: OkHttpClient = OkHttpClient(), val intakeReceipts:com.soundq.android.data.acquisition.IntakeReceipts = com.soundq.android.data.acquisition.IntakeReceipts()) {
    private class WireGuard(val valid: () -> Boolean)
    private val http = client.newBuilder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .callTimeout(20, TimeUnit.SECONDS)
        .addNetworkInterceptor { chain ->
            val r = chain.request()
            if (r.tag(WireGuard::class.java)?.valid?.invoke() != true) throw SafeFailure(SafeFailure.Reason.Retired)
            val base = session.endpoint.base
            if (r.url.scheme != base.scheme || r.url.host != base.host || r.url.port != base.port || !r.url.encodedPath.startsWith("/api/v1/")) throw SafeFailure(SafeFailure.Reason.Endpoint)
            chain.proceed(r)
        }.build()
    private val json = Json { ignoreUnknownKeys = true }
    private fun payload(vararg fields: Pair<String, String>) = buildJsonObject { fields.forEach { put(it.first,it.second) } }
    private fun tokens(body: JsonObject): SecretTokens = try {
        SecretTokens(body.getValue("accessToken").jsonPrimitive.content,body.getValue("refreshToken").jsonPrimitive.content,body.getValue("user").jsonObject.getValue("id").jsonPrimitive.content)
    } catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
    private class Reply(val code: Int, val body: JsonObject, val text: String = "")
    private fun wire(path: String, method: String = "GET", body: JsonObject? = null, access: String? = null, dispatchValid: (() -> Boolean)? = null, headers:Map<String,String> = emptyMap(), emptyBody:Boolean=false, rawJson:String?=null, valid: () -> Boolean): Reply {
        if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
        val pathOnly=path.substringBefore('?')
        require(path.startsWith("/") && !path.startsWith("//") && '#' !in path && '\\' !in pathOnly)
        require(pathOnly.split('/').none {part->
            val segment=part.lowercase().replace("%2e",".")
            segment in setOf(".","..") || "%2f" in segment || "%5c" in segment
        })
        val url = (session.endpoint.identity + path).toHttpUrlOrNull() ?: throw SafeFailure(SafeFailure.Reason.Endpoint)
        val request = Request.Builder().url(url).tag(WireGuard::class.java,WireGuard { valid() && (dispatchValid?.invoke() ?: true) }).header("Accept","application/json")
        if (access != null) request.header("Authorization","Bearer $access")
        headers.forEach {(name,value)->require(name=="Idempotency-Key");request.header(name,value)}
        require(rawJson==null || path=="/mix-plans/import" && method=="POST" && body==null && !emptyBody)
        request.method(method, if (method in listOf("GET","HEAD")) null else (rawJson ?: if(emptyBody)"" else body?.toString() ?: "{}").toRequestBody("application/json".toMediaType()))
        try {
            http.newCall(request.build()).execute().use { response ->
                if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
                if (response.code in 300..399) throw SafeFailure(SafeFailure.Reason.Endpoint)
                // Never parse/display server error text, which can echo sensitive input.
                if (response.code !in 200..299) {
                    // Only exchange admits a bounded declared code. No message/hash/body survives.
                    val membership=method=="POST" && Regex("^/catalog/recordings/[0-9a-f-]{36}/membership$").matches(path)
                    if(membership) {
                        val safe=try {val source=response.body.source();if(source.request(8193))null else com.soundq.android.data.catalog.CatalogMembershipJson.refusal(response.code,json.parseToJsonElement(source.readUtf8()).jsonObject)}catch(_:Exception){null}
                        return Reply(response.code,if(safe==null)buildJsonObject {} else buildJsonObject {put("membershipCode",safe.name)})
                    }
                    val exchange=path=="/mix-plans/import" || Regex("^/mix-plans/[0-9a-f-]{36}/export$").matches(path)
                    val code=if(exchange && response.code in setOf(400,403,404,409,413,422)) try {
                        val source=response.body.source()
                        if(source.request(8193))null else {
                            val declared=json.parseToJsonElement(source.readUtf8()).jsonObject["code"]?.jsonPrimitive?.takeIf {v->v.isString}?.content
                            com.soundq.android.data.mix.ExchangeRefusal.Code.entries.firstOrNull {it.name==declared}
                        }
                    } catch(_:Exception){null} else null
                    return Reply(response.code,if(code==null)buildJsonObject {} else buildJsonObject {put("code",code.name)})
                }
                val source = response.body.source()
                // Full signed RGB/tier artifacts are larger than metadata. This bounded
                // exception belongs ONLY to canonical analysis GETs, never arbitrary URLs,
                // queries, overrides or writes. Auth/endpoint/retirement fences above stay shared.
                val responseLimit = if (method == "GET" && Regex("^/tracks/[1-9][0-9]*/analysis$").matches(path)) 16L * 1024 * 1024 else 2_000_000L
                if (source.request(responseLimit + 1)) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                val text = source.readUtf8()
                val parsed = if (text.isBlank()) buildJsonObject {} else json.parseToJsonElement(text).jsonObject
                if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
                return Reply(response.code, parsed, text)
            }
        } catch (e: SafeFailure) { throw e }
        catch (_: java.net.UnknownHostException) { throw SafeFailure(SafeFailure.Reason.Network) }
        catch (_: java.io.IOException) { throw SafeFailure(if (method == "GET") SafeFailure.Reason.Network else SafeFailure.Reason.Uncertain) }
        catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
    }
    fun authenticate(email: String, password: String, username: String? = null): Boolean {
        if (session.state.value is AuthState.SaveRequired) return session.retrySave()
        val intent = session.beginAuthentication() ?: return false
        return try {
            val body = buildJsonObject { put("email",email.trim()); put("password",password); if (username != null) put("username",username) }
            val result = wire(if (username == null) "/auth/login" else "/auth/register", "POST", body, valid = {session.owns(intent)})
            if (result.code !in 200..299) { session.failure(intent,SafeFailure.Reason.Refused); false }
            else session.accept(intent,tokens(result.body))
        } catch (e: SafeFailure) { session.failure(intent,e.reason, e.reason in listOf(SafeFailure.Reason.Uncertain,SafeFailure.Reason.InvalidResponse)); false }
    }
    fun restore(): Boolean = session.restore { refresh(it) }
    fun restoreOnline(ticket:AccountSession.OnlineRestoreTicket):Boolean = session.restoreOnline(ticket) {refresh(it)}
    private fun refresh(scope: AccountScope, access: String? = null, routeValid: () -> Boolean = { true }): Boolean = session.refreshExchange(scope,access) { token ->
        var dispatched = false
        try {
            // A dispatched rotation must still persist on route exit; only admission is route-owned.
            val result = wire("/auth/refresh","POST",payload("refreshToken" to token),
                dispatchValid={ (routeValid()&&session.remoteCurrent(scope)).also { if(it) dispatched=true } },valid={session.rotationCurrent(scope)})
            if (result.code !in 200..299) throw SafeFailure(SafeFailure.Reason.Refused)
            RefreshExchange.Rotated(tokens(result.body))
        } catch(error: SafeFailure) {
            if(!dispatched && error.reason == SafeFailure.Reason.Retired && session.current(scope) && !routeValid())
                RefreshExchange.Undispatched
            else throw error
        }
    }
    private fun authorized(scope: AccountScope, path: String, method: String = "GET", body: JsonObject? = null, readOnly: Boolean = method == "GET", valid: () -> Boolean = { true }, expectedStatus: Int? = null, acceptedStatuses:Set<Int>? = null, dispatchValid: (() -> Boolean)? = null, allowMissing: Boolean = false, headers:Map<String,String> = emptyMap(), emptyBody:Boolean=false, privateFeature: Boolean = false, rawJson:String?=null, received:((String)->Unit)?=null): JsonObject {
        if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
        val access = session.access(scope)
        var result = wire(path,method,body,access,dispatchValid,headers,emptyBody,rawJson) {session.remoteCurrent(scope) && valid()}
        if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
        if (result.code == 401 && readOnly && refresh(scope,access,valid)) {
            if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
            result = wire(path,method,body,session.access(scope),headers=headers,emptyBody=emptyBody,rawJson=rawJson) {session.remoteCurrent(scope) && valid()}
        }
        if (!valid()) throw SafeFailure(SafeFailure.Reason.Retired)
        session.checkScope(scope)
        if (privateFeature && result.code !in 200..299) throw com.soundq.android.data.connect.FeatureFailure(result.code)
        if (allowMissing && result.code == 404) throw PlaylistMissing()
        if (result.code !in 200..299) {
            if(method=="POST" && Regex("^/catalog/recordings/[0-9a-f-]{36}/membership$").matches(path)) {
                val code=result.body["membershipCode"]?.jsonPrimitive?.content?.let {com.soundq.android.data.catalog.CatalogMembershipRefusal.Code.valueOf(it)}
                if(code!=null)throw com.soundq.android.data.catalog.CatalogMembershipRefusal(code)
                if(result.code in setOf(404,503))throw com.soundq.android.data.catalog.CatalogMembershipRefusal(com.soundq.android.data.catalog.CatalogMembershipRefusal.Code.UNAVAILABLE)
            }
            result.body["code"]?.jsonPrimitive?.content?.let {code ->
                throw com.soundq.android.data.mix.ExchangeRefusal(com.soundq.android.data.mix.ExchangeRefusal.Code.valueOf(code))
            }
            if(path=="/mix-plans/import" && result.code in setOf(400,413,422))throw com.soundq.android.data.mix.ExchangeAdmissionRefused()
            val acquisition=path.startsWith("/research-jobs")||path.startsWith("/playlist-imports")||path=="/queue"
            throw SafeFailure(when {acquisition&&result.code==429->SafeFailure.Reason.Capacity;acquisition&&result.code==503->SafeFailure.Reason.ServiceUnavailable;result.code>=500&&!readOnly->SafeFailure.Reason.Uncertain;else->SafeFailure.Reason.Refused})
        }
        if(acceptedStatuses!=null&&result.code !in acceptedStatuses)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        if (expectedStatus != null && result.code != expectedStatus) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        received?.invoke(result.text)
        return result.body
    }
    /** Feature-local transport through the canonical auth/refresh and dispatch fence. */
    internal fun privateExchange(scope:AccountScope,path:String,method:String="GET",body:JsonObject?=null,status:Int=200,valid:()->Boolean):JsonObject {
        require(path=="/me/devices" || Regex("^/me/devices/[0-9a-f-]{36}$").matches(path) || path=="/jams" || Regex("^/jams/[0-9a-f-]{36}(/(host|invites)|/requests/[0-9a-f-]{36}(/approval)?)?$").matches(path))
        return authorized(scope,path,method,body,valid=valid,expectedStatus=status,privateFeature=true)
    }
    /** Narrow nearby metadata read through the sole authenticated client. */
    fun nearbyTracks(scope:AccountScope,query:com.soundq.android.data.harmonic.HarmonicQuery,valid:()->Boolean):com.soundq.android.data.harmonic.NearbyResult {
        require(query.bpm.isFinite()&&query.bpm>0&&query.bpm<=300&&query.tolerance.isFinite()&&query.tolerance in 0.0..50.0&&com.soundq.android.data.harmonic.normalizeHarmonicKey(query.camelot)==query.camelot)
        val url=session.endpoint.base.newBuilder().addQueryParameter("bpm",query.bpm.toString()).addQueryParameter("camelot",query.camelot).addQueryParameter("tolerance",query.tolerance.toString()).apply {if(query.history)addQueryParameter("order","history")}.build()
        val body=try {authorized(scope,"/tracks/nearby?"+url.encodedQuery,valid=valid,expectedStatus=200,allowMissing=true)}
            catch(_:PlaylistMissing){throw com.soundq.android.data.harmonic.NearbyDisabled()}
        return com.soundq.android.data.harmonic.NearbyJson.parse(body)
    }
    /** One network entry, including response-driven OkHttp follow-ups. Never refresh/replay this POST. */
    fun catalogMembership(scope:AccountScope,recording:com.soundq.android.data.catalog.RecordingMbid,track:Long,valid:()->Boolean,dispatchValid:()->Boolean) {
        com.soundq.android.data.catalog.canonicalMembershipId(recording.value);com.soundq.android.data.catalog.canonicalMembershipId(scope.accountId);require(track>0)
        val entered=java.util.concurrent.atomic.AtomicBoolean(false)
        val body=authorized(scope,"/catalog/recordings/${recording.value}/membership","POST",buildJsonObject {put("trackId",track)},readOnly=false,valid=valid,expectedStatus=200,
            dispatchValid={valid()&&entered.compareAndSet(false,true)&&dispatchValid()})
        com.soundq.android.data.catalog.CatalogMembershipJson.ack(body,recording,scope.accountId,track)
    }
    fun trackDetailsSnapshot(scope:AccountScope,id:TrackId,valid:()->Boolean):com.soundq.android.data.trackdetails.TrackDetails? {
        var offset=0
        val seen=mutableSetOf<TrackId>()
        var found:com.soundq.android.data.trackdetails.TrackDetails?=null
        repeat(1000) {
            val body=authorized(scope,"/library?limit=100&offset=$offset&sort=added_at&order=desc&fields=id,title,artist,album,duration_ms,is_liked,cover_art_url,artwork_url,mb_verified,has_metadata_override,mb_recording_id,mb_suggestions,codec,bitrate_kbps,sample_rate_hz,channels,source_url",valid=valid,expectedStatus=200)
            val (rows,total)=com.soundq.android.data.trackdetails.TrackDetailsJson.page(body,offset)
            rows.forEach {row->if(!seen.add(row.track.id))throw SafeFailure(SafeFailure.Reason.InvalidResponse);if(row.track.id==id)found=row}
            if(found!=null)return found
            offset+=rows.size
            if(offset>=total)return found
            if(rows.isEmpty())throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        }
        throw SafeFailure(SafeFailure.Reason.InvalidResponse)
    }
    fun trackDetailsAnalysis(scope:AccountScope,id:TrackId,valid:()->Boolean):com.soundq.android.data.trackdetails.AnalysisDetail? = try {
        com.soundq.android.data.trackdetails.AnalysisJson.parse(authorized(scope,"/tracks/${id.value}/analysis",valid=valid,expectedStatus=200,allowMissing=true),id)
    } catch(_:PlaylistMissing){null}
    fun trackDetailsCorrectAnalysis(scope:AccountScope,id:TrackId,base:com.soundq.android.data.trackdetails.AnalysisDetail,correction:com.soundq.android.data.trackdetails.AnalysisCorrection,valid:()->Boolean) {
        val body=authorized(scope,"/tracks/${id.value}/analysis/overrides","PATCH",com.soundq.android.data.trackdetails.AnalysisJson.request(base,correction),valid=valid,expectedStatus=200)
        val accepted=com.soundq.android.data.trackdetails.AnalysisJson.parse(body,id)
        com.soundq.android.data.trackdetails.AnalysisJson.acknowledgement(accepted,base,correction)
    }
    fun trackDetailsVerify(scope:AccountScope,id:TrackId,action:com.soundq.android.data.trackdetails.VerificationAction,valid:()->Boolean):List<com.soundq.android.data.trackdetails.MatchSuggestion> {
        val (path,payload)=com.soundq.android.data.trackdetails.TrackDetailsJson.verificationRequest(action)
        val body=authorized(scope,"/tracks/${id.value}/$path","POST",payload,readOnly=false,valid=valid,expectedStatus=200)
        return com.soundq.android.data.trackdetails.TrackDetailsJson.verificationAck(body,id,action)
    }
    fun trackDetailsRemove(scope:AccountScope,id:TrackId,valid:()->Boolean) {
        authorized(scope,"/library/tracks/${id.value}","DELETE",readOnly=false,valid=valid,expectedStatus=204)
    }
    fun trackDetailsMetadata(scope:AccountScope,id:TrackId,draft:com.soundq.android.data.trackdetails.MetadataDraft,valid:()->Boolean) {
        val body=authorized(scope,"/tracks/${id.value}/metadata-override","PUT",com.soundq.android.data.trackdetails.TrackDetailsJson.metadata(draft),valid=valid,expectedStatus=200)
        com.soundq.android.data.trackdetails.TrackDetailsJson.metadataAck(body,id,draft)
    }
    private fun catalogBody(scope:AccountScope,path:String,valid:()->Boolean):JsonObject = try {
        authorized(scope,path,valid=valid,expectedStatus=200,allowMissing=true)
    } catch(_:PlaylistMissing) {throw com.soundq.android.data.catalog.CatalogMissing()}
    fun catalogSearch(scope: AccountScope, query:String, offset:Int, valid:()->Boolean): com.soundq.android.data.catalog.CatalogSearch {
        require(query.isNotBlank() && query.toByteArray(Charsets.UTF_8).size<=512 && offset>=0)
        val url=session.endpoint.base.newBuilder().addQueryParameter("q",query).addQueryParameter("limit","20").addQueryParameter("offset",offset.toString()).build()
        return com.soundq.android.data.catalog.CatalogJson.search(catalogBody(scope,"/musicbrainz/search/artists?"+url.encodedQuery,valid),offset)
    }
    fun catalogReleases(scope:AccountScope,query:String,offset:Int,valid:()->Boolean):com.soundq.android.data.catalog.CatalogAlbums {
        require(query.isNotBlank() && query.toByteArray(Charsets.UTF_8).size<=512 && offset>=0)
        val url=session.endpoint.base.newBuilder().addQueryParameter("q",query).addQueryParameter("limit","20").addQueryParameter("offset",offset.toString()).build()
        return com.soundq.android.data.catalog.CatalogJson.releases(catalogBody(scope,"/search/releases?"+url.encodedQuery,valid),offset)
    }
    fun catalogArtist(scope: AccountScope, id:com.soundq.android.data.catalog.ArtistMbid, valid:()->Boolean): com.soundq.android.data.catalog.CatalogArtist =
        com.soundq.android.data.catalog.CatalogJson.artist(catalogBody(scope,"/artists/${id.value}",valid),id)
    fun catalogAlbum(scope: AccountScope, id:com.soundq.android.data.catalog.ReleaseMbid, valid:()->Boolean): com.soundq.android.data.catalog.CatalogAlbum =
        com.soundq.android.data.catalog.CatalogJson.album(catalogBody(scope,"/albums/${id.value}",valid),id)
    fun catalogResolution(scope:AccountScope,id:com.soundq.android.data.catalog.RecordingMbid,valid:()->Boolean):com.soundq.android.data.catalog.CatalogResolution {
        require(id.value!="00000000-0000-0000-0000-000000000000")
        val body=try {authorized(scope,"/catalog/recordings/${id.value}/resolution",valid=valid,expectedStatus=200,privateFeature=true)}
            catch(error:com.soundq.android.data.connect.FeatureFailure) {if(error.status in setOf(404,503))throw com.soundq.android.data.catalog.CatalogResolutionUnavailable() else throw SafeFailure(SafeFailure.Reason.Refused)}
        return com.soundq.android.data.catalog.CatalogJson.resolution(body,id,scope.accountId)
    }
    fun mixStemStatus(scope:AccountScope,track:Long,channelSet:String,valid:()->Boolean):JsonObject {
        require(track>0 && channelSet in setOf("stems4-demucs-v1","stems5-hybrid-v1"))
        return authorized(scope,"/tracks/$track/stems?channelSet=$channelSet&includeUrls=1",valid=valid,expectedStatus=200)
    }
    /** Metadata-only endpoint allowlist. Uses the sole credential/refresh/dispatch policy. */
    internal fun mixExchange(scope:AccountScope,id:String?=null,rawImport:String?=null,valid:()->Boolean):com.soundq.android.data.mix.ExchangeDocument {
        require((id==null)!=(rawImport==null))
        if(id!=null)require(java.util.UUID.fromString(id).toString()==id)
        var text=""
        val body=if(rawImport!=null) {
            com.soundq.android.data.mix.validateExchangeInput(rawImport)
            authorized(scope,"/mix-plans/import","POST",readOnly=false,valid=valid,expectedStatus=201,rawJson=rawImport,received={text=it})
        } else authorized(scope,"/mix-plans/$id/export",valid=valid,expectedStatus=200,received={text=it})
        return com.soundq.android.data.mix.ExchangeDocument(body,text)
    }
    internal fun mixExchangeReadback(scope:AccountScope,id:String,valid:()->Boolean):JsonObject {
        require(java.util.UUID.fromString(id).toString()==id)
        return authorized(scope,"/mix-plans/$id",valid=valid,expectedStatus=200)
    }
    fun mixPlans(scope:AccountScope,offset:Int,valid:()->Boolean):com.soundq.android.data.mix.MixPage {
        require(offset>=0)
        return com.soundq.android.data.mix.MixJson.page(authorized(scope,"/mix-plans?limit=20&offset=$offset",valid=valid,expectedStatus=200),offset)
    }
    fun mixPlanDocument(scope:AccountScope,id:String,valid:()->Boolean):com.soundq.android.data.playlists.MixPlanDocument {
        require(java.util.UUID.fromString(id).toString()==id)
        return com.soundq.android.data.playlists.PlaylistBlendJson.document(authorized(scope,"/mix-plans/$id",valid=valid,expectedStatus=200)).also {require(it.plan.id==id)}
    }
    fun playlistBlend(scope:AccountScope,detail:com.soundq.android.data.playlists.PlaylistDetail,dispatch:()->Boolean,valid:()->Boolean):com.soundq.android.data.playlists.PlaylistBlendAck {
        require(!detail.playlist.draft.isPublic && detail.tracks.size in 2..500)
        val raw=authorized(scope,"/playlists/${detail.playlist.id.value}/auto-mix","POST",buildJsonObject {},readOnly=false,valid=valid,dispatchValid=dispatch,expectedStatus=200)
        return com.soundq.android.data.playlists.PlaylistBlendJson.ack(raw,detail)
    }
    fun mixPlan(scope:AccountScope,id:String,valid:()->Boolean):com.soundq.android.data.mix.SavedMix {
        require(java.util.UUID.fromString(id).toString()==id)
        return com.soundq.android.data.mix.MixJson.saved(authorized(scope,"/mix-plans/$id",valid=valid,expectedStatus=200)).also {require(it.id==id)}
    }
    fun saveMix(scope:AccountScope,prior:com.soundq.android.data.mix.SavedMix?,name:String,clips:List<com.soundq.android.data.mix.MixClip>,valid:()->Boolean):com.soundq.android.data.mix.SavedMix {
        val draft=com.soundq.android.data.mix.MixJson.draft(name,clips)
        val payload=if(prior==null)draft else JsonObject(draft+ ("version" to JsonPrimitive(prior.version)))
        val acknowledged=com.soundq.android.data.mix.MixJson.saved(authorized(scope,if(prior==null)"/mix-plans" else "/mix-plans/${prior.id}",if(prior==null)"POST" else "PUT",payload,readOnly=false,valid=valid,expectedStatus=if(prior==null)201 else 200))
        if(acknowledged.draft()!=draft || prior!=null && (acknowledged.id!=prior.id || acknowledged.version!=prior.version+1))throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        // Never repeat a write to recover an uncertain response. GET is the only verification.
        return mixPlan(scope,acknowledged.id,valid).also {if(it!=acknowledged)throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    }
    fun playlists(scope: AccountScope, offset: Int, valid: () -> Boolean = { true }): com.soundq.android.data.playlists.PlaylistPage {
        require(offset >= 0)
        val body = authorized(scope, "/playlists?limit=20&offset=$offset", valid = valid)
        return com.soundq.android.data.playlists.PlaylistJson.page(body, offset)
    }
    fun browsePlaylists(scope: AccountScope, offset: Int, query: String, sort: String, order: String, valid: () -> Boolean): com.soundq.android.data.playlists.PlaylistPage {
        require(offset >= 0 && sort in setOf("updated_at", "name", "track_count") && order in setOf("asc", "desc"))
        val url = session.endpoint.base.newBuilder().addQueryParameter("limit", "20").addQueryParameter("offset", offset.toString())
            .addQueryParameter("q", query).addQueryParameter("sort", sort).addQueryParameter("order", order).build()
        return com.soundq.android.data.playlists.PlaylistJson.page(authorized(scope, "/playlists?" + url.encodedQuery, valid = valid, expectedStatus = 200), offset)
    }
    fun createPlaylist(scope: AccountScope, draft: com.soundq.android.data.playlists.PlaylistDraft, valid: () -> Boolean = { true }): com.soundq.android.data.playlists.PlaylistSummary {
        require(!draft.isPublic)
        val body = authorized(scope, "/playlists", "POST", com.soundq.android.data.playlists.PlaylistJson.draft(draft), valid = valid, expectedStatus = 201)
        return com.soundq.android.data.playlists.PlaylistJson.summary(body).also {
            if (it.draft != draft || it.trackCount != 0 || it.durationMs != 0L) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        }
    }
    private class PlaylistMissing : Exception()
    fun playlistManagementSnapshot(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, valid: () -> Boolean): com.soundq.android.data.playlists.PlaylistDetail? = try {
        com.soundq.android.data.playlists.PlaylistJson.detail(authorized(scope,"/playlists/${id.value}",valid=valid,expectedStatus=200,allowMissing=true),id)
    } catch (_: PlaylistMissing) { null }
    fun deletePrivatePlaylist(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, valid: () -> Boolean) {
        authorized(scope,"/playlists/${id.value}","DELETE",readOnly=false,valid=valid,expectedStatus=204)
    }
    fun renamePlaylist(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, draft: com.soundq.android.data.playlists.PlaylistDraft, valid: () -> Boolean): com.soundq.android.data.playlists.PlaylistSummary {
        val body = authorized(scope, "/playlists/${id.value}", "PUT", com.soundq.android.data.playlists.PlaylistJson.draft(draft), readOnly = false, valid = valid, expectedStatus = 200)
        return com.soundq.android.data.playlists.PlaylistJson.summary(body).also {
            if (it.id != id || it.draft != draft) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        }
    }
    fun removePlaylistMembers(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, tracks: List<TrackId>, valid: () -> Boolean): com.soundq.android.data.playlists.PlaylistDetail {
        require(tracks.size in 1..100 && tracks.distinct().size == tracks.size)
        val body = authorized(scope, "/playlists/${id.value}/tracks/batch-remove", "POST", buildJsonObject { put("trackIds", buildJsonArray { tracks.forEach { add(it.value) } }) }, readOnly = false, valid = valid, expectedStatus = 200)
        return com.soundq.android.data.playlists.PlaylistJson.detail(body, id).also {
            if (!it.canManage || it.tracks.any { row -> row.id in tracks }) throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        }
    }
    fun removePlaylistMember(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, track: TrackId, valid: () -> Boolean): com.soundq.android.data.playlists.PlaylistDetail =
        removePlaylistMembers(scope, id, listOf(track), valid)
    fun restorePlaylistPosition(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, track: TrackId, position: Int, valid: () -> Boolean): com.soundq.android.data.playlists.PlaylistDetail {
        require(position >= 0)
        val body = authorized(scope, "/playlists/${id.value}/tracks/reorder", "PUT", buildJsonObject { put("trackId", track.value); put("newPosition", position) }, readOnly = false, valid = valid, expectedStatus = 200)
        return com.soundq.android.data.playlists.PlaylistJson.detail(body, id)
    }
    /** Queue-save uses the same Go endpoints, with account-owned response and route-owned dispatch. */
    fun createQueuePlaylist(scope: AccountScope, draft: com.soundq.android.data.playlists.PlaylistDraft, valid: () -> Boolean, admit: () -> Boolean): com.soundq.android.data.playlists.PlaylistSummary {
        require(!draft.isPublic)
        val body=authorized(scope,"/playlists","POST",com.soundq.android.data.playlists.PlaylistJson.draft(draft),readOnly=false,valid=valid,expectedStatus=201,dispatchValid=admit)
        return com.soundq.android.data.playlists.PlaylistJson.summary(body).also {
            if(it.draft!=draft || it.trackCount!=0 || it.durationMs!=0L)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        }
    }
    fun addQueuePlaylistTracks(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, tracks: List<TrackId>, valid: () -> Boolean, admit: () -> Boolean): com.soundq.android.data.playlists.PlaylistAddAck {
        require(tracks.isNotEmpty())
        val body=authorized(scope,"/playlists/${id.value}/tracks","POST",buildJsonObject {put("trackIds",buildJsonArray {tracks.forEach {add(it.value)}})},readOnly=false,valid=valid,expectedStatus=200,dispatchValid=admit)
        return com.soundq.android.data.playlists.QueuePlaylistJson.add(body,id,tracks)
    }
    fun addPlaylistTrack(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, track: TrackId, valid: () -> Boolean = { true }): com.soundq.android.data.playlists.PlaylistAddAck {
        val body = authorized(scope, "/playlists/${id.value}/tracks", "POST", buildJsonObject { put("trackIds", buildJsonArray { add(track.value) }) }, readOnly = false, valid = valid, expectedStatus = 200)
        return com.soundq.android.data.playlists.PlaylistJson.singleAdd(body, id, track)
    }
    fun playlistDetail(scope: AccountScope, id: com.soundq.android.data.playlists.PlaylistId, valid: () -> Boolean = { true }): com.soundq.android.data.playlists.PlaylistDetail {
        val body = authorized(scope, "/playlists/${id.value}", valid = valid)
        return com.soundq.android.data.playlists.PlaylistJson.detail(body, id)
    }
    private fun receiptImport(scope:AccountScope,kind:String,send:()->ImportAcknowledgement):ImportAcknowledgement {
        session.checkRemote(scope)
        val receipt=try {intakeReceipts.begin(session.endpoint.identity,scope.accountId,kind)} catch(_:Exception){throw SafeFailure(SafeFailure.Reason.StoreRejected)}
        try {
            val ack=send()
            intakeReceipts.finish(session.endpoint.identity,scope.accountId,receipt,"accepted",ack.id.value)
            return ack
        }catch(e:Exception){
            val reason=(e as? SafeFailure)?.reason
            runCatching {intakeReceipts.finish(session.endpoint.identity,scope.accountId,receipt,if(reason in setOf(SafeFailure.Reason.Refused,SafeFailure.Reason.Retired))"refused" else "uncertain")}
            if(e is SafeFailure)throw e
            throw SafeFailure(SafeFailure.Reason.Uncertain)
        }
    }
    fun createImport(scope: AccountScope, source: ImportSource, admit: () -> Boolean = {true}, current: () -> Boolean = {true}): ImportAcknowledgement = receiptImport(scope,"download") {
        ImportJson.acknowledgement(authorized(scope,"/downloads","POST",payload("url" to source.url,"source_type" to source.provider),readOnly=false,valid=current,expectedStatus=201,dispatchValid=admit))
    }
    fun importJob(scope: AccountScope, id: ImportJobId, current: () -> Boolean = {true}): ImportJob =
        ImportJson.job(authorized(scope,"/downloads/${id.value}",valid=current,expectedStatus=200),id)
    fun recentImports(scope: AccountScope, current: () -> Boolean = {true}): List<ImportJob> =
        ImportJson.recent(authorized(scope,"/downloads",valid=current,expectedStatus=200))
    fun resolveSource(scope:AccountScope,source:ImportSource,valid:()->Boolean):com.soundq.android.data.discovery.SourceResults {
        val body=authorized(scope,"/discovery/resolve-url","POST",payload("url" to source.url),readOnly=false,valid=valid,expectedStatus=200)
        return com.soundq.android.data.discovery.DiscoveryJson.resolved(body,source.url)
    }
    fun discoverySearch(scope: AccountScope, query:String, valid:()->Boolean = {true},grouped:Boolean=false): com.soundq.android.data.discovery.SourceResults {
        require(query.isNotBlank() && query.toByteArray(Charsets.UTF_8).size<=512)
        val url=session.endpoint.base.newBuilder().addQueryParameter("q",query).addQueryParameter("limit",com.soundq.android.data.discovery.DiscoveryJson.SEARCH_SURFACE_LIMIT.toString()).addQueryParameter("providers",if(grouped)"youtube,soundcloud,musicbrainz" else "youtube,soundcloud").build()
        return com.soundq.android.data.discovery.DiscoveryJson.search(authorized(scope,"/discovery/search?"+url.encodedQuery,valid=valid,expectedStatus=200),query)
    }
    fun createSourceDecision(scope:AccountScope,choice:com.soundq.android.data.discovery.SourceChoice,valid:()->Boolean,admit:()->Boolean,playlistId:com.soundq.android.data.playlists.PlaylistId?=null):com.soundq.android.data.discovery.SourceDecision {
        val receipt=try {intakeReceipts.begin(session.endpoint.identity,scope.accountId,"source",choice.selection.id,choice.candidate.id,playlistId=playlistId?.value)}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.StoreRejected)}
        try {
            val decision=com.soundq.android.data.discovery.DiscoveryJson.decision(authorized(scope,"/source-selections","POST",payload("sessionId" to choice.selection.id,"candidateId" to choice.candidate.id,"action" to "selected"),readOnly=false,valid=valid,expectedStatus=201,dispatchValid=admit),choice.selection.id,choice.candidate.id)
            intakeReceipts.finish(session.endpoint.identity,scope.accountId,receipt,"accepted",decisionId=decision.id)
            return decision
        }catch(e:Exception){runCatching {intakeReceipts.finish(session.endpoint.identity,scope.accountId,receipt,"uncertain")};throw e}
    }
    fun queueSourceDecision(scope:AccountScope,decision:com.soundq.android.data.discovery.SourceDecision,valid:()->Boolean,admit:()->Boolean={true}):ImportAcknowledgement {
        // Target authority belongs to the original durable source operation, never the current picker.
        val saved=try {intakeReceipts.entries(session.endpoint.identity,scope.accountId).lastOrNull {it.kind=="source"&&it.decisionId==decision.id}}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.StoreRejected)}
        val body=buildJsonObject {put("sourceDecisionId",decision.id);put("position","last");saved?.playlistId?.let {put("playlistId",it)}}
        val ack=com.soundq.android.data.discovery.DiscoveryJson.queued(authorized(scope,"/queue/items","POST",body,readOnly=false,valid=valid,acceptedStatuses=setOf(200,202),dispatchValid=admit))
        intakeReceipts.entries(session.endpoint.identity,scope.accountId).lastOrNull {it.decisionId==decision.id}?.let {r->intakeReceipts.finish(session.endpoint.identity,scope.accountId,r,"accepted",ack.id.value,decision.id)}
        return ack
    }
    fun sourceDecision(scope:AccountScope,decision:com.soundq.android.data.discovery.SourceDecision,valid:()->Boolean):com.soundq.android.data.discovery.SourceDecision =
        com.soundq.android.data.discovery.DiscoveryJson.decision(authorized(scope,"/source-selections/${decision.id}",valid=valid,expectedStatus=200),decision.sessionId,decision.candidateId,knownId=decision.id)
    fun findSourceDecision(scope:AccountScope,choice:com.soundq.android.data.discovery.SourceChoice,valid:()->Boolean):com.soundq.android.data.discovery.SourceDecision? {
        var offset=0
        repeat(100) {
            val (matches,count)=com.soundq.android.data.discovery.DiscoveryJson.decisions(authorized(scope,"/source-selections?limit=100&offset=$offset",valid=valid,expectedStatus=200),choice.selection.id,choice.candidate.id,offset)
            if(matches.size>1)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            if(matches.isNotEmpty())return matches.single()
            if(count<100)return null
            offset+=count
        }
        throw SafeFailure(SafeFailure.Reason.InvalidResponse)
    }
    fun recoverDurableSource(scope:AccountScope,receipt:com.soundq.android.data.acquisition.IntakeReceipt,valid:()->Boolean):com.soundq.android.data.discovery.SourceDecision? {
        val sessionId=receipt.sessionId ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        val candidate=receipt.candidateId ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        receipt.decisionId?.let {id->return com.soundq.android.data.discovery.DiscoveryJson.decision(authorized(scope,"/source-selections/$id",valid=valid,expectedStatus=200),sessionId,candidate,id)}
        var offset=0
        repeat(100){
            val (matches,count)=com.soundq.android.data.discovery.DiscoveryJson.decisions(authorized(scope,"/source-selections?limit=100&offset=$offset",valid=valid,expectedStatus=200),sessionId,candidate,offset)
            if(matches.size>1)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            if(matches.isNotEmpty())return matches.single()
            if(count<100)return null
            offset+=count
        }
        throw SafeFailure(SafeFailure.Reason.InvalidResponse)
    }
    fun serverImports(scope:AccountScope,valid:()->Boolean)=com.soundq.android.data.acquisition.AcquisitionJson.queue(authorized(scope,"/queue",valid=valid,expectedStatus=200))
    fun manageServerImport(scope:AccountScope,operation:String,id:String?,position:Int?,valid:()->Boolean,admit:()->Boolean):com.soundq.android.data.acquisition.ServerImportQueue {
        require(operation in setOf("retry","remove","reorder","clear"))
        require(operation=="clear" || id?.let {Regex("[A-Za-z0-9_-]{1,128}").matches(it)}==true)
        val path=when(operation){"clear"->"/queue";"reorder"->"/queue/reorder";"retry"->"/queue/items/$id/retry";else->"/queue/items/$id"}
        val method=when(operation){"retry"->"POST";"reorder"->"PUT";else->"DELETE"}
        val body=if(operation=="reorder")buildJsonObject {put("queueItemId",id!!);put("toPosition",position!!.also {require(it>=0)})} else null
        return com.soundq.android.data.acquisition.AcquisitionJson.queue(authorized(scope,path,method,body,readOnly=false,valid=valid,expectedStatus=200,dispatchValid=admit))
    }
    fun playlistImport(scope:AccountScope,id:ImportJobId,valid:()->Boolean)=com.soundq.android.data.acquisition.AcquisitionJson.playlist(authorized(scope,"/playlist-imports/${id.value}",valid=valid,expectedStatus=200),id)
    fun createPlaylistImport(scope:AccountScope,source:ImportSource,name:String,maxItems:Int,valid:()->Boolean,admit:()->Boolean,description:String=""):com.soundq.android.data.acquisition.PlaylistImportProgress {
        require(source.provider=="youtube"&&maxItems in 1..1000&&name.length<=200&&description.length<=5000)
        val body=buildJsonObject {put("url",source.url);put("maxItems",maxItems);if(name.isNotBlank())put("name",name);if(description.isNotBlank())put("description",description)}
        return com.soundq.android.data.acquisition.AcquisitionJson.playlist(authorized(scope,"/playlist-imports","POST",body,readOnly=false,valid=valid,expectedStatus=202,dispatchValid=admit))
    }
    fun research(scope:AccountScope,id:ImportJobId,valid:()->Boolean)=com.soundq.android.data.acquisition.AcquisitionJson.research(authorized(scope,"/research-jobs/${id.value}",valid=valid,expectedStatus=200),id)
    fun researchEvents(scope:AccountScope,id:ImportJobId,after:Long,valid:()->Boolean)=com.soundq.android.data.acquisition.researchEvents(authorized(scope,"/research-jobs/${id.value}/events?afterSequence=$after&limit=50",valid=valid,expectedStatus=200),id,after)
    fun startResearch(scope:AccountScope,query:String,key:String,valid:()->Boolean,admit:()->Boolean):com.soundq.android.data.acquisition.ResearchProgress {
        require(query.isNotBlank()&&query.toByteArray().size<=512);ImportJobId(key)
        val body=buildJsonObject {put("query",query);put("providers",buildJsonArray {add("youtube");add("soundcloud")});put("limit",12)}
        return com.soundq.android.data.acquisition.AcquisitionJson.research(authorized(scope,"/research-jobs","POST",body,readOnly=false,valid=valid,expectedStatus=201,headers=mapOf("Idempotency-Key" to key),dispatchValid=admit))
    }
    fun mutateResearch(scope:AccountScope,id:ImportJobId,operation:String,valid:()->Boolean,admit:()->Boolean):com.soundq.android.data.acquisition.ResearchProgress {
        require(operation in setOf("cancel","retry"))
        return com.soundq.android.data.acquisition.AcquisitionJson.research(authorized(scope,"/research-jobs/${id.value}/$operation","POST",readOnly=false,valid=valid,expectedStatus=200,emptyBody=true,dispatchValid=admit),id)
    }
    fun queueResearchReview(scope:AccountScope,decision:String,valid:()->Boolean,admit:()->Boolean):ImportAcknowledgement {
        ImportJobId(decision)
        return com.soundq.android.data.discovery.DiscoveryJson.queued(authorized(scope,"/queue/items","POST",payload("sourceDecisionId" to decision,"position" to "last"),readOnly=false,valid=valid,acceptedStatuses=setOf(200,202),dispatchValid=admit))
    }
    fun reviewResearch(scope:AccountScope,id:ImportJobId,candidate:com.soundq.android.data.discovery.SourceCandidate,action:String,key:String,reason:String,valid:()->Boolean,admit:()->Boolean):com.soundq.android.data.acquisition.ResearchReview {
        require(action in setOf("accepted","overridden"));ImportJobId(key)
        return com.soundq.android.data.acquisition.AcquisitionJson.review(authorized(scope,"/research-jobs/${id.value}/reviews","POST",payload("candidateId" to candidate.id,"action" to action,"reason" to reason),readOnly=false,valid=valid,expectedStatus=201,headers=mapOf("Idempotency-Key" to key),dispatchValid=admit),candidate,action)
    }
    fun revokeLogout(): AccountSession.Retirement = session.revoke()
    fun finishLogout(retired: AccountSession.Retirement) {
        session.clearRetired(retired)
        val access = retired.access
        if (access != null) try { wire("/auth/logout","POST",access=access,valid={session.owns(retired.intent)}) } catch (_: SafeFailure) { /* Local retirement remains authoritative. */ }
    }
    fun logout() = finishLogout(revokeLogout())
    fun library(scope:AccountScope,query:LibraryQuery,offset:Int):LibraryPage=ownedLibraryPage(scope,query,offset){true}
    internal fun ownedLibraryPage(scope: AccountScope, query: LibraryQuery, offset: Int, valid: () -> Boolean): LibraryPage = ownedLibraryPage(scope,query,offset,20,valid)
    internal fun ownedLibraryPage(scope: AccountScope, query: LibraryQuery, offset: Int, limit:Int, valid: () -> Boolean): LibraryPage {
        require(offset >= 0 && limit in 1..100)
        val url = session.endpoint.base.newBuilder().encodedPath("/api/v1/library").query(null)
            .addQueryParameter("limit",limit.toString()).addQueryParameter("offset",offset.toString())
            .addQueryParameter("sort",query.sort.wire).addQueryParameter("order",if(query.ascending) "asc" else "desc")
            .addQueryParameter("fields","id,title,artist,album,duration_ms,is_liked,cover_art_url,artwork_url,artwork_kind,analysis_status,analysis_summary")
        if(query.text.isNotBlank()) url.addQueryParameter("q",query.text.trim())
        if(query.liked) url.addQueryParameter("liked","true")
        query.verified?.let { url.addQueryParameter("mb_verified",it.toString()) }
        if(query.genre.isNotBlank()) url.addQueryParameter("genre",query.genre)
        val body = authorized(scope,"/library?"+url.build().encodedQuery,valid=valid)
        return try {
            val rows=body.getValue("tracks").jsonArray
            val scannedIds=rows.map {it.jsonObject.getValue("id").jsonPrimitive.long}
            val tracks = rows.mapNotNull { e ->
                val t=e.jsonObject
                // The continuation selector filters positive IDs. Keep ordinary browse's
                // strict typed rows and its default limit unchanged.
                if(limit==100 && t.getValue("id").jsonPrimitive.long<=0)return@mapNotNull null
                Track(TrackId(t.getValue("id").jsonPrimitive.long),t.getValue("title").jsonPrimitive.content,
                    t["artist"]?.jsonPrimitive?.contentOrNull.orEmpty(),t["album"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    t["duration_ms"]?.jsonPrimitive?.longOrNull ?: 0,t["is_liked"]?.jsonPrimitive?.booleanOrNull,
                    libraryArtworkUrl(t))
            }
            val trackIds=tracks.map {it.id}.toSet()
            val analysis=rows.mapNotNull {e->
                val row=e.jsonObject;val id=row.getValue("id").jsonPrimitive.long
                if(id<=0||TrackId(id) !in trackIds)null else libraryAnalysisFacts(row)?.let {TrackId(id) to it}
            }.toMap()
            val page = LibraryPage(tracks,body.getValue("total").jsonPrimitive.int,body.getValue("limit").jsonPrimitive.int,body.getValue("offset").jsonPrimitive.int,scannedIds,analysis)
            require(page.total>=0 && page.limit in 1..500 && page.offset==offset && rows.size<=page.limit)
            page
        } catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
    }
    /** No retry after a possibly dispatched write. The backend has no idempotency key. */
    fun recordPlay(scope:AccountScope,track:TrackId,valid:()->Boolean={true}) {
        val response=authorized(scope,"/me/plays","POST",buildJsonObject {put("trackId",track.value)},readOnly=false,valid=valid,expectedStatus=201)
        val accepted=try {response.keys==setOf("trackId","played") && response["trackId"]?.jsonPrimitive?.isString==false && response["played"]?.jsonPrimitive?.isString==false && response["trackId"]?.jsonPrimitive?.longOrNull==track.value && response["played"]?.jsonPrimitive?.booleanOrNull==true}catch(_:Exception){false}
        if(!accepted)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
    }
    fun recent(scope: AccountScope, valid: () -> Boolean = { true }): List<com.soundq.android.data.home.HomeEntry> {
        val body = authorized(scope, "/me/plays/recent?limit=20", valid = valid)
        return parseHomeRows(body)
    }
    fun top(scope: AccountScope, valid: () -> Boolean = { true }): List<com.soundq.android.data.home.HomeEntry> =
        parseHomeRows(authorized(scope, "/me/plays/top?days=30&limit=20", valid = valid))
    fun history(scope: AccountScope, offset: Int, valid: () -> Boolean = { true }): List<com.soundq.android.data.home.HistoryEntry> {
        require(offset >= 0)
        val body = authorized(scope, "/me/plays/history?limit=50&offset=$offset", valid = valid)
        return try {
            require(homeLong(body.getValue("limit")) == 50L && homeLong(body.getValue("offset")) == offset.toLong())
            val rows = body.getValue("plays").jsonArray.map { element ->
                val event = element.jsonObject
                val id = homeLong(event.getValue("id")).also { require(it > 0) }
                com.soundq.android.data.home.HistoryEntry(id, parseHomeEntry(event.getValue("track").jsonObject),
                    Instant.parse(homeString(event.getValue("playedAt"))),
                    event["contextType"]?.let { homeString(it) }, event["contextId"]?.let { homeString(it) },
                    event.getValue("skipped").jsonPrimitive.let { require(!it.isString); it.boolean })
            }
            require(rows.size <= 50 && rows.map { it.id }.distinct().size == rows.size)
            rows
        } catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
    }
    private fun parseHomeRows(body: JsonObject): List<com.soundq.android.data.home.HomeEntry> = try {
        body.getValue("tracks").jsonArray.map { parseHomeEntry(it.jsonObject) }.also { require(it.size <= 20) }
    } catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
    // Home/history Go scalars: omitted optionals default, present malformed values never coerce.
    private fun homeString(value: JsonElement): String = value.jsonPrimitive.let { require(it.isString); it.content }
    private fun homeLong(value: JsonElement): Long = value.jsonPrimitive.let { require(!it.isString); it.long }
    private fun parseHomeEntry(track: JsonObject): com.soundq.android.data.home.HomeEntry {
        val artwork = track["artworkUrl"]?.let { homeString(it) }
        val cover = track["coverArtUrl"]?.let { homeString(it) }
        return com.soundq.android.data.home.HomeEntry(
            Track(TrackId(homeLong(track.getValue("id"))), homeString(track.getValue("title")),
                track["artist"]?.let { homeString(it) }.orEmpty(), track["album"]?.let { homeString(it) }.orEmpty(),
                track["durationMs"]?.let { homeLong(it).also { value -> require(value >= 0) } } ?: 0,
                artwork = (artwork ?: cover)?.takeIf { safeMediaUrl(it) }),
            !track.containsKey("inLibrary") || (track["inLibrary"] as? JsonPrimitive)?.let { !it.isString && it.booleanOrNull == true } == true,
        )
    }
    fun like(scope: AccountScope, track: TrackId, liked: Boolean) {
        authorized(scope,"/library/tracks/${track.value}/like",if(liked) "POST" else "DELETE",readOnly=false)
    }
    fun analysisWaveform(scope:AccountScope,track:TrackId,durationMs:Long,valid:()->Boolean={true}): com.soundq.android.data.timeline.TrackWaveform =
        try {com.soundq.android.data.timeline.AnalysisWaveformJson.parse(authorized(scope,"/tracks/${track.value}/analysis",valid=valid,expectedStatus=200),track,durationMs)}
        catch(e:SafeFailure){throw e}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    fun descriptor(scope: AccountScope, track: TrackId, valid: () -> Boolean = { true }): AudioDescriptor {
        val body = authorized(scope,"/playback/urls","POST",buildJsonObject { put("trackIds",buildJsonArray { add(track.value) }); put("ttlSeconds",900) },readOnly=true,valid=valid)
        session.checkScope(scope)
        return try {
            val rows=body.getValue("urls").jsonArray.map {it.jsonObject}
            val ids=rows.map {it.getValue("trackId").jsonPrimitive.let {id -> require(!id.isString);id.long.also {value -> require(value>0)}}}
            require(ids.distinct().size==ids.size)
            val entry = rows.singleOrNull {it.getValue("trackId").jsonPrimitive.long == track.value}
                ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            fun text(key:String):String? = entry[key]?.let {value -> value.jsonPrimitive.let { require(it.isString && it.content.length<=1024 && it.content.none { c -> c.code<32 });it.content } }
            fun number(key:String):Long? = entry[key]?.let {value -> value.jsonPrimitive.let { require(!it.isString);it.long.also { n -> require(n>=0) } } }
            val url = text("url")!!
            val expires = Instant.parse(text("expiresAt")!!)
            require(safeMediaUrl(url) && expires.isAfter(Instant.now().plusSeconds(5)))
            listOf("bitrateKbps","sampleRateHz","channels").forEach {number(it)}
            AudioDescriptor(url,expires,text("contentType"),number("sizeBytes"),text("codec"),text("etag"),text("storageKeyVersion"))
        } catch(e: SafeFailure) {throw e} catch(_: Exception) {throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    }
    companion object {
        /** Go's canonical field wins. Legacy aliases cannot replace a refused canonical URL. */
        internal fun libraryArtworkUrl(row:JsonObject):String? {
            val value=(row["cover_art_url"]?.takeUnless {it is JsonNull} ?: row["artwork_url"]?.takeUnless {it is JsonNull}) as? JsonPrimitive ?: return null
            return value.takeIf {it.isString}?.content?.takeIf(::safeMediaUrl)
        }
        fun safeMediaUrl(value: String): Boolean {
            val u=value.toHttpUrlOrNull() ?: return false
            return u.scheme=="https" && u.username.isEmpty() && u.password.isEmpty() && u.fragment==null && value.none {it.isWhitespace() || it.code<32}
        }
    }
}
class AudioDescriptor(val url: String, val expires: Instant, val contentType:String?=null, val sizeBytes:Long?=null, val codec:String?=null, val etag:String?=null, val storageKeyVersion:String?=null) { override fun toString()="AudioDescriptor([redacted])" }
