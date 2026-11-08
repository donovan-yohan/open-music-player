package com.soundq.android.data.discovery

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.time.Instant

/** Owns source reads and disposable inspection capabilities, never an intake/player. */
class DiscoveryRepository(private val session:AccountSession,private val api:SoundQApi,historyDirectory:java.io.File?=null,private val now:()->Instant={Instant.now()}) {
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
        owner=scope;read=null;detailsIncarnation=Any()
        mutable.value=mutable.value.copy(recent=recentHistory.load(session.endpoint.identity,scope.accountId))
        mutable.value=mutable.value.copy(phase=if(mutable.value.results!=null)DiscoveryPhase.Ready else DiscoveryPhase.Idle,inspected=null)
        return DiscoveryView(scope).also {view=it}
    }
    @Synchronized fun current(candidate:DiscoveryView)=view===candidate&&session.current(candidate.scope)
    @Synchronized fun close(candidate:DiscoveryView) {if(view===candidate){view=null;read=null;detailsIncarnation=Any();mutable.value=mutable.value.copy(phase=if(mutable.value.results!=null)DiscoveryPhase.Ready else DiscoveryPhase.Idle,inspected=null)}}
    @Synchronized fun retire() {view=null;owner=null;read=null;detailsIncarnation=Any();history.clear();mutable.value=DiscoveryState()}
    @Synchronized fun edit(candidate:DiscoveryView,text:String) {
        if(!current(candidate))return
        read=null;detailsIncarnation=Any();mutable.value=DiscoveryState(draft=DiscoveryDraft(text),resultType=mutable.value.resultType,canBack=history.isNotEmpty(),recent=mutable.value.recent)
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
        read=null;detailsIncarnation=Any();mutable.value=history.removeAt(history.lastIndex).copy(inspected=null,canBack=history.isNotEmpty(),recent=mutable.value.recent);return true
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
