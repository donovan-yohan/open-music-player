package com.soundq.android.data.discovery

import com.soundq.android.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Instant

/** Owns source reads and disposable inspection capabilities, never an intake/player. */
class DiscoveryRepository(private val session:AccountSession,private val api:SoundQApi,historyDirectory:java.io.File?=null,private val now:()->Instant={Instant.now()},private val radarAdmitted:Boolean=false,private val unifiedSearch:Boolean=false) {
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
            if(radarVisitRead===request.view&&radarMutable.value.page==null)radarVisitRead=null
            abandonRadar(request)
        }
        radarRead=null;radarAction=null;radarMutable.value=radarMutable.value.copy(finding=false,phase=if(!radarAdmitted)RadarPhase.Held else if(radarMutable.value.phase==RadarPhase.Failed)RadarPhase.Failed else if(radarMutable.value.page!=null)RadarPhase.Ready else RadarPhase.Idle)
    }
    private val defaultType=if(unifiedSearch)DiscoveryResultType.All else DiscoveryResultType.Song
    private val catalogTypes=listOf(DiscoveryResultType.Artist,DiscoveryResultType.Album)
    private val mutable=MutableStateFlow(DiscoveryState(resultType=defaultType))
    val state:StateFlow<DiscoveryState> = mutable
    private var view:DiscoveryView?=null
    private var owner:AccountScope?=null
    // A unified draft owns one admission with four peer reads, or one URL resolution.
    // Legacy source/grouped callers can still exercise their explicit wire contract.
    private data class SearchLane(
        val request:DiscoverySearchRequest?=null,
        val phase:DiscoveryPhase=DiscoveryPhase.Idle,
        val results:DiscoveryResults?=null,
        val error:SafeFailure.Reason?=null,
        val pendingProviders:Boolean=false,
        val providerFailure:SafeFailure.Reason?=null,
        val catalog:Map<DiscoveryResultType,DiscoveryCatalogStatus> = emptyMap(),
        val catalogOffsets:Map<DiscoveryResultType,Int> = emptyMap(),
        val catalogRetries:Map<DiscoveryResultType,DiscoverySearchRequest> = emptyMap()
    ) {
        val active get()=request!=null||catalogRetries.isNotEmpty()
        fun cancelReads() {request?.calls?.cancel();catalogRetries.values.forEach {it.calls.cancel()}}
        fun hasPrimaryCatalogWork(statuses:Map<DiscoveryResultType,DiscoveryCatalogStatus> = catalog)=
            statuses.any {(type,status)->status==DiscoveryCatalogStatus.Loading&&type !in catalogRetries}
        fun afterCancellation(keepRetries:Boolean=false):SearchLane {
            if(catalog.isEmpty())return if(phase==DiscoveryPhase.Ready)copy(request=null,pendingProviders=false) else SearchLane()
            if(!active)return this
            val retainedRetries=if(keepRetries)catalogRetries else emptyMap()
            if(results==null&&retainedRetries.isEmpty())return SearchLane()
            val sourceAvailable=results?.providers?.any {it.status=="ok"}==true
            return copy(request=null,phase=if(sourceAvailable)DiscoveryPhase.Ready else DiscoveryPhase.Failed,
                error=if(sourceAvailable)null else SafeFailure.Reason.ServiceUnavailable,pendingProviders=false,
                catalog=catalog.mapValues {(type,status)->if(status==DiscoveryCatalogStatus.Loading&&type !in retainedRetries)DiscoveryCatalogStatus.Unavailable() else status},
                catalogRetries=retainedRetries)
        }
    }
    private class PriorSearch(val state:DiscoveryState,val lanes:Map<SearchFamily,SearchLane>)
    private val lanes=mutableMapOf<SearchFamily,SearchLane>()
    private var detailsIncarnation=Any()
    private val history=mutableListOf<PriorSearch>()
    private val recentHistory=DiscoveryHistory(historyDirectory)
    private fun selected(state:DiscoveryState=mutable.value)=state.draft.family(state.resultType,unifiedSearch)
    private fun project(state:DiscoveryState=mutable.value) {
        val lane=lanes[selected(state)] ?: SearchLane()
        val next=state.copy(phase=lane.phase,results=lane.results,error=lane.error,pendingProviders=lane.pendingProviders,catalog=lane.catalog,searchActive=lane.active)
        mutable.value=if(lane.catalog.isEmpty()||state.resultType==DiscoveryResultType.Song)next else {
            val all=state.resultType==DiscoveryResultType.All
            val families=if(all)lane.catalog.values else listOfNotNull(lane.catalog[state.resultType])
            val pending=families.any {it==DiscoveryCatalogStatus.Loading}||all&&lane.pendingProviders
            val available=families.any {it is DiscoveryCatalogStatus.Ready||it is DiscoveryCatalogStatus.Legacy}||all&&lane.phase==DiscoveryPhase.Ready
            val phase=when {
                next.items.isNotEmpty()->DiscoveryPhase.Ready
                pending->DiscoveryPhase.Loading
                available->DiscoveryPhase.Ready
                else->DiscoveryPhase.Failed
            }
            next.copy(phase=phase,error=if(phase==DiscoveryPhase.Failed)SafeFailure.Reason.ServiceUnavailable else null,pendingProviders=pending)
        }
    }
    private fun put(family:SearchFamily,lane:SearchLane) {
        lanes[family]=lane
        if(family==selected())project()
    }
    private fun cancelSearches() {lanes.values.forEach {it.cancelReads()};lanes.clear()}
    private fun suspendSearches() {
        val retained=lanes.mapValues {(_,lane)->lane.afterCancellation()}.filterValues {it.phase!=DiscoveryPhase.Idle}
        cancelSearches();lanes.putAll(retained)
        project(mutable.value.copy(inspected=null))
    }
    @Synchronized fun open():DiscoveryView? {
        val scope=session.capture() ?: run {retire();return null}
        if(owner?.let(session::discoveryCurrent)!=true)retire()
        owner=scope;detailsIncarnation=Any();cancelRadar();radarLanding=null;radarVisitRead=null
        radarMutable.value=radarMutable.value.copy(visibleCount=5)
        suspendSearches()
        mutable.value=mutable.value.copy(recent=recentHistory.load(session.endpoint.identity,scope.accountId))
        return DiscoveryView(scope).also {view=it}
    }
    @Synchronized fun current(candidate:DiscoveryView)=view===candidate&&session.discoveryCurrent(candidate.scope)
    @Synchronized fun close(candidate:DiscoveryView) {if(view===candidate){view=null;detailsIncarnation=Any();cancelRadar();radarLanding=null;suspendSearches()}}
    @Synchronized fun retire() {view=null;owner=null;cancelSearches();detailsIncarnation=Any();history.clear();mutable.value=DiscoveryState(resultType=defaultType);radarRead=null;radarLanding=null;radarVisitRead=null;radarAction=null;radarMutable.value=RadarState(if(radarAdmitted)RadarPhase.Idle else RadarPhase.Held)}
    private fun ownsSearch(request:DiscoverySearchRequest)=
        view===request.view&&mutable.value.draft===request.draft&&lanes[request.family]?.let {lane->
            val retry=request.catalogRetry
            (if(retry==null)lane.request else lane.catalogRetries[retry])===request
        }==true
    @Synchronized internal fun abandonSearch(request:DiscoverySearchRequest) {
        if(!ownsSearch(request))return
        request.calls.cancel()
        val lane=lanes.getValue(request.family)
        val retry=request.catalogRetry
        if(retry!=null) {
            put(request.family,lane.copy(catalog=lane.catalog+(retry to DiscoveryCatalogStatus.Unavailable()),catalogRetries=lane.catalogRetries-retry))
            return
        }
        val retained=lane.afterCancellation(keepRetries=true)
        if(request.family==selected()) {
            lanes[request.family]=retained
            project(mutable.value.copy(inspected=null))
        } else lanes[request.family]=retained
    }
    @Synchronized fun edit(candidate:DiscoveryView,text:String) {
        if(!current(candidate))return
        if(unifiedSearch&&mutable.value.draft.text==text)return
        cancelRadar();cancelSearches();detailsIncarnation=Any();mutable.value=DiscoveryState(draft=DiscoveryDraft(text),resultType=if(unifiedSearch)defaultType else mutable.value.resultType,canBack=history.isNotEmpty(),recent=mutable.value.recent)
    }
    @Synchronized fun claimSearch(candidate:DiscoveryView,expected:DiscoveryDraft,retry:Boolean=false):DiscoverySearchRequest? {
        val state=mutable.value
        if(!current(candidate)||state.draft!==expected)return null
        val unavailable=state.catalog[state.resultType] as? DiscoveryCatalogStatus.Unavailable
        if(retry&&unavailable!=null)return claimCatalogRetry(candidate,expected,state.resultType,unavailable)
        if(state.phase==DiscoveryPhase.Loading||unifiedSearch&&lanes[selected()]?.let {it.active||!retry&&it.phase!=DiscoveryPhase.Idle}==true)return null
        val q=expected.text.trim()
        if(q.isEmpty()||q.toByteArray(Charsets.UTF_8).size>512){mutable.value=mutable.value.copy(invalidQuery=true);return null}
        val recent=recentHistory.add(session.endpoint.identity,candidate.scope.accountId,q)
        return startSearch(candidate,state.copy(recent=recent))
    }
    private fun startSearch(candidate:DiscoveryView,state:DiscoveryState):DiscoverySearchRequest {
        val family=selected(state)
        val request=DiscoverySearchRequest(candidate,state.draft,family)
        lanes[family]?.cancelReads()
        lanes[family]=SearchLane(request,DiscoveryPhase.Loading,pendingProviders=family==SearchFamily.Song||family==SearchFamily.Unified,
            catalog=if(family==SearchFamily.Unified)catalogTypes.associateWith {DiscoveryCatalogStatus.Loading} else emptyMap())
        detailsIncarnation=Any()
        project(state.copy(inspected=null,expired=false,invalidQuery=false))
        return request
    }
    suspend fun search(candidate:DiscoveryView,expected:DiscoveryDraft) {claimSearch(candidate,expected)?.let {search(it)}}
    @Synchronized internal fun claimCatalogRetry(candidate:DiscoveryView,draft:DiscoveryDraft,type:DiscoveryResultType,expected:DiscoveryCatalogStatus.Unavailable):DiscoverySearchRequest? {
        val state=mutable.value
        if(!unifiedSearch||!current(candidate)||state.draft!==draft||type.catalogKind==null||
            state.resultType!=DiscoveryResultType.All&&state.resultType!=type)return null
        val lane=lanes[SearchFamily.Unified] ?: return null
        if(lane.catalog[type]!==expected)return null
        val request=DiscoverySearchRequest(candidate,draft,SearchFamily.Unified,type)
        // Only this unavailable family gets new work. Keep the accepted query and action incarnation.
        put(SearchFamily.Unified,lane.copy(catalog=lane.catalog+(type to DiscoveryCatalogStatus.Loading),catalogRetries=lane.catalogRetries+(type to request)))
        return request
    }
    @Synchronized fun claimCatalogContinuation(candidate:DiscoveryView,draft:DiscoveryDraft,type:DiscoveryResultType,expected:DiscoveryCatalogStatus.Ready):DiscoverySearchRequest? {
        val state=mutable.value
        if(!unifiedSearch||!current(candidate)||state.draft!==draft||state.resultType!=type||!expected.hasMore||type.catalogKind==null)return null
        val lane=lanes[SearchFamily.Unified] ?: return null
        if(lane.active||lane.catalog[type]!==expected)return null
        val offset=lane.catalogOffsets[type]?.takeIf {it in 1..1000} ?: return null
        val request=DiscoverySearchRequest(candidate,draft,SearchFamily.Unified,type,offset)
        put(SearchFamily.Unified,lane.copy(request=request))
        return request
    }
    suspend fun search(request:DiscoverySearchRequest) {
        val job=currentCoroutineContext()[Job]!!
        val candidate=request.view;val scope=candidate.scope
        // Route/request custody does not depend on a bearer being momentarily
        // withdrawn. The API independently guards actual network admission.
        fun valid()=synchronized(this){job.isActive&&ownsSearch(request)}
        synchronized(this){
            if(!ownsSearch(request)||request.dispatched)return
            if(!job.isActive){abandonSearch(request);return}
            request.dispatched=true
        }
        try {
            val query=request.draft.text.trim()
            fun emptyResults()=if(request.family==SearchFamily.Unified)DiscoveryResults.unified(query) else DiscoveryResults(emptyList(),query=query)
            when(request.family) {
                SearchFamily.Link,SearchFamily.Grouped -> {
                    val response=searchResult {
                        searchCall(request) {
                            val source=request.draft.source
                            if(source!=null)api.resolveSource(scope,source,calls=request.calls,valid=::valid)
                            else api.discoverySearch(scope,query,::valid,grouped=true,calls=request.calls)
                        }
                    }
                    settleSearch(request,job,response) {
                        response.fold(
                            onSuccess={SearchLane(phase=DiscoveryPhase.Ready,results=DiscoveryResults(listOf(it)))},
                            onFailure={SearchLane(phase=DiscoveryPhase.Failed,error=searchFailure(it))}
                        )
                    }
                }
                SearchFamily.Song,SearchFamily.Unified -> coroutineScope {
                    // Share the grouped metadata read only within this exact request. No
                    // capability cache, duplicate source search, or fallback on a transient failure.
                    val legacyLock=Mutex()
                    var legacyRead:Result<SourceResults>?=null
                    suspend fun legacyCatalog()=legacyLock.withLock {
                        legacyRead ?: searchResult {
                            searchCall(request) {api.legacyDiscoveryCatalog(scope,query,request.calls,::valid)}
                        }.also {legacyRead=it}
                    }
                    if(request.catalogOnly==null)for(provider in SourceProvider.entries)launch(Dispatchers.IO) {
                        val worker=currentCoroutineContext()[Job]!!
                        val response=searchResult {
                            searchCall(request) {api.discoverySearch(scope,query,::valid,provider=provider,calls=request.calls)}
                        }
                        settleSearch(request,worker,response) {lane->
                            val previous=lane.results
                            val received=response.getOrNull()
                            val duplicateSession=received?.selection?.id?.let {id->previous?.batches?.any {it.selection?.id==id}}==true
                            val batch=if(received!=null&&!duplicateSession)received else
                                SourceResults(query,emptyList(),null,listOf(ProviderObservation(provider,"failed")))
                            val results=(previous ?: emptyResults()).append(batch)
                            val pending=results.batches.size<SourceProvider.entries.size
                            val unavailable=!pending&&results.providers.none {it.status=="ok"}
                            val failure=lane.providerFailure ?: response.exceptionOrNull()?.let(::searchFailure)
                                ?: if(duplicateSession)SafeFailure.Reason.InvalidResponse else null
                            lane.copy(request=if(pending||lane.hasPrimaryCatalogWork())request else null,phase=when {
                                unavailable->DiscoveryPhase.Failed
                                !pending||results.rows.isNotEmpty()->DiscoveryPhase.Ready
                                else->DiscoveryPhase.Loading
                            },results=results,error=if(unavailable)failure ?: SafeFailure.Reason.ServiceUnavailable else null,
                                pendingProviders=pending,providerFailure=failure)
                        }
                    }
                    if(request.family==SearchFamily.Unified)for(type in request.catalogOnly?.let(::listOf) ?: catalogTypes)launch(Dispatchers.IO) {
                        val worker=currentCoroutineContext()[Job]!!
                        val offset=request.catalogOffset
                        val response=searchResult {searchCall(request) {api.discoveryCatalog(scope,query,type,request.calls,::valid,offset)}}
                        val legacy=if(offset==0&&response.exceptionOrNull() is DiscoveryCatalogRouteMissing)legacyCatalog().getOrNull() else null
                        val legacyRows=legacy?.entities.orEmpty().filter {it.type==type}.distinctBy {it.id}
                        val legacyOk=legacy?.providers?.single()?.status=="ok"
                        settleSearch(request,worker) {lane->
                            val page=response.getOrNull()
                            val next=offset+(page?.rows?.size ?: 0)
                            val status=when {
                                page!=null->DiscoveryCatalogStatus.Ready(page.hasMore&&next in 1..1000)
                                offset>0->DiscoveryCatalogStatus.Ready(hasMore=true,continuationFailed=true)
                                legacyOk||legacyRows.isNotEmpty()->DiscoveryCatalogStatus.Legacy(partial=!legacyOk)
                                else->DiscoveryCatalogStatus.Unavailable()
                            }
                            val catalog=lane.catalog+(type to status)
                            val results=when {
                                page!=null&&offset>0->lane.results?.continueCatalog(page)
                                page!=null||legacyOk||legacyRows.isNotEmpty()->(lane.results ?: emptyResults()).appendCatalog(page?.rows ?: legacyRows)
                                else->lane.results
                            }
                            val retry=request.catalogRetry
                            val primary=when {
                                retry!=null->lane.request
                                lane.pendingProviders||lane.hasPrimaryCatalogWork(catalog)->request
                                else->null
                            }
                            lane.copy(request=primary,results=results,catalog=catalog,
                                catalogOffsets=if(page==null)lane.catalogOffsets else lane.catalogOffsets+(type to next),
                                catalogRetries=if(retry==null)lane.catalogRetries else lane.catalogRetries-retry)
                        }
                    }
                }
            }
        } finally {abandonSearch(request)}
    }
    private inline fun <T> searchResult(load:()->T):Result<T> = try {Result.success(load())}
        catch(e:CancellationException){throw e}
        catch(e:Exception){Result.failure(e)}
    private fun searchFailure(error:Throwable)=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network

    private fun settleSearch(request:DiscoverySearchRequest,job:Job,response:Result<SourceResults>?=null,prepare:(SearchLane)->SearchLane) {
        val scope=request.view.scope
        job.ensureActive()
        if(response!=null)request.beforePublication?.invoke(response)
        while(true) {
            val saving=synchronized(this) {
                job.ensureActive()
                if(!ownsSearch(request))return
                // Preparation is local: even a hidden lane can later be projected or saved by Back.
                val lane=prepare(lanes.getValue(request.family))
                val account=synchronized(session) {
                    // Repository -> session. Order the lane AND its visible projection
                    // against revocation and bearer withdrawal, not just the scope read.
                    val authority=session.discoveryReadState(scope)
                    job.ensureActive()
                    if(authority==DiscoveryReadState.Current) {
                        // DiscoverScreen's lifecycle collector only writes Compose state;
                        // actions/effects don't run in the StateFlow setter.
                        put(request.family,lane)
                        return
                    }
                    authority
                }
                // A resolve POST cannot borrow GET custody. Call cancellation and
                // retirement feedback stay outside the account monitor.
                if(account !is DiscoveryReadState.Saving||request.family==SearchFamily.Link) {
                    failRetiredSearch(request,job)
                    return
                }
                account.completion
            }
            // Never wait for secure persistence under either monitor.
            if(!saving.get()) {
                synchronized(this) {
                    if(ownsSearch(request))failRetiredSearch(request,job)
                }
                return
            }
        }
    }
    private fun failRetiredSearch(request:DiscoverySearchRequest,job:Job) {
        job.ensureActive()
        lanes.getValue(request.family).cancelReads()
        job.ensureActive()
        lanes[request.family]=SearchLane(phase=DiscoveryPhase.Failed,error=SafeFailure.Reason.Retired)
        if(request.family==selected())project(mutable.value.copy(inspected=null,expired=false))
    }
    // Blocking wire/refresh code stays on IO; cancellation closes the registered Call rather than
    // merely discarding its reply. An already-entered auth rotation keeps its existing custody.
    private suspend fun <T> searchCall(request:DiscoverySearchRequest,load:()->T):T = suspendCancellableCoroutine {continuation->
        continuation.invokeOnCancellation {request.calls.cancel()}
        if(continuation.isActive)continuation.resumeWith(runCatching(load))
    }
    @Synchronized fun selectType(candidate:DiscoveryView,type:DiscoveryResultType):DiscoverySearchRequest? {
        if(!current(candidate)||type==mutable.value.resultType||unifiedSearch&&mutable.value.draft.source!=null)return null
        val next=mutable.value.copy(resultType=type,inspected=null,expired=false)
        detailsIncarnation=Any()
        // A tab change neither re-records the query nor replaces another lane's work.
        if(!unifiedSearch&&lanes.isNotEmpty()&&selected(next) !in lanes)return startSearch(candidate,next)
        project(next)
        return null
    }
    @Synchronized fun clearRecent(candidate:DiscoveryView) {
        if(current(candidate))mutable.value=mutable.value.copy(recent=recentHistory.clear(session.endpoint.identity,candidate.scope.accountId))
    }
    @Synchronized fun recent(candidate:DiscoveryView,query:String):DiscoveryDraft? {
        if(!current(candidate)||query !in mutable.value.recent)return null
        edit(candidate,query);return mutable.value.draft
    }
    @Synchronized fun details(candidate:DiscoveryView,entity:DiscoveryEntity):DiscoveryDetails? {
        val results=mutable.value.results ?: return null
        if(!current(candidate)||mutable.value.phase!=DiscoveryPhase.Ready||!visibleEntity(entity))return null
        val target=entity.catalogTarget ?: return null
        val incarnation=detailsIncarnation
        // Preserve entered browse reads during an in-flight bearer save, without granting
        // new wire dispatch or making a failed save/replacement the same account lifetime.
        return DiscoveryDetails(candidate.scope,entity,target) {synchronized(this){
            (if(unifiedSearch)view===candidate&&session.discoveryReadState(candidate.scope)!=DiscoveryReadState.Retired else current(candidate))&&detailsIncarnation===incarnation&&
            (if(unifiedSearch)mutable.value.results?.identity===results.identity&&visibleEntity(entity) else mutable.value.results===results)}}
    }
    private fun visibleEntity(entity:DiscoveryEntity)=mutable.value.let {state->
        (!unifiedSearch||state.resultType==DiscoveryResultType.All||state.resultType==entity.type)&&state.results?.entities?.any {it===entity}==true
    }
    @Synchronized fun refine(candidate:DiscoveryView,entity:DiscoveryEntity):DiscoveryDraft? {
        if(!current(candidate)||!visibleEntity(entity)||unifiedSearch&&mutable.value.draft.text.trim()==entity.title)return null
        val type=mutable.value.resultType
        rememberSearch()
        edit(candidate,entity.title)
        if(unifiedSearch)mutable.value=mutable.value.copy(resultType=type)
        return mutable.value.draft
    }
    private fun rememberSearch() {
        history+=PriorSearch(mutable.value.copy(inspected=null),lanes.mapValues {(_,lane)->
            if(lane.active)lane.afterCancellation() else lane
        })
    }
    @Synchronized fun back(candidate:DiscoveryView):Boolean {
        if(!current(candidate)||history.isEmpty())return false
        cancelRadar();cancelSearches();detailsIncarnation=Any()
        val prior=history.removeAt(history.lastIndex)
        lanes.putAll(prior.lanes)
        project(prior.state.copy(canBack=history.isNotEmpty(),recent=mutable.value.recent))
        return true
    }
    @Synchronized fun showRadar(candidate:DiscoveryView,visible:()->Boolean):RadarLanding? {
        if(!radarAdmitted||!current(candidate)||!session.remoteCurrent(candidate.scope)||session.state.value !is AuthState.SignedIn||!visible())return null
        return radarLanding?.takeIf {it.view===candidate} ?: RadarLanding(candidate,visible).also {radarLanding=it}
    }
    @Synchronized fun hideRadar(landing:RadarLanding) {if(radarLanding===landing){cancelRadar();radarLanding=null}}
    private fun radarVisible(candidate:DiscoveryView)=radarLanding?.let {it.view===candidate&&it.visible()}==true&&current(candidate)&&session.remoteCurrent(candidate.scope)&&session.state.value is AuthState.SignedIn
    @Synchronized fun radarCurrent(candidate:DiscoveryView,page:RadarPage,song:RadarSong,draft:DiscoveryDraft,preview:Boolean=false):Boolean =
        radarAdmitted&&(if(preview) view===candidate&&session.previewOwnerCurrent(candidate.scope)&&
            radarLanding?.let {it.view===candidate&&it.visible()}==true else radarVisible(candidate))&&
            mutable.value.draft===draft&&draft.text.isBlank()&&radarMutable.value.page===page&&!radarMutable.value.stale&&radarMutable.value.phase==RadarPhase.Ready&&page.songs.any {it===song}
    @Synchronized internal fun sourceRowGuard(candidate:DiscoveryView,results:SourceResults,row:SourceCandidate,preview:Boolean=false):()->Boolean {
        val incarnation=detailsIncarnation
        return {synchronized(this) {
            view===candidate&&(if(preview)session.previewOwnerCurrent(candidate.scope) else session.discoveryCurrent(candidate.scope))&&detailsIncarnation===incarnation&&
                mutable.value.let {it.phase==DiscoveryPhase.Ready&&it.resultType in setOf(DiscoveryResultType.All,DiscoveryResultType.Song)&&it.results?.batches?.any {batch->batch===results}==true}&&
                results.rows.any {it===row}
        }}
    }
    @Synchronized internal fun sourceRowChoice(candidate:DiscoveryView,results:SourceResults,row:SourceCandidate,valid:()->Boolean):SourceChoice? {
        val exact=sourceRowGuard(candidate,results,row)
        if(!exact()||!valid()||!row.downloadable)return null
        val selection=results.selection ?: return null
        if(!selection.expires.isAfter(now())) {mutable.value=mutable.value.copy(expired=true);return null}
        return SourceChoice(candidate.scope,row,selection) {exact()&&valid()&&selection.expires.isAfter(now())}
    }
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
                rememberSearch()
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
        if(unifiedSearch&&mutable.value.resultType !in setOf(DiscoveryResultType.All,DiscoveryResultType.Song))return null
        val batch=mutable.value.results?.batches?.firstOrNull {batch->batch.rows.any {it===row}} ?: return null
        val selection=batch.selection ?: return null
        if(!selection.expires.isAfter(now())) {mutable.value=mutable.value.copy(expired=true);return null}
        lateinit var choice:SourceChoice
        choice=SourceChoice(candidate.scope,row,selection) {synchronized(this){current(candidate)&&mutable.value.results?.batches?.any {it===batch}==true&&mutable.value.inspected===choice&&selection.expires.isAfter(now())}}
        mutable.value=mutable.value.copy(inspected=choice,expired=false)
        return choice
    }
    @Synchronized fun reportExpired(candidate:DiscoveryView,expected:SourceChoice) {
        if(current(candidate)&&mutable.value.inspected===expected&&!expected.selection.expires.isAfter(now()))mutable.value=mutable.value.copy(inspected=null,expired=true)
    }
    @Synchronized fun dismiss(candidate:DiscoveryView,expected:SourceChoice?) {if(current(candidate)&&mutable.value.inspected===expected)mutable.value=mutable.value.copy(inspected=null)}
}
