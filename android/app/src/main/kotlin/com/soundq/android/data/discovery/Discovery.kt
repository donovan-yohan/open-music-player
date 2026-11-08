package com.soundq.android.data.discovery

import com.soundq.android.data.AccountScope
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.imports.ImportSource
import com.soundq.android.data.imports.ImportJobId
import java.time.Instant
import com.soundq.android.data.catalog.*

/** Closed source-only capability; no catalog, research, audio or playback authority. */
enum class SourceProvider(val wire:String,val label:String) { YouTube("youtube","YouTube"), SoundCloud("soundcloud","SoundCloud") }
class SourceCandidate internal constructor(val id:String,val provider:SourceProvider,val source:ImportSource,val title:String,val artist:String,val durationMs:Long,val downloadable:Boolean,val uploader:String="",val album:String="",val sourceId:String="",val thumbnailUrl:String?=null,val playable:Boolean=false,val explicit:Boolean?=null) {
    override fun toString()="SourceCandidate([redacted])"
}
class SourceSession internal constructor(val id:String,val expires:Instant)
enum class DiscoveryResultType(val label:String,val section:String) { Song("Song","sources"),Artist("Artist","artists"),Album("Album","albums") }
/** Catalog items are read projections, never SourceChoice or playback identities. */
class DiscoveryEntity internal constructor(val type:DiscoveryResultType,val id:String,val title:String,val subtitle:String,val artist:String="",val releaseDate:String="") {
    // Grouped MusicBrainz album search returns release groups, never editions.
    val catalogTarget:DiscoveryCatalogTarget? get()=runCatching {
        require(id!="00000000-0000-0000-0000-000000000000")
        when(type) {
            DiscoveryResultType.Artist->DiscoveryCatalogTarget.Artist(ArtistMbid(id))
            DiscoveryResultType.Album->DiscoveryCatalogTarget.Group(ReleaseGroupMbid(id))
            else->null
        }
    }.getOrNull()
}
sealed interface DiscoveryCatalogTarget {
    data class Artist(val id:ArtistMbid):DiscoveryCatalogTarget
    data class Group(val id:ReleaseGroupMbid):DiscoveryCatalogTarget
}
class DiscoveryDetails internal constructor(internal val scope:AccountScope,val entity:DiscoveryEntity,val target:DiscoveryCatalogTarget,val valid:()->Boolean)
enum class DiscoveryProvider(val wire:String,val label:String) { YouTube("youtube","YouTube"),SoundCloud("soundcloud","SoundCloud"),MusicBrainz("musicbrainz","MusicBrainz") }
class SourceResults internal constructor(val query:String,val rows:List<SourceCandidate>,val selection:SourceSession?,val providers:List<ProviderObservation>,val entities:List<DiscoveryEntity> = emptyList())
data class ProviderObservation(val provider:DiscoveryProvider,val status:String,val resultCount:Int?=null) {
    constructor(provider:SourceProvider,status:String):this(DiscoveryProvider.entries.single {it.wire==provider.wire},status)
}
class DiscoveryView internal constructor(internal val scope:AccountScope)
class DiscoverySearchRequest internal constructor(internal val view:DiscoveryView,internal val draft:DiscoveryDraft,internal val token:Any) { internal var dispatched=false }
class DiscoveryDraft internal constructor(val text:String) { override fun toString()="DiscoveryDraft([redacted])" }
class SourceChoice internal constructor(internal val scope:AccountScope,val candidate:SourceCandidate,val selection:SourceSession,internal val valid:()->Boolean) {
    internal var consumed=false
    override fun toString()="SourceChoice([redacted])"
}
class SourceDecision internal constructor(val id:String,val sessionId:String,val candidateId:String,val job:ImportJobId?)
enum class SourceImportPhase { SavingDecision, Queueing, DecisionUncertain, DecisionRefused, QueueUncertain, QueueRefused, ReadbackFailed, Accepted }
class SourceImportReceipt internal constructor(val choice:SourceChoice,val decision:SourceDecision?=null,val phase:SourceImportPhase=SourceImportPhase.SavingDecision) {
    internal fun copy(decision:SourceDecision?=this.decision,phase:SourceImportPhase=this.phase)=SourceImportReceipt(choice,decision,phase)
    override fun toString()="SourceImportReceipt([redacted])"
}
enum class DiscoveryPhase { Idle, Loading, Ready, Failed }
data class DiscoveryState(val draft:DiscoveryDraft=DiscoveryDraft(""),val phase:DiscoveryPhase=DiscoveryPhase.Idle,val results:SourceResults?=null,val inspected:SourceChoice?=null,val error:SafeFailure.Reason?=null,val expired:Boolean=false,val invalidQuery:Boolean=false,val resultType:DiscoveryResultType=DiscoveryResultType.Song,val canBack:Boolean=false,val recent:List<String> = emptyList())
