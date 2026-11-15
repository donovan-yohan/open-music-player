package com.soundq.android.data.discovery

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.time.Instant

/** Owns source reads and disposable inspection capabilities, never an intake/player. */
class DiscoveryRepository(private val session:AccountSession,private val api:SoundQApi,historyDirectory:java.io.File?=null,private val now:()->Instant={Instant.now()},private val radarAdmitted:Boolean=false) {
    private val radarMutable=MutableStateFlow(RadarState(if(radarAdmitted)RadarPhase.Idle else RadarPhase.Held))
    val radar:StateFlow<RadarState> = radarMutable
    private val radarInvalidationMutable=MutableStateFlow(0L)
    val radarInvalidation:StateFlow<Long> = radarInvalidationMutable
    private var radarRead:RadarRead?=null
    private var radarLanding:RadarLanding?=null
    private var radarVisitRead:DiscoveryView?=null
    private var radarAction:Any?=null
    private fun cancelRadar() {
        radarRead?.let { request ->
            // A retired GET cannot publish. An unfinished first landing may ask again
            // under a fresh owner; durable provider admission still belongs to the server.
            if(request.automatic&&radarVisitRead===request.view&&radarMutable.value.page==null)radarVisitRead=null
            abandonRadar(request)
        }
        radarRead=null;radarAction=null;radarMutable.value=radarMutable.value.copy(finding=false,phase=if(!radarAdmitted)RadarPhase.Held else if(radarMutable.value.phase==RadarPhase.Failed)RadarPhase.Failed else if(radarMutable.value.page!=null)RadarPhase.Ready else RadarPhase.Idle)
    }
    private val mutable=MutableStateFlow(DiscoveryState())
    val state:StateFlow<DiscoveryState> = mutable
    private var view:DiscoveryView?=null
    private var owner:AccountScope?=null
    private var read:Any?=null
    private var detailsIncarnation=Any()
    private val history=mutableListOf<DiscoveryState>()
    private val recentHistory=DiscoveryHistory(historyDirectory)
    @Synchronized fun open():DiscoveryView? {
        val scope=session.capture() ?: run {retire();return null}
        if(owner?.let(session::current)!=true)retire()
        owner=scope;read=null;detailsIncarnation=Any();cancelRadar();radarLanding=null;radarVisitRead=null
        radarMutable.value=radarMutable.value.copy(visibleCount=5)
        mutable.value=mutable.value.copy(recent=recentHistory.load(session.endpoint.identity,scope.accountId))
        mutable.value=mutable.value.copy(phase=if(mutable.value.results!=null)DiscoveryPhase.Ready else DiscoveryPhase.Idle,inspected=null)
        return DiscoveryView(scope).also {view=it}
    }
    @Synchronized fun current(candidate:DiscoveryView)=view===candidate&&session.current(candidate.scope)
    @Synchronized fun close(candidate:DiscoveryView) {if(view===candidate){view=null;read=null;detailsIncarnation=Any();cancelRadar();radarLanding=null;mutable.value=mutable.value.copy(phase=if(mutable.value.results!=null)DiscoveryPhase.Ready else DiscoveryPhase.Idle,inspected=null)}}
    @Synchronized fun retire() {view=null;owner=null;read=null;detailsIncarnation=Any();history.clear();mutable.value=DiscoveryState();radarRead=null;radarLanding=null;radarVisitRead=null;radarAction=null;radarMutable.value=RadarState(if(radarAdmitted)RadarPhase.Idle else RadarPhase.Held)}
    @Synchronized fun edit(candidate:DiscoveryView,text:String) {
        if(!current(candidate))return
        cancelRadar();read=null;detailsIncarnation=Any();mutable.value=DiscoveryState(draft=DiscoveryDraft(text),resultType=mutable.value.resultType,canBack=history.isNotEmpty(),recent=mutable.value.recent)
    }
    @Synchronized fun claimSearch(candidate:DiscoveryView,expected:DiscoveryDraft):DiscoverySearchRequest? {
        if(!current(candidate)||mutable.value.draft!==expected||mutable.value.phase==DiscoveryPhase.Loading)return null
        val q=expected.text.trim()
        if(q.isEmpty()||q.toByteArray(Charsets.UTF_8).size>512){mutable.value=mutable.value.copy(invalidQuery=true);return null}
        val token=Any();read=token;detailsIncarnation=Any()
        val recent=recentHistory.add(session.endpoint.identity,candidate.scope.accountId,q)
        mutable.value=mutable.value.copy(phase=DiscoveryPhase.Loading,results=null,inspected=null,error=null,expired=false,invalidQuery=false,recent=recent)
        return DiscoverySearchRequest(candidate,expected,token)
    }
    fun search(candidate:DiscoveryView,expected:DiscoveryDraft) {claimSearch(candidate,expected)?.let(::search)}
    fun search(request:DiscoverySearchRequest) {
        val candidate=request.view;val expected=request.draft;val token=request.token
        fun valid()=synchronized(this){current(candidate)&&read===token&&mutable.value.draft===expected}
        synchronized(this){if(!valid()||request.dispatched)return;request.dispatched=true}
        try {
            val source=com.soundq.android.data.imports.ImportSource.parse(expected.text)
            val result=if(source!=null)api.resolveSource(candidate.scope,source,::valid) else api.discoverySearch(candidate.scope,expected.text.trim(),::valid,grouped=true)
            synchronized(this){if(valid()){read=null;mutable.value=mutable.value.copy(phase=DiscoveryPhase.Ready,results=result)}}
        }catch(e:Exception){synchronized(this){if(valid()){read=null;mutable.value=mutable.value.copy(phase=DiscoveryPhase.Failed,error=(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}}}
    }
    @Synchronized fun selectType(candidate:DiscoveryView,type:DiscoveryResultType) {if(current(candidate)){if(type!=mutable.value.resultType)detailsIncarnation=Any();mutable.value=mutable.value.copy(resultType=type)}}
    @Synchronized fun clearRecent(candidate:DiscoveryView) {
        if(current(candidate))mutable.value=mutable.value.copy(recent=recentHistory.clear(session.endpoint.identity,candidate.scope.accountId))
    }
    @Synchronized fun recent(candidate:DiscoveryView,query:String):DiscoveryDraft? {
        if(!current(candidate)||query !in mutable.value.recent)return null
        edit(candidate,query);return mutable.value.draft
    }
    @Synchronized fun details(candidate:DiscoveryView,entity:DiscoveryEntity):DiscoveryDetails? {
        val results=mutable.value.results ?: return null
        if(!current(candidate)||mutable.value.phase!=DiscoveryPhase.Ready||results.entities.none {it===entity})return null
        val target=entity.catalogTarget ?: return null
        val incarnation=detailsIncarnation
        return DiscoveryDetails(candidate.scope,entity,target) {synchronized(this){current(candidate)&&detailsIncarnation===incarnation&&mutable.value.results===results}}
    }
    @Synchronized fun refine(candidate:DiscoveryView,entity:DiscoveryEntity):DiscoveryDraft? {
        if(!current(candidate)||mutable.value.results?.entities?.none {it===entity}!=false)return null
        history+=mutable.value.copy(inspected=null)
        edit(candidate,entity.title)
        return mutable.value.draft
    }
    @Synchronized fun back(candidate:DiscoveryView):Boolean {
        if(!current(candidate)||history.isEmpty())return false
        cancelRadar();read=null;detailsIncarnation=Any();mutable.value=history.removeAt(history.lastIndex).copy(inspected=null,canBack=history.isNotEmpty(),recent=mutable.value.recent);return true
    }
    @Synchronized fun showRadar(candidate:DiscoveryView,visible:()->Boolean):RadarLanding? {
        if(!radarAdmitted||!current(candidate)||!session.remoteCurrent(candidate.scope)||session.state.value !is AuthState.SignedIn||!visible())return null
        return radarLanding?.takeIf {it.view===candidate} ?: RadarLanding(candidate,visible).also {radarLanding=it}
    }
    @Synchronized fun hideRadar(landing:RadarLanding) {if(radarLanding===landing){cancelRadar();radarLanding=null}}
    private fun radarVisible(candidate:DiscoveryView)=radarLanding?.let {it.view===candidate&&it.visible()}==true&&current(candidate)&&session.remoteCurrent(candidate.scope)&&session.state.value is AuthState.SignedIn
    @Synchronized fun radarCurrent(candidate:DiscoveryView,page:RadarPage,song:RadarSong,draft:DiscoveryDraft):Boolean =
        radarAdmitted&&radarVisible(candidate)&&mutable.value.draft===draft&&draft.text.isBlank()&&radarMutable.value.page===page&&!radarMutable.value.stale&&radarMutable.value.phase==RadarPhase.Ready&&page.songs.any {it===song}
    /** Only display grows. Canonical page/song identity remains the action context. */
    @Synchronized fun moreRadar(candidate:DiscoveryView,page:RadarPage,draft:DiscoveryDraft) {
        if(page.songs.firstOrNull()?.let {radarCurrent(candidate,page,it,draft)}!=true)return
        radarMutable.value=radarMutable.value.copy(visibleCount=(radarMutable.value.visibleCount+5).coerceAtMost(page.songs.size.coerceAtMost(20)))
    }
    @Synchronized fun claimRadar(candidate:DiscoveryView,refresh:Boolean=false,automatic:Boolean=false):RadarRead? {
        if(!radarAdmitted||!radarVisible(candidate)||mutable.value.draft.text.isNotBlank()||radarRead!=null||radarAction!=null)return null
        if(automatic&&radarVisitRead===candidate)return null
        if(!automatic&&!refresh&&radarMutable.value.page!=null&&!radarMutable.value.stale)return null
        val request=RadarRead(candidate,mutable.value.draft,Any(),radarLanding!!,radarMutable.value,automatic)
        radarRead=request
        if(automatic)radarVisitRead=candidate
        radarMutable.value=radarMutable.value.copy(phase=RadarPhase.Loading,error=null)
        return request
    }
    /** Also called by Job completion when cancellation precedes coroutine entry. */
    @Synchronized fun abandonRadar(request:RadarRead) {
        if(radarRead!==request||request.dispatched)return
        radarRead=null;request.dispatched=true
        if(request.automatic&&radarVisitRead===request.view)radarVisitRead=null
        radarMutable.value=request.prior
    }
    fun loadRadar(request:RadarRead) {
        fun valid()=synchronized(this){radarVisible(request.view)&&radarLanding===request.landing&&radarRead===request&&mutable.value.draft===request.draft&&request.draft.text.isBlank()}
        synchronized(this){if(!valid()||request.dispatched)return;request.dispatched=true}
        try {val page=api.releaseRadar(request.view.scope,::valid);synchronized(this){if(valid()){radarRead=null;radarMutable.value=RadarState(RadarPhase.Ready,page)}}}
        catch(e:Exception){synchronized(this){if(valid()){radarRead=null;radarMutable.value=radarMutable.value.copy(phase=RadarPhase.Failed,error=(e as? SafeFailure)?.reason?:SafeFailure.Reason.Network,stale=radarMutable.value.page!=null)}}}
    }
    /** Unknown revisions are deliberately re-read on every explicit action. */
    @Synchronized fun claimFindSources(candidate:DiscoveryView,page:RadarPage,song:RadarSong,draft:DiscoveryDraft):RadarFind? {
        if(!radarCurrent(candidate,page,song,draft)||radarAction!=null||radarRead!=null)return null
        val token=Any();radarAction=token;radarMutable.value=radarMutable.value.copy(finding=true,error=null)
        return RadarFind(candidate,mutable.value.draft,page,song,token)
    }
    fun findSources(request:RadarFind):DiscoverySearchRequest? {
        fun valid()=synchronized(this){radarAction===request.token&&radarCurrent(request.view,request.page,request.song,request.draft)}
        synchronized(this){if(!valid()||request.dispatched)return null;request.dispatched=true}
        try {
            val owned=api.radarMembership(request.view.scope,request.song.recording,::valid)
            synchronized(this){
                if(!valid())return null
                radarAction=null;radarMutable.value=radarMutable.value.copy(finding=false)
                if(owned){libraryChanged();return null}
                history+=mutable.value.copy(inspected=null)
                edit(request.view,request.song.title+" "+request.song.artist)
                mutable.value=mutable.value.copy(resultType=DiscoveryResultType.Song)
                return claimSearch(request.view,mutable.value.draft)
            }
        }catch(e:Exception){synchronized(this){if(valid()){radarAction=null;radarMutable.value=radarMutable.value.copy(finding=false,error=(e as? SafeFailure)?.reason?:SafeFailure.Reason.Network)}};return null}
    }
    /** Actual library readback invalidates the private exclusion snapshot. */
    @Synchronized fun libraryChanged(scope:AccountScope) {
        // Both capabilities must belong to this live account incarnation, not merely an equal ID.
        if(!session.current(scope)||owner?.let(session::current)!=true)return
        libraryChanged()
    }
    @Synchronized fun libraryChanged() {
        cancelRadar()
        if(radarMutable.value.page!=null)radarMutable.value=radarMutable.value.copy(stale=true)
        // Also witness cancellation before the first page. Loading may be conflated
        // back to Idle while the same landing/effect remains mounted.
        radarInvalidationMutable.value++
    }
    /** Preview has no decision/import/player authority; even retained callbacks revalidate the choice. */
    @Synchronized fun preview(candidate:DiscoveryView,choice:SourceChoice,launch:(String)->Unit):Boolean {
        if(!current(candidate)||mutable.value.inspected!==choice||!choice.valid())return false
        val uri=runCatching {java.net.URI(choice.candidate.source.url)}.getOrNull() ?: return false
        val source=com.soundq.android.data.imports.ImportSource.parse(choice.candidate.source.url) ?: return false
        if(uri.scheme!="https"||uri.port !in setOf(-1,443)||uri.rawUserInfo!=null||source.provider!=choice.candidate.provider.wire)return false
        return runCatching {launch(choice.candidate.source.url)}.isSuccess
    }
    @Synchronized fun inspect(candidate:DiscoveryView,row:SourceCandidate):SourceChoice? {
        if(!current(candidate)||mutable.value.phase!=DiscoveryPhase.Ready)return null
        val results=mutable.value.results ?: return null
        val selection=results.selection ?: return null
        if(results.rows.none {it===row})return null
        if(!selection.expires.isAfter(now())) {mutable.value=mutable.value.copy(expired=true,inspected=null);return null}
        lateinit var choice:SourceChoice
        choice=SourceChoice(candidate.scope,row,selection) {synchronized(this){current(candidate)&&mutable.value.results===results&&mutable.value.inspected===choice&&selection.expires.isAfter(now())}}
        mutable.value=mutable.value.copy(inspected=choice,expired=false)
        return choice
    }
    @Synchronized fun reportExpired(candidate:DiscoveryView,expected:SourceChoice) {
        if(current(candidate)&&mutable.value.inspected===expected&&!expected.selection.expires.isAfter(now()))mutable.value=mutable.value.copy(inspected=null,expired=true)
    }
    @Synchronized fun dismiss(candidate:DiscoveryView,expected:SourceChoice?) {if(current(candidate)&&mutable.value.inspected===expected)mutable.value=mutable.value.copy(inspected=null)}
}
