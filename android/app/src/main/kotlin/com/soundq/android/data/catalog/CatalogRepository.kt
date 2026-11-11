package com.soundq.android.data.catalog

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class CatalogView internal constructor(internal val scope:AccountScope)
data class CatalogState(val draft:String="",val operation:CatalogRead?=null,val albums:CatalogAlbums?=null,val search:CatalogSearch?=null,val artist:CatalogArtist?=null,val group:CatalogReleaseGroup?=null,val album:CatalogAlbum?=null,val loading:Boolean=false,val missing:Boolean=false,val error:SafeFailure.Reason?=null,val inputError:String?=null,val inspection:CatalogInspection?=null,val recoveries:List<CatalogMembershipRecovery> = emptyList(),val membershipNotice:String?=null)
sealed interface CatalogRead {
    data class Search(val query:String,val offset:Int=0):CatalogRead
    data class Releases(val query:String,val offset:Int=0):CatalogRead
    data class Artist(val id:ArtistMbid):CatalogRead
    data class Album(val id:ReleaseMbid):CatalogRead
}
class CatalogRequest internal constructor(internal val view:CatalogView,internal val read:CatalogRead)
/** Catalog owns target-bound membership, never playback or acquisition. */
class CatalogRepository(private val api:SoundQApi,private val membershipJournal:CatalogMembershipJournal=CatalogMembershipJournal()) {
    private val mutable=MutableStateFlow(CatalogState())
    val state:StateFlow<CatalogState> = mutable
    private var mounted:CatalogView?=null
    private var pending:CatalogRequest?=null
    private var resolutionPending:CatalogResolutionRequest?=null
    private val history=mutableListOf<CatalogState>()
    private var membershipPending:CatalogMembershipRequest?=null
    private var membershipNavigation=0L
    private var discoveryOrigin:com.soundq.android.data.discovery.DiscoveryDetails?=null
    @Synchronized fun open():CatalogView? {
        retire();return api.session.capture()?.takeIf(api.session::remoteCurrent)?.let {CatalogView(it).also {view->mounted=view;restoreMembership(view)}}
    }
    @Synchronized fun owns(view:CatalogView)=mounted===view && api.session.remoteCurrent(view.scope) && discoveryOrigin?.valid?.invoke()!=false
    @Synchronized fun close(view:CatalogView) {if(mounted===view)retire()}
    @Synchronized fun retire() {membershipNavigation++;mounted=null;pending=null;resolutionPending=null;membershipPending=null;discoveryOrigin=null;history.clear();mutable.value=CatalogState()}
    @Synchronized fun discover(view:CatalogView,details:com.soundq.android.data.discovery.DiscoveryDetails):Boolean {
        if(!owns(view)||!details.valid()||details.scope.owner!==view.scope.owner||details.scope.accountId!=view.scope.accountId)return false
        discoveryOrigin=details
        mutable.value=mutable.value.copy(draft=details.entity.title)
        when(val target=details.target) {
            is com.soundq.android.data.discovery.DiscoveryCatalogTarget.Artist->claim(view,CatalogRead.Artist(target.id),false)
            is com.soundq.android.data.discovery.DiscoveryCatalogTarget.Group->{
                membershipNavigation++;pending=null;resolutionPending=null
                mutable.value=mutable.value.copy(group=CatalogReleaseGroup(target.id,details.entity.title,details.entity.releaseDate.takeIf {it.isNotBlank()}))
            }
        }
        return true
    }
    @Synchronized fun discoveredRead(view:CatalogView):CatalogRequest?=pending?.takeIf {it.view===view&&owns(view)}
    @Synchronized fun groupEditions(view:CatalogView,source:CatalogState):CatalogRequest? {
        if(!owns(view)||mutable.value!==source||source.loading)return null
        val group=source.group ?: return null
        val q=group.title.trim()
        if(q.isEmpty()||q.toByteArray(Charsets.UTF_8).size>512)return null
        return claim(view,CatalogRead.Releases(q),true)
    }
    @Synchronized fun edit(view:CatalogView,text:String) {
        if(!owns(view))return
        membershipNavigation++;pending=null;resolutionPending=null;history.clear();mutable.value=CatalogState(recoveries=mutable.value.recoveries,membershipNotice=mutable.value.membershipNotice,draft=text)
    }
    private fun claim(view:CatalogView,read:CatalogRead,push:Boolean):CatalogRequest {
        membershipNavigation++
        resolutionPending=null
        mutable.value=mutable.value.copy(inspection=null)
        if(push)history.add(mutable.value.copy(loading=false,error=null,missing=false))
        mutable.value=when(read){is CatalogRead.Search->CatalogState(recoveries=mutable.value.recoveries,membershipNotice=mutable.value.membershipNotice,draft=read.query,operation=read,loading=true)
            is CatalogRead.Releases->CatalogState(recoveries=mutable.value.recoveries,membershipNotice=mutable.value.membershipNotice,draft=read.query,operation=read,loading=true)
            is CatalogRead.Artist->CatalogState(recoveries=mutable.value.recoveries,membershipNotice=mutable.value.membershipNotice,draft=mutable.value.draft,search=mutable.value.search,operation=read,loading=true)
            is CatalogRead.Album->mutable.value.copy(album=null,operation=read,loading=true,error=null,missing=false,inputError=null)}
        return CatalogRequest(view,read).also {pending=it}
    }
    @Synchronized fun search(view:CatalogView,offset:Int=0):CatalogRequest? {
        if(!owns(view))return null
        val q=mutable.value.draft.trim()
        if(q.isBlank() || q.toByteArray(Charsets.UTF_8).size>512){pending=null;mutable.value=mutable.value.copy(loading=false,inputError="Enter an artist name up to 512 UTF-8 bytes.");return null}
        if(offset!=0 && mutable.value.search?.let {it.offset+it.rows.size==offset && offset<it.total}!=true)return null
        history.clear();return claim(view,CatalogRead.Search(q,offset),false)
    }
    @Synchronized fun artist(view:CatalogView,source:CatalogState,row:CatalogArtistRow):CatalogRequest? {
        if(!owns(view)||mutable.value!==source||source.loading||source.search?.rows?.any {it===row}!=true)return null
        return claim(view,CatalogRead.Artist(row.id),true)
    }
    @Synchronized fun group(view:CatalogView,source:CatalogState,row:CatalogReleaseGroup):Boolean {
        if(!owns(view)||mutable.value!==source||source.loading||source.artist?.releases?.any {it===row}!=true)return false
        membershipNavigation++;pending=null;history.add(source);mutable.value=source.copy(group=row,album=null,error=null,missing=false);return true
    }
    @Synchronized fun releases(view:CatalogView,offset:Int=0):CatalogRequest? {
        if(!owns(view))return null
        val q=mutable.value.draft.trim()
        if(q.isBlank()||q.toByteArray(Charsets.UTF_8).size>512){pending=null;mutable.value=mutable.value.copy(loading=false,inputError="Enter an album name up to 512 UTF-8 bytes.");return null}
        if(offset!=0 && mutable.value.albums?.let {it.offset+it.rows.size==offset && offset<it.total}!=true)return null
        history.clear();return claim(view,CatalogRead.Releases(q,offset),false)
    }
    @Synchronized fun retry(view:CatalogView,source:CatalogState):CatalogRequest? {
        if(!owns(view)||mutable.value!==source||source.loading)return null
        return source.operation?.let {claim(view,it,false)}
    }
    @Synchronized fun album(view:CatalogView,source:CatalogState,row:CatalogAlbumRow):CatalogRequest? {
        if(!owns(view)||mutable.value!==source)return null
        if(source.loading || source.albums?.rows?.any {it===row}!=true)return null
        val release=row.id ?: return null
        return claim(view,CatalogRead.Album(release),true)
    }
    @Synchronized fun back(view:CatalogView):Boolean {
        if(!owns(view))return false
        membershipNavigation++
        if(mutable.value.inspection!=null){resolutionPending=null;mutable.value=mutable.value.copy(inspection=null);return true}
        pending=null
        if(history.isEmpty()){mutable.value=mutable.value.copy(loading=false);return false}
        mutable.value=history.removeAt(history.lastIndex).copy(loading=false,error=null,missing=false,recoveries=mutable.value.recoveries,membershipNotice=mutable.value.membershipNotice);return true
    }
    @Synchronized fun recording(view:CatalogView,source:CatalogState,row:CatalogRecording,index:Int):CatalogResolutionRequest? {
        if(!owns(view)||mutable.value!==source||source.loading)return null
        val album=source.album ?: return null
        if(album.tracks.getOrNull(index)!==row || row.id.value=="00000000-0000-0000-0000-000000000000")return null
        return claimResolution(view,CatalogSelection(album,row,index))
    }
    private fun claimResolution(view:CatalogView,selection:CatalogSelection):CatalogResolutionRequest {
        membershipNavigation++
        mutable.value=mutable.value.copy(inspection=CatalogInspection(selection))
        return CatalogResolutionRequest(view,selection).also {resolutionPending=it}
    }
    @Synchronized fun dismissRecording(view:CatalogView,source:CatalogInspection) {
        if(!owns(view)||mutable.value.inspection!==source)return
        membershipNavigation++;resolutionPending=null;mutable.value=mutable.value.copy(inspection=null)
    }
    @Synchronized fun retryRecording(view:CatalogView,source:CatalogInspection):CatalogResolutionRequest? {
        if(!owns(view)||mutable.value.inspection!==source||source.loading||source.result!=null)return null
        return claimResolution(view,source.selection)
    }
    @Synchronized private fun valid(request:CatalogResolutionRequest)=resolutionPending===request && owns(request.view) && mutable.value.album===request.selection.album && mutable.value.inspection?.selection===request.selection
    fun loadResolution(request:CatalogResolutionRequest) {
        try {
            if(!valid(request))return
            val result=api.catalogResolution(request.view.scope,request.selection.row.id){valid(request)}
            synchronized(this){if(valid(request))mutable.value=mutable.value.copy(inspection=CatalogInspection(request.selection,loading=false,result=result))}
        } catch(error:Exception) {
            synchronized(this){if(valid(request))mutable.value=mutable.value.copy(inspection=CatalogInspection(request.selection,loading=false,error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network,unavailable=error is CatalogResolutionUnavailable))}
        } finally {
            synchronized(this){if(resolutionPending===request){resolutionPending=null;if(!owns(request.view))retire()}}
        }
    }
    private fun restoreMembership(view:CatalogView) {
        try {mutable.value=mutable.value.copy(recoveries=membershipJournal.entries(api.session.endpoint.identity,view.scope.accountId).map(::CatalogMembershipRecovery))}
        catch(_:Exception){mutable.value=mutable.value.copy(membershipNotice="Recovery unavailable")}
    }
    private fun eligible(result:CatalogResolution?,intent:CatalogMembershipIntent?=null,owned:Boolean=false):Boolean {
        val row=result?.candidates?.singleOrNull() ?: return false
        return !result.truncated&&result.status==(if(owned)"owned" else "stored_unowned")&&row.mbVerified&&row.inLibrary==owned&&row.trackId>0&&(intent==null||(result.recording.value==intent.recording&&result.accountId==intent.account&&row.trackId==intent.track))
    }
    @Synchronized fun addRecording(view:CatalogView,source:CatalogInspection):CatalogMembershipRequest? {
        if(!owns(view)||mutable.value.inspection!==source||source.loading||source.membership!=null||!eligible(source.result)||mutable.value.membershipNotice=="Recovery unavailable")return null
        val selection=source.selection;val result=source.result!!
        if(mutable.value.recoveries.any {it.intent.recording==selection.row.id.value})return null
        val intent=try {CatalogMembershipIntent(java.util.UUID.randomUUID().toString(),api.session.endpoint.identity,view.scope.accountId,selection.row.id.value,result.candidates.single().trackId,selection.album.id.value,selection.index,selection.row.title)}catch(_:Exception){return null}
        return claimMembership(view,intent,selection,true)
    }
    @Synchronized fun checkMembership(view:CatalogView,source:CatalogMembershipRecovery,retry:Boolean=false):CatalogMembershipRequest? {
        if(!owns(view)||mutable.value.recoveries.none {it===source}||source.busy||(retry&&!source.retryEligible))return null
        return claimMembership(view,source.intent,null,retry)
    }
    private fun claimMembership(view:CatalogView,intent:CatalogMembershipIntent,selection:CatalogSelection?,write:Boolean):CatalogMembershipRequest? {
        if(membershipPending?.let {valid(it)}==true)return null
        if(intent.endpoint!=api.session.endpoint.identity||intent.account!=view.scope.accountId)return null
        return CatalogMembershipRequest(view,intent,selection,write,membershipNavigation).also {
            membershipPending=it
            mutable.value=mutable.value.copy(inspection=mutable.value.inspection?.let {s->if(s.selection===selection)s.copy(membership="Adding") else s},recoveries=mutable.value.recoveries.map {r->if(r.intent==intent)r.copy(busy=true,retryEligible=false) else if(r.busy)r.copy(busy=false) else r})
        }
    }
    @Synchronized private fun valid(request:CatalogMembershipRequest)=membershipPending===request&&request.navigation==membershipNavigation&&owns(request.view)&&(request.selection==null||mutable.value.inspection?.selection===request.selection&&mutable.value.album===request.selection.album)
    private fun membershipStatus(request:CatalogMembershipRequest,status:String,retry:Boolean=false,confirmed:Boolean=false) {
        synchronized(this) {
            if(!valid(request))return
            val i=request.intent
            val remaining=mutable.value.recoveries.filterNot {it.intent.operation==i.operation}
            mutable.value=mutable.value.copy(recoveries=if(confirmed)remaining else remaining+CatalogMembershipRecovery(i,status,retry,busy=true),membershipNotice=if(confirmed)status else mutable.value.membershipNotice,
                inspection=mutable.value.inspection?.let {s->if(s.selection===request.selection||s.selection.row.id.value==i.recording&&s.selection.album.id.value==i.edition&&s.selection.index==i.occurrence)s.copy(membership=status) else s})
        }
    }
    fun executeMembership(request:CatalogMembershipRequest) {
        synchronized(this){if(request.consumed)return;request.consumed=true}
        val i=request.intent;val scope=request.view.scope
        try {
            if(!valid(request))return
            // Journal preparation must complete before the network capability can enter.
            if(request.write) {
                membershipJournal.prepare(i)
                if(!valid(request))return
                membershipStatus(request,"Adding")
                try {api.catalogMembership(scope,RecordingMbid(i.recording),i.track,{valid(request)},{valid(request)})}
                catch(error:Exception) {
                    val status=when((error as? CatalogMembershipRefusal)?.code) {
                        CatalogMembershipRefusal.Code.NEEDS_REVIEW,CatalogMembershipRefusal.Code.TARGET_MISMATCH->"Needs review"
                        CatalogMembershipRefusal.Code.SERVICE_DISABLED,CatalogMembershipRefusal.Code.UNAVAILABLE,CatalogMembershipRefusal.Code.TARGET_UNAVAILABLE->"Unavailable"
                        else->"Unconfirmed"
                    }
                    membershipStatus(request,status);return
                }
            }
            if(!valid(request))return
            val result=api.catalogResolution(scope,RecordingMbid(i.recording)){valid(request)}
            if(!eligible(result,i,true)&&!eligible(result,i,false)){membershipStatus(request,"Needs review");return}
            val detail=api.trackDetailsSnapshot(scope,TrackId(i.track)){valid(request)}
            if(!valid(request))return
            if(eligible(result,i,true)&&detail?.track?.id?.value==i.track&&detail.verified&&detail.recording?.value==i.recording) {
                // Durable cleanup and publication share the same captured owner/operation.
                synchronized(this){if(!valid(request))return;membershipJournal.confirm(i);membershipStatus(request,if(request.write)"Added" else "In your Library",confirmed=true)}
            } else membershipStatus(request,if(eligible(result,i,false)&&detail==null)"Unconfirmed" else "Needs review",retry=!request.write&&eligible(result,i,false)&&detail==null)
        } catch(_:Exception) {
            synchronized(this) {
                if(valid(request)) {
                    val stored=runCatching {membershipJournal.entries(i.endpoint,i.account).any {it==i}}.getOrDefault(false)
                    if(stored)membershipStatus(request,"Unconfirmed")
                    else mutable.value=mutable.value.copy(membershipNotice="Recovery unavailable",inspection=mutable.value.inspection?.copy(membership="Unavailable"))
                }
            }
        } finally {
            synchronized(this){if(membershipPending===request){membershipPending=null
                if(!owns(request.view)){if(mounted===request.view)retire()}
                else mutable.value=mutable.value.copy(recoveries=mutable.value.recoveries.map {if(it.intent==i)it.copy(busy=false,status=if(it.status=="Adding")"Unconfirmed" else it.status) else it})
            }}
        }
    }
    @Synchronized private fun valid(request:CatalogRequest)=pending===request && owns(request.view)
    fun load(request:CatalogRequest) {
        try {
            if(!valid(request))return
            val value=when(val read=request.read) {
                is CatalogRead.Search->api.catalogSearch(request.view.scope,read.query,read.offset){valid(request)}
                is CatalogRead.Releases->api.catalogReleases(request.view.scope,read.query,read.offset){valid(request)}
                is CatalogRead.Artist->api.catalogArtist(request.view.scope,read.id){valid(request)}
                is CatalogRead.Album->api.catalogAlbum(request.view.scope,read.id){valid(request)}
            }
            synchronized(this) {if(valid(request))mutable.value=when(value) {
                is CatalogSearch->mutable.value.copy(search=value,loading=false)
                is CatalogAlbums->mutable.value.copy(albums=value,loading=false)
                is CatalogArtist->mutable.value.copy(artist=value,loading=false)
                is CatalogAlbum->mutable.value.copy(album=value,loading=false)
                else->error("Unsupported catalog reply")
            }}
        } catch(_:CatalogMissing) {
            synchronized(this){if(valid(request))mutable.value=mutable.value.copy(loading=false,missing=true)}
        } catch(error:Exception) {
            synchronized(this){if(valid(request))mutable.value=mutable.value.copy(loading=false,error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}
        } finally {
            synchronized(this){if(pending===request){pending=null;if(!owns(request.view))retire() else if(mutable.value.loading)mutable.value=mutable.value.copy(loading=false)}}
        }
    }
}
class CatalogMissing:Exception()
class CatalogResolutionUnavailable:Exception()
class CatalogResolutionRequest internal constructor(internal val view:CatalogView,internal val selection:CatalogSelection)
