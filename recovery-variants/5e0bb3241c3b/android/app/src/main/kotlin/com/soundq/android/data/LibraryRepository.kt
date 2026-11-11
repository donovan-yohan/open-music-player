package com.soundq.android.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import com.soundq.android.data.playlists.LibraryTrackCapture

data class LibraryState(val query: LibraryQuery = LibraryQuery(), val rows: List<Track> = emptyList(), val total: Int? = null, val loading: Boolean = false, val error: SafeFailure.Reason? = null, val mutations: Map<TrackId,MutationOutcome> = emptyMap(), val analysis:Map<TrackId,LibraryAnalysisFacts> = emptyMap(), val nextOffset:Int=0, val endReached:Boolean=false, val pageRevision:Long=0, val failedAppend:Boolean=false, val sortError:Boolean=false, val collectionLoading:Boolean=false, val collectionError:String?=null)
/** One account-bound acknowledgement and mutation owner for rows and system controls. */
class LibraryRepository(val session: AccountSession, private val fetch: (AccountScope,LibraryQuery,Int)->LibraryPage, private val mutate: (AccountScope,TrackId,Boolean)->Unit) {
    private var sortStore:LibrarySortStore?=null
    constructor(session:AccountSession,fetch:(AccountScope,LibraryQuery,Int)->LibraryPage,mutate:(AccountScope,TrackId,Boolean)->Unit,sortStore:LibrarySortStore):this(session,fetch,mutate){this.sortStore=sortStore}
    class RefinementRequest internal constructor(internal val owner:LibraryRepository,internal val scope:AccountScope,internal val query:LibraryQuery,internal val version:Long,internal val restore:Boolean) {internal var entered=false}
    class CollectionRequest internal constructor(internal val owner:LibraryRepository,internal val scope:AccountScope,internal val expected:LibraryState,internal val lifetime:Long,internal val mutation:Long,internal val selected:TrackId?,internal val shuffle:Boolean,internal val current:()->Boolean) {internal var entered=false;internal var result:List<Track>?=null}
    private var pendingCollection:CollectionRequest?=null
    private var sortScope:AccountScope?=null
    private var acceptedSort=LibrarySortChoice()
    private var sortReadable=false
    private var pendingRefinement:RefinementRequest?=null
    class LikeView internal constructor(val scope:AccountScope,val track:Track,val revision:Long,val outcome:MutationOutcome?)
    class LikeOffer internal constructor(internal val view:LikeView)
    private data class LikeReadback(val mutation:Long,val rows:List<Track>,val target:LikeView)
    class LikeReceipt internal constructor(internal val offer:LikeOffer,internal val lifetime:Long,internal val query:LibraryQuery) {internal var entered=false}
    class PageRequest internal constructor(internal val owner:LibraryRepository,internal val scope:AccountScope,internal val expected:LibraryState,internal val version:Long,internal val loading:LibraryState,internal val current:()->Boolean) {internal var entered=false}
    private val mutable=MutableStateFlow(LibraryState())
    val state: StateFlow<LibraryState> = mutable
    private val likeChanges=MutableStateFlow(0L)
    val likeRevision:StateFlow<Long> = likeChanges
    private val acknowledged=mutableMapOf<TrackId,LikeView>()
    private val mutations=mutableMapOf<TrackId,LikeReceipt>()
    internal var beforeImportPage:((Int)->Unit)?=null
    private var generation=0L
    private var queryLifetime=0L
    private var acceptedScope:AccountScope?=null
    private var mutationRevision=0L
    private var paginationSerial=0L
    private var pendingPage:PageRequest?=null
    private fun pageAnalysis(page:LibraryPage)=page.analysis.filterKeys {id->page.tracks.any {it.id==id}}
    private fun changed(){likeChanges.value++}
    private fun same(a:AccountScope,b:AccountScope)=a.owner===b.owner&&a.epoch==b.epoch&&a.accountId==b.accountId
    /** Capture the acknowledged account and exact row set, never a new account at invocation. */
    fun playAction(expectedRows:List<Track>,index:Int,play:(List<Track>,Int)->Unit):()->Unit {
        val captured=synchronized(this) {acceptedScope to queryLifetime}
        return action@{
            synchronized(this) {
                val scope=captured.first ?: return@action
                val state=mutable.value
                if(!session.remoteCurrent(scope)||queryLifetime!=captured.second||state.rows!==expectedRows||state.loading||state.error!=null||index !in expectedRows.indices)return@action
                play(expectedRows,index)
            }
        }
    }
    class PlaybackCapture internal constructor(val scope:AccountScope,val query:LibraryQuery,val selected:Int,internal val prefix:List<Track>,internal val lifetime:Long,internal val mutation:Long)
    @Synchronized fun capturePlayback(rows:List<Track>,index:Int):PlaybackCapture? {
        val scope=acceptedScope ?: return null
        val state=mutable.value
        if(!session.remoteCurrent(scope)||state.loading||state.error!=null||state.rows!==rows||index !in rows.indices)return null
        return PlaybackCapture(scope,state.query,index,rows,queryLifetime,mutationRevision)
    }
    @Synchronized fun ownsPlayback(c:PlaybackCapture)=session.remoteCurrent(c.scope)&&queryLifetime==c.lifetime&&mutationRevision==c.mutation
    /** Resolve the complete captured server query, not the lazy view's loaded prefix.
     * Each page is bounded; changing query/account/source permanently retires this read. */
    fun playback(c:PlaybackCapture,current:()->Boolean={true}):Pair<List<Track>,Int>? {
        val tracks=ArrayList<Track>();var offset=0;var total:Int?=null
        var metadataBytes=0L
        val scanned=HashSet<Long>()
        while(true) {
            if(!current()||!ownsPlayback(c))return null
            val page=fetch(c.scope,c.query,offset)
            if(!current()||!ownsPlayback(c))return null
            require(page.offset==offset && page.total in 0..com.soundq.android.playback.QueuePolicy.MAX_LOGICAL_TRACKS)
            if(total==null)total=page.total else require(total==page.total)
            require(page.limit in 1..500 && page.tracks.size<=page.limit)
            require(page.scannedIds==page.tracks.map {it.id.value}) // Never drop an unplayable member.
            require(page.scannedIds.all {scanned.add(it)}) // Refuse changing raw membership, never dedupe it.
            page.tracks.forEach {track->
                metadataBytes+=com.soundq.android.playback.QueuePolicy.metadataBytes("00000000-0000-0000-0000-000000000000",track.title,track.artist)
                require(metadataBytes<=com.soundq.android.playback.QueuePolicy.MAX_METADATA_BYTES)
            }
            tracks.addAll(page.tracks)
            require(tracks.size<=com.soundq.android.playback.QueuePolicy.MAX_LOGICAL_TRACKS)
            val next=Math.addExact(offset,page.scannedIds.size)
            require(next<=total)
            if(next==total)break
            require(next>offset);offset=next
        }
        require(tracks.take(c.prefix.size).map {it.id}==c.prefix.map {it.id})
        if(c.selected !in tracks.indices||!current()||!ownsPlayback(c))return null
        return tracks.toList() to c.selected
    }
    @Synchronized fun captureTrack(track: Track): LibraryTrackCapture? {
        val s=mutable.value;val scope=acceptedScope ?: return null
        if(!session.current(scope)||s.loading||s.error!=null||s.rows.none {it===track})return null
        return LibraryTrackCapture(scope,track,queryLifetime)
    }
    @Synchronized fun owns(capture:LibraryTrackCapture):Boolean=session.current(capture.scope)&&queryLifetime==capture.lifetime&&
        !mutable.value.loading&&mutable.value.error==null&&mutable.value.rows.any {it===capture.track}
    @Synchronized fun likeView(scope:AccountScope,id:TrackId):LikeView? = acknowledged[id]?.takeIf {session.remoteCurrent(scope)&&same(it.scope,scope)}
    @Synchronized fun offerLike(scope:AccountScope,id:TrackId):LikeOffer? {
        val view=likeView(scope,id) ?: return null
        if(view.track.liked==null||view.outcome in setOf(MutationOutcome.Pending,MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)||mutations[id]?.let {session.current(it.offer.view.scope)}==true)return null
        return LikeOffer(view)
    }
    /** Consume immutable intent before the caller schedules IO. Query refinement cannot release this lock. */
    @Synchronized fun claimLike(offer:LikeOffer):LikeReceipt? {
        val v=offer.view;val id=v.track.id
        if(!session.remoteCurrent(v.scope)||acknowledged[id]!==v||v.track.liked==null||v.outcome in setOf(MutationOutcome.Pending,MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)||mutations[id]?.let {session.current(it.offer.view.scope)}==true)return null
        val receipt=LikeReceipt(offer,queryLifetime,mutable.value.query)
        mutations[id]=receipt;generation++
        acknowledged[id]=LikeView(v.scope,v.track,++likeChanges.value,MutationOutcome.Pending)
        mutable.value=mutable.value.copy(loading=false,mutations=mutable.value.mutations+(id to MutationOutcome.Pending))
        return receipt
    }
    /** Completion can release only this never-entered claim, never a possibly dispatched write. */
    @Synchronized fun abandonLike(receipt:LikeReceipt) {
        val v=receipt.offer.view;val id=v.track.id
        if(mutations[id]!==receipt||receipt.entered)return
        mutations.remove(id)
        if(session.remoteCurrent(v.scope)) {
            acknowledged[id]?.takeIf {same(it.scope,v.scope)}?.let {acknowledged[id]=LikeView(v.scope,it.track,likeChanges.value+1,v.outcome)}
            mutable.value=mutable.value.copy(mutations=mutable.value.mutations-id)
            changed()
        }
    }
    private fun accepts(receipt:LikeReceipt)=session.remoteCurrent(receipt.offer.view.scope)&&mutations[receipt.offer.view.track.id]===receipt
    private fun observe(scope:AccountScope,rows:List<Track>,explicit:Boolean=false) {
        rows.forEach {track ->
            val old=acknowledged[track.id]?.takeIf {same(it.scope,scope)}
            val pending=mutations[track.id]?.takeIf {accepts(it)}
            val outcome=if(pending!=null)MutationOutcome.Pending else if(explicit)null else old?.outcome
            acknowledged[track.id]=LikeView(scope,track,likeChanges.value+1,outcome)
        }
        changed()
    }
    fun refine(query:LibraryQuery) {claimRefinement(query)?.let(::executeRefinement)}
    fun restore(){claimRefinement(LibraryQuery(),restore=true)?.let(::executeRefinement)}
    /** Claim before dispatch so an old scheduled refinement cannot capture a replacement account. */
    @Synchronized fun claimRefinement(query:LibraryQuery,restore:Boolean=false):RefinementRequest? {
        val scope=session.capture() ?: run {retire();return null}
        generation++;queryLifetime++;pendingPage=null;pendingCollection=null
        mutable.value=LibraryState(query=mutable.value.query,loading=true)
        return RefinementRequest(this,scope,query,generation,restore).also {pendingRefinement=it}
    }
    fun executeRefinement(request:RefinementRequest) {
        val query=synchronized(this) {
            if(request.owner!==this||request.entered||pendingRefinement!==request||generation!=request.version||!session.remoteCurrent(request.scope))return
            request.entered=true
            val scope=request.scope
            var error=false
            if(sortScope?.let {same(it,scope)}!=true) {
                acceptedSort=LibrarySortChoice();sortReadable=false;sortScope=scope
                try {acceptedSort=sortStore?.load(session.endpoint.identity,scope.accountId) ?: acceptedSort;sortReadable=true}
                catch(_:Exception){error=true}
            }
            var requested=if(request.restore)request.query.copy(sort=acceptedSort.sort,ascending=acceptedSort.ascending)else request.query
            val choice=LibrarySortChoice(requested.sort,requested.ascending)
            if(choice!=acceptedSort) {
                try {
                    check(sortReadable)
                    sortStore?.save(session.endpoint.identity,scope.accountId,choice) {session.remoteCurrent(scope)&&generation==request.version}
                    acceptedSort=choice
                }catch(_:Exception){error=true;requested=requested.copy(sort=acceptedSort.sort,ascending=acceptedSort.ascending)}
            }
            if(!session.remoteCurrent(scope)||generation!=request.version)return
            mutable.value=LibraryState(query=requested,loading=true,sortError=error||!sortReadable)
            requested
        }
        read(request.scope,query,0,request.version)
    }
    /** Exact collection reads materialize all eligible members before exposing rows or totals. */
    private fun fetchPage(scope:AccountScope,query:LibraryQuery,offset:Int,current:()->Boolean={true}):LibraryPage =
        if(query.collection==null)fetch(scope,query,offset) else {
            check(offset==0)
            readLibraryCorpus(scope,query,fetch) {session.remoteCurrent(scope)&&current()}
        }
    @Synchronized fun claimCollectionPlay(expected:LibraryState,selected:TrackId?=null,shuffle:Boolean=false,current:()->Boolean):CollectionRequest? {
        val scope=acceptedScope ?: return null
        if(mutable.value!==expected||expected.loading||expected.error!=null||expected.collectionLoading||!current()||!session.remoteCurrent(scope)||
            (selected!=null&&expected.rows.none {it.id==selected})||mutations.isNotEmpty())return null
        return CollectionRequest(this,scope,expected,queryLifetime,mutationRevision,selected,shuffle,current).also {
            pendingCollection=it;mutable.value=expected.copy(collectionLoading=true,collectionError=null)
        }
    }
    private fun ownsCollection(request:CollectionRequest)=request.owner===this&&pendingCollection===request&&session.remoteCurrent(request.scope)&&
        queryLifetime==request.lifetime&&mutationRevision==request.mutation&&mutable.value.rows===request.expected.rows&&!mutable.value.loading&&mutations.isEmpty()&&request.current()
    /** Source validity survives successful pending-request consumption. It never owns transport intent. */
    @Synchronized fun collectionPlaybackCurrent(request:CollectionRequest):Boolean =
        request.owner===this && request.entered && request.result!=null && session.remoteCurrent(request.scope) &&
        queryLifetime==request.lifetime && mutationRevision==request.mutation && mutable.value.rows===request.expected.rows &&
        !mutable.value.loading && mutations.isEmpty() && request.current()
    fun readCollection(request:CollectionRequest) {
        synchronized(this){if(request.entered||!ownsCollection(request))return;request.entered=true}
        try {
            val rows=readLibraryCorpus(request.scope,request.expected.query,fetch) {synchronized(this){ownsCollection(request)}}.tracks
            synchronized(this){if(ownsCollection(request))request.result=if(request.shuffle)rows.shuffled()else rows}
        }catch(e:Exception){synchronized(this){if(ownsCollection(request)){
            mutable.value=mutable.value.copy(collectionLoading=false,collectionError=(e as? SafeFailure)?.reason?.message ?: "Could not load collection")
            pendingCollection=null
        }}}
    }
    /** Main-thread consumer invokes the existing canonical start, never partial rows. */
    @Synchronized fun startCollection(request:CollectionRequest,start:(List<Track>,Int)->String?) {
        if(!ownsCollection(request))return
        val rows=request.result ?: return
        val index=if(request.selected==null)0 else rows.indexOfFirst {it.id==request.selected}
        val error=if(rows.isEmpty())"No matching tracks" else if(index<0)"Selected track is no longer in this collection" else start(rows,index)
        mutable.value=mutable.value.copy(collectionLoading=false,collectionError=error);pendingCollection=null
    }
    @Synchronized fun abandonCollection(request:CollectionRequest) {
        if(pendingCollection!==request)return
        pendingCollection=null;mutable.value=mutable.value.copy(collectionLoading=false)
    }
    fun revealImported(track:TrackId,current:()->Boolean):Boolean {
        val scope=session.capture() ?: return false
        val query=LibraryQuery()
        val version=synchronized(this){if(!current())return false;generation++;queryLifetime++;pendingPage=null;mutable.value=LibraryState(query=query,loading=true);generation}
        try {
            var offset=0;beforeImportPage?.invoke(offset)
            while(current()&&session.current(scope)) {
                if(synchronized(this){generation!=version})return false
                read(scope,query,offset,version)
                synchronized(this) {
                    if(!current()||!session.current(scope)||generation!=version)return false
                    val accepted=mutable.value
                    if(accepted.loading||accepted.error!=null)return false
                    if(accepted.rows.any {it.id==track})return true
                    if(accepted.endReached||accepted.nextOffset<=offset)return false
                    offset=accepted.nextOffset;mutable.value=accepted.copy(loading=true)
                }
                beforeImportPage?.invoke(offset)
            }
            return false
        } finally {synchronized(this){if(generation==version)mutable.value=mutable.value.copy(loading=false)}}
    }
    fun loadMore() {
        if(session.capture()==null)return retire()
        val expected=state.value
        // Compatibility for an explicitly cancelled import reveal before its first fetch.
        if(expected.total==null&&!expected.loading&&expected.error==null)return refine(expected.query)
        claimNextPage(expected){true}?.let(::executeNextPage)
    }

    /** Claim the displayed acknowledgement before scheduling IO. Never capture a later account/query. */
    @Synchronized fun claimNextPage(expected:LibraryState,current:()->Boolean):PageRequest? = claimPage(expected,current,false)
    /** Explicit recovery only. Automatic near-bottom reads still stop on failure. */
    @Synchronized fun claimPageRetry(expected:LibraryState,current:()->Boolean):PageRequest? = claimPage(expected,current,true)
    private fun claimPage(expected:LibraryState,current:()->Boolean,retry:Boolean):PageRequest? {
        val scope=acceptedScope ?: return null
        val eligibleError=if(retry)expected.error!=null&&expected.failedAppend else expected.error==null
        if(!current()||!session.remoteCurrent(scope)||mutable.value!==expected||expected.loading||!eligibleError||expected.endReached||expected.total==null||expected.nextOffset>=expected.total)return null
        val loading=expected.copy(loading=true,error=null,failedAppend=false)
        return PageRequest(this,scope,expected,++generation,loading,current).also {pendingPage=it;mutable.value=loading}
    }
    private fun ownsPage(request:PageRequest)=request.owner===this&&pendingPage===request&&generation==request.version&&session.remoteCurrent(request.scope)
    fun executeNextPage(request:PageRequest) {
        val admitted=synchronized(this) {
            if(request.entered)return
            if(!ownsPage(request)||!request.current())false else {request.entered=true;true}
        }
        if(!admitted){abandonNextPage(request);return}
        try {
            read(request.scope,request.expected.query,request.expected.nextOffset,request.version) {ownsPage(request)&&request.current()}
        } finally {abandonNextPage(request)}
    }
    /** Only this claim's loading paint can settle; completion cannot clear a replacement read. */
    @Synchronized fun abandonNextPage(request:PageRequest) {
        if(request.owner!==this||pendingPage!==request)return
        pendingPage=null
        if(mutable.value===request.loading)mutable.value=request.expected
    }
    private fun read(scope:AccountScope,query:LibraryQuery,offset:Int,version:Long,current:()->Boolean={true}) {
        val revision=synchronized(this){mutationRevision}
        try {
            synchronized(this){if(generation!=version||!current())return}
            session.checkScope(scope);val page=fetchPage(scope,query,offset) {synchronized(this){generation==version&&current()}}
            synchronized(this) {
                if(!session.current(scope)||generation!=version||mutationRevision!=revision||!current())return
                val prior=if(offset==0)emptyList()else mutable.value.rows
                val seen=prior.mapTo(mutableSetOf()) {it.id}
                val added=page.tracks.filter {seen.add(it.id)}
                acceptedScope=scope;observe(scope,added,explicit=true)
                val next=(offset.toLong()+page.scannedIds.size).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                val analysis=pageAnalysis(page).filterKeys {id->added.any {it.id==id}}
                mutable.value=mutable.value.copy(rows=if(added.isEmpty()&&offset>0)prior else prior+added,total=page.total,loading=false,error=null,nextOffset=next,endReached=added.isEmpty()||next<=offset||next>=page.total,pageRevision=++paginationSerial,
                    analysis=if(offset==0)analysis else mutable.value.analysis+analysis)
            }
        } catch(e:Exception) {synchronized(this){if(session.current(scope)&&generation==version&&current())mutable.value=mutable.value.copy(loading=false,error=(e as? SafeFailure)?.reason?:SafeFailure.Reason.Network,failedAppend=offset>0)}}
    }
    fun like(track:Track) {
        val offer=synchronized(this) {
            val scope=acceptedScope ?: return
            if(!session.remoteCurrent(scope)||mutable.value.rows.none {it===track})return
            offerLike(scope,track.id) ?: return
        }
        val receipt=claimLike(offer) ?: return
        executeLike(receipt)
    }
    /** No player or collection-selection dependency survives admission. */
    fun executeLike(receipt:LikeReceipt):MutationOutcome {
        val v=receipt.offer.view;val scope=v.scope;val id=v.track.id
        synchronized(this){if(!accepts(receipt)||receipt.entered)return MutationOutcome.Refused;receipt.entered=true}
        var outcome=MutationOutcome.Confirmed
        try {session.checkRemote(scope);mutate(scope,id,!v.track.liked!!)}
        catch(e:Exception){outcome=if((e as? SafeFailure)?.reason in setOf(SafeFailure.Reason.Refused,SafeFailure.Reason.Retired))MutationOutcome.Refused else MutationOutcome.Uncertain}
        val version=synchronized(this) {
            if(!accepts(receipt)){if(mutations[id]===receipt)mutations.remove(id);return outcome}
            if(outcome!=MutationOutcome.Refused){generation++;mutationRevision++}
            acknowledged[id]=LikeView(scope,v.track,likeChanges.value+1,outcome);changed()
            if(queryLifetime==receipt.lifetime)mutable.value=mutable.value.copy(mutations=mutable.value.mutations+(id to outcome))
            LikeReadback(mutationRevision,mutable.value.rows,acknowledged[id]!!)
        }
        if(outcome!=MutationOutcome.Refused) {
            try {
                session.checkRemote(scope);val page=fetchPage(scope,receipt.query,0) {synchronized(this){accepts(receipt)}}
                val row=page.tracks.singleOrNull {it.id==id}
                // An off-page or filtered-out current song uses the same owned-library contract.
                val target=if(row!=null)row else readOwned(scope,id)
                synchronized(this) {
                    if(accepts(receipt)) {
                        val targetCurrent=acknowledged[id]===version.target
                        val pageCurrent=mutationRevision==version.mutation&&queryLifetime==receipt.lifetime&&mutable.value.rows===version.rows
                        if(pageCurrent)observe(scope,page.tracks.filter {it.id!=id})
                        // A sibling may invalidate the page, not this still-owned target read.
                        if(targetCurrent) {
                            if(target!=null)acknowledged[id]=LikeView(scope,target,likeChanges.value+1,outcome) else acknowledged.remove(id)
                        }
                        if(pageCurrent) {
                            val acceptedTarget=acknowledged[id]?.track
                            val rows=page.tracks.map {if(it.id==id&&acceptedTarget!=null)it.copy(liked=acceptedTarget.liked) else it}
                            mutable.value=mutable.value.copy(rows=rows,total=page.total,error=null,loading=false,analysis=pageAnalysis(page),nextOffset=page.scannedIds.size,endReached=page.tracks.isEmpty()||page.scannedIds.size>=page.total,pageRevision=++paginationSerial)
                        } else if(targetCurrent&&target!=null) {
                            val rows=mutable.value.rows
                            if(rows.any {it.id==id&&it.liked!=target.liked})mutable.value=mutable.value.copy(rows=rows.map {if(it.id==id)it.copy(liked=target.liked) else it})
                        }
                        changed()
                    }
                }
            } catch(_:Exception) {
                synchronized(this) {
                    if(accepts(receipt)) {
                        if(outcome==MutationOutcome.Confirmed)outcome=MutationOutcome.ReadbackFailed
                        val observed=acknowledged[id]
                        if(observed===version.target)acknowledged[id]=LikeView(scope,observed.track,likeChanges.value+1,outcome)
                        changed()
                        if(queryLifetime==receipt.lifetime)mutable.value=mutable.value.copy(error=if(mutationRevision==version.mutation)SafeFailure.Reason.Network else mutable.value.error,mutations=mutable.value.mutations+(id to outcome))
                    }
                }
            }
        }
        synchronized(this){if(mutations[id]===receipt){mutations.remove(id);acknowledged[id]?.let {if(same(it.scope,scope))acknowledged[id]=LikeView(scope,it.track,likeChanges.value+1,outcome)};changed()}}
        return outcome
    }
    private fun readOwned(scope:AccountScope,id:TrackId):Track? {
        var offset=0
        repeat(1000) {
            session.checkRemote(scope);val page=fetch(scope,LibraryQuery(),offset)
            page.tracks.singleOrNull {it.id==id}?.let {return it}
            offset+=page.tracks.size
            if(offset>=page.total)return null
            if(page.tracks.isEmpty())throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        }
        throw SafeFailure(SafeFailure.Reason.InvalidResponse)
    }
    /** Explicit GET-only reconciliation, never a retry of an uncertain write or a visible query reset. */
    fun reconcileLike(scope:AccountScope,id:TrackId) {
        val revision=synchronized(this){if(!session.remoteCurrent(scope)||mutations[id]?.let {accepts(it)}==true)return;mutationRevision}
        val track=readOwned(scope,id)
        synchronized(this) {
            if(!session.remoteCurrent(scope)||mutationRevision!=revision||mutations[id]?.let {accepts(it)}==true)return
            if(track==null)acknowledged.remove(id) else observe(scope,listOf(track),explicit=true)
            mutable.value=mutable.value.copy(rows=mutable.value.rows.map {if(it.id==id&&track!=null)it.copy(liked=track.liked) else it},mutations=mutable.value.mutations-id)
            changed()
        }
    }
    fun refreshObserved(scope:AccountScope,expected:LibraryState,valid:()->Boolean={true}) {
        val version=synchronized(this){if(!valid()||!session.current(scope)||mutable.value!==expected||expected.loading)return;generation}
        val page=fetchPage(scope,expected.query,0) {valid()&&session.current(scope)&&synchronized(this){generation==version}}
        synchronized(this){if(valid()&&session.current(scope)&&generation==version&&mutable.value===expected){generation++;observe(scope,page.tracks,true);mutable.value=expected.copy(rows=page.tracks,total=page.total,error=null,analysis=pageAnalysis(page),nextOffset=page.scannedIds.size,endReached=page.tracks.isEmpty()||page.scannedIds.size>=page.total,pageRevision=++paginationSerial)}}
    }
    @Synchronized fun retire(){generation++;queryLifetime++;pendingPage=null;mutations.clear();acknowledged.clear();acceptedScope=null;mutable.value=LibraryState();changed()}
}
