package com.soundq.android.data.discovery

import com.soundq.android.data.SafeFailure
import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.RecordingMbid
import kotlinx.serialization.json.*
import java.time.*

class RadarDate internal constructor(val raw:String,val precision:String,internal val start:LocalDate,internal val end:LocalDate)
class RadarSong internal constructor(val recording:RecordingMbid,val title:String,val artist:String,val creditedSeeds:List<ArtistMbid>,val firstRelease:RadarDate)
class RadarCoverage internal constructor(val partial:Boolean,val reasons:List<String>,val providerStatus:String,val serverEvents:Int?,val seedsAvailable:Int?,val seedsSelected:Int,val unresolvedSeedTracks:Int?,val unlinkedLibraryTracks:Int?,val pagesFetched:Int,val knownTotal:Int?,val retrieved:Int,val deduped:Int,val dateRejected:Int,val identityRejected:Int,val ownedExcluded:Int?,val returned:Int)
class RadarPage internal constructor(val songs:List<RadarSong>,val coverage:RadarCoverage,val generatedAt:Instant,val selectedArtists:List<ArtistMbid>)
enum class RadarPhase { Held,Idle,Loading,Ready,Failed }
data class RadarState(val phase:RadarPhase=RadarPhase.Held,val page:RadarPage?=null,val error:SafeFailure.Reason?=null,val stale:Boolean=false,val finding:Boolean=false,val visibleCount:Int=5)
/** Revoked on route/background loss. A resumed successor never revives an old read. */
class RadarLanding internal constructor(internal val view:DiscoveryView,internal val visible:()->Boolean)
class RadarRead internal constructor(internal val view:DiscoveryView,internal val draft:DiscoveryDraft,internal val token:Any,internal val landing:RadarLanding,internal val prior:RadarState,internal val automatic:Boolean){internal var dispatched=false}
class RadarFind internal constructor(internal val view:DiscoveryView,internal val draft:DiscoveryDraft,internal val page:RadarPage,internal val song:RadarSong,internal val token:Any){internal var dispatched=false}

fun radarEmptyMessage(coverage:RadarCoverage):String=when {
 coverage.serverEvents==0->"No server listening history yet"
 coverage.seedsSelected==0&&coverage.serverEvents!=null&&coverage.serverEvents>0->"No identified listened-to artists yet"
 coverage.partial->"No releases found in this search"
 else->"No new releases found"
}

/** Strict Go wire projection. Metadata only, never playback/source capabilities. */
object RadarJson {
 private fun string(e:JsonElement)=e.jsonPrimitive.let {require(it.isString);it.content}
 private fun text(o:JsonObject,k:String)=string(o.getValue(k))
 private fun number(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(!it.isString);it.int.also {n->require(n>=0)}}
 private fun optional(o:JsonObject,k:String)=o.getValue(k).takeUnless {it==JsonNull}?.let {number(o,k)}
 private fun bool(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.let {require(!it.isString);it.boolean}
 private fun id(raw:String):String {RecordingMbid(raw);require(raw!="00000000-0000-0000-0000-000000000000");return raw}
 private fun display(raw:String)=raw.also {require(it.isNotBlank()&&it.toByteArray(Charsets.UTF_8).size<=240&&it.none {c->Character.isISOControl(c)})}
 private inline fun <T> parse(block:()->T):T=try{block()}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
 fun page(o:JsonObject):RadarPage=parse {
  require(o.toString().toByteArray(Charsets.UTF_8).size<=262144)
  require(text(o,"policyVersion")=="recording-radar-v1"&&text(o,"calendarZone")=="UTC")
  val generated=Instant.parse(text(o,"generatedAt"));val today=generated.atZone(ZoneOffset.UTC).toLocalDate()
  val w=o.getValue("effectiveWindows").jsonObject
  require(number(w,"listenDays")==90&&number(w,"releaseDays")==90)
  require(Instant.parse(text(w,"listenSince"))==generated.minusSeconds(90L*86400))
  val since=LocalDate.parse(text(w,"releaseSince"));require(since==today.minusDays(90)&&LocalDate.parse(text(w,"through"))==today)
  val b=o.getValue("effectiveBounds").jsonObject
  mapOf("seeds" to 5,"pages" to 2,"pageSize" to 100,"rawCandidates" to 200,"items" to 20,"deadlineSeconds" to 15,"providerPageBytes" to 1048576,"responseBytes" to 262144,"retriesPerPage" to 1).forEach {(k,v)->require(number(b,k)==v)}
  val selected=o.getValue("selectedArtistMbids").jsonArray.map {ArtistMbid(id(string(it)))}
  require(selected.size<=5&&selected.distinct().size==selected.size)
  val songs=o.getValue("items").jsonArray.map {e->val row=e.jsonObject
   require(row.keys.none {it in setOf("trackId","url","sourceUrl","selectionSessionId","playable")})
   val recording=RecordingMbid(id(text(row,"recordingMbid")))
   val seeds=row.getValue("creditedSeedArtistMbids").jsonArray.map {ArtistMbid(id(string(it)))}
   require(seeds.isNotEmpty()&&seeds.size<=5&&seeds.distinct().size==seeds.size&&seeds.all {it in selected})
   val date=row.getValue("firstRelease").jsonObject;val raw=text(date,"raw");val precision=text(date,"precision")
   val start:LocalDate;val end:LocalDate
   when(precision){
    "day"->{require(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}").matches(raw));start=LocalDate.parse(raw);end=start}
    "month"->{require(Regex("[0-9]{4}-[0-9]{2}").matches(raw));val month=YearMonth.parse(raw);start=month.atDay(1);end=month.atEndOfMonth()}
    "year"->{require(Regex("[0-9]{4}").matches(raw));val year=Year.parse(raw);start=year.atDay(1);end=year.atMonth(12).atEndOfMonth()}
    else->error("precision")
   }
   require(start.year>=1&&!start.isBefore(since)&&!end.isAfter(today)&&(precision=="day"||end.isBefore(today)))
   RadarSong(recording,display(text(row,"title")),display(text(row,"artist")),seeds,RadarDate(raw,precision,start,end))
  }
  require(songs.size<=20&&songs.map {it.recording}.distinct().size==songs.size)
  require(songs.zipWithNext().all {(a,b)->a.firstRelease.start>b.firstRelease.start||a.firstRelease.start==b.firstRelease.start&&a.recording.value<b.recording.value})
  val c=o.getValue("coverage").jsonObject
  require(text(c,"identityScope")=="identified_server_library"&&text(c,"deviceLocalCoverage")=="unresolved")
  val reasons=c.getValue("reasons").jsonArray.map(::string)
  require(reasons.size<=12&&reasons.distinct().size==reasons.size&&reasons.all {it in setOf("seeds_unavailable","seed_limit","catalog_budget","timeout","provider_unavailable","date_omissions","identity_unresolved","identity_omissions","result_limit","membership_unavailable")})
  val partial=bool(c,"partial");require(partial==reasons.isNotEmpty())
  val status=text(c,"providerStatus");require(status in setOf("ok","not_requested","unavailable","timeout"))
  val available=optional(c,"seedsAvailable");val events=optional(c,"serverEvents");val unresolved=optional(c,"unresolvedSeedTracks");val unlinked=optional(c,"unlinkedLibraryTracks")
  val count=number(c,"seedsSelected");val pages=number(c,"pagesFetched");val total=optional(c,"knownTotal");val raw=number(c,"retrieved");val deduped=number(c,"deduped");val rejected=number(c,"dateRejected");val identity=number(c,"identityRejected");val owned=optional(c,"ownedExcluded");val returned=number(c,"returned")
  require(count==selected.size&&count<=5&&(available==null||count<=available)&&pages<=2&&raw<=200&&raw<=pages*100&&deduped<=raw&&rejected<=deduped&&identity<=raw&&(owned==null||owned<=deduped)&&returned==songs.size)
  if(songs.isNotEmpty())require(owned!=null)
  if("membership_unavailable" in reasons||"seeds_unavailable" in reasons)require(songs.isEmpty())
  if(status!="ok")require(partial||status=="not_requested")
  RadarPage(songs,RadarCoverage(partial,reasons,status,events,available,count,unresolved,unlinked,pages,total,raw,deduped,rejected,identity,owned,returned),generated,selected)
 }
 fun membership(o:JsonObject,recording:RecordingMbid):Boolean=parse {require(text(o,"recordingMbid")==recording.value);bool(o,"inLibrary")}
}
