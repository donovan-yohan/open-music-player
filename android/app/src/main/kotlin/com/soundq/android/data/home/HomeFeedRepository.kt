package com.soundq.android.data.home

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class HomeSection { Recent, Top, History }
enum class HistoryKind { All, Listened, Skipped }
data class HistoryQuery(val text:String="",val kind:HistoryKind=HistoryKind.All) {
    internal fun matches(event:HistoryEntry):Boolean =
        (kind==HistoryKind.All || event.skipped==(kind==HistoryKind.Skipped)) &&
        (text.isBlank() || event.entry.track.title.contains(text.trim(),ignoreCase=true) || event.entry.track.artist.contains(text.trim(),ignoreCase=true))
}
data class HistoryReadState(val rows: List<HistoryEntry> = emptyList(), val loading: Boolean = false, val error: SafeFailure.Reason? = null, val nextOffset: Int = 0, val hasMore: Boolean = false, val retryAppend: Boolean = false, val query:HistoryQuery=HistoryQuery())

/** Feature read/action owner; Media3 remains the only playback/queue owner. */
class HomeFeedRepository(private val session: AccountSession, private val api: SoundQApi) {
    private val recentMutable = MutableStateFlow(HomeReadState())
    private val topMutable = MutableStateFlow(HomeReadState())
    private val historyMutable = MutableStateFlow(HistoryReadState())
    val recent: StateFlow<HomeReadState> = recentMutable
    val top: StateFlow<HomeReadState> = topMutable
    val history: StateFlow<HistoryReadState> = historyMutable
    private data class ReadOwner(val scope: AccountScope, val route: HomeRoute, val generation: Long)
    private val owners = mutableMapOf<HomeSection, ReadOwner>()
    private var generation = 0L
    private fun allowed(route: HomeRoute, section: HomeSection) = route.current() &&
        route.destination == if (section == HomeSection.History) HomeDestination.History else HomeDestination.Home
    private fun current(section: HomeSection, owner: ReadOwner) = owners[section] === owner &&
        allowed(owner.route, section) && session.current(owner.scope)
    @Synchronized private fun rows(section: HomeSection): Any = when(section) {
        HomeSection.Recent -> recentMutable.value.rows
        HomeSection.Top -> topMutable.value.rows
        HomeSection.History -> historyMutable.value.rows
    }
    fun load(route: HomeRoute, section: HomeSection, expected: Any? = null, append: Boolean = false) {
        if (section == HomeSection.History) { loadHistory(route, expected, append); return }
        if (section == HomeSection.Recent) { claimRecent(route,expected as? HomeReadState,append)?.let(::executeRecent); return }
        val owner: ReadOwner
        val target = topMutable
        synchronized(this) {
            if (!allowed(route, section) || (expected != null && (expected !== target.value || owners[section]?.let {current(section,it)} != true))) return
            val scope = session.capture() ?: return
            owner = ReadOwner(scope, route, ++generation)
            val previous = owners[section]
            owners[section] = owner
            target.value = if (previous?.route === route && session.current(previous.scope)) target.value.copy(loading=true,error=null) else HomeReadState(loading=true)
        }
        try {
            val valid = { synchronized(this) { current(section, owner) } }
            val loaded = api.top(owner.scope,valid)
            synchronized(this) { if(current(section,owner)) target.value = HomeReadState(rows=loaded) }
        } catch(error: Exception) {
            synchronized(this) { if(current(section,owner)) target.value = target.value.copy(loading=false,error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network) }
        }
    }
    class RecentRequest internal constructor(
        internal val repository:HomeFeedRepository,internal val scope:AccountScope,internal val route:HomeRoute,
        internal val generation:Long,internal val before:HomeReadState,internal val loading:HomeReadState,
        internal val append:Boolean,
    ) {internal var entered=false}
    /** Presentation only: expose the accepted page without replacing its row owner. */
    @Synchronized fun revealRecent(route:HomeRoute,expected:HomeReadState):Boolean {
        if(recentMutable.value!==expected||expected.loading||owners[HomeSection.Recent]?.let {it.route===route&&current(HomeSection.Recent,it)}!=true)return false
        if(expected.visibleCount!=expected.rows.size)recentMutable.value=expected.copy(visibleCount=expected.rows.size)
        return true
    }
    private var pendingRecent:RecentRequest?=null
    /** Claim synchronously at the rendered input, before ViewModel schedules IO.
     * Buffered reveal changes only presentation, retaining the full accepted
     * rows object and owner used by playback/queue capability admission. */
    @Synchronized fun claimRecent(route:HomeRoute,expected:HomeReadState?=null,append:Boolean=false):RecentRequest? {
        val before=recentMutable.value
        if(!allowed(route,HomeSection.Recent) || (expected!=null && (expected!==before || owners[HomeSection.Recent]?.let {current(HomeSection.Recent,it)}!=true)))return null
        val scope=session.capture() ?: return null
        val previous=owners[HomeSection.Recent]
        val same=previous?.route===route && session.current(previous.scope)
        if(append) {
            if(!same || before.loading || !before.hasMore || before.revision==null)return null
            if(before.visibleCount+5<=before.rows.size || !before.serverHasMore) {
                recentMutable.value=before.copy(visibleCount=minOf(before.visibleCount+5,before.rows.size),error=null,retryAppend=false)
                return null
            }
        }
        val owner=ReadOwner(scope,route,++generation)
        owners[HomeSection.Recent]=owner
        val loading=if(same)before.copy(loading=true,error=null) else HomeReadState(loading=true)
        recentMutable.value=loading
        return RecentRequest(this,scope,route,owner.generation,before,loading,append).also {pendingRecent=it}
    }
    private fun ownsRecent(request:RecentRequest):Boolean = request.repository===this && pendingRecent===request &&
        owners[HomeSection.Recent]?.let {it.generation==request.generation && current(HomeSection.Recent,it)}==true
    fun executeRecent(request:RecentRequest) {
        synchronized(this) {if(request.entered || !ownsRecent(request))return;request.entered=true}
        val valid={synchronized(this){ownsRecent(request)}}
        var append=request.append
        try {
            val page=try {api.recentPage(request.scope,if(append)request.before.nextOffset else 0,if(append)request.before.revision else null,valid)}
            catch(_:RecentChanged) {
                synchronized(this) {
                    if(!ownsRecent(request))return
                    // Corpus invalidation is not an append failure. Retire the
                    // old rows/actions and replace under the same single claim.
                    recentMutable.value=HomeReadState(loading=true)
                }
                append=false
                api.recentPage(request.scope,valid=valid)
            }
            synchronized(this) {
                if(!ownsRecent(request))return
                if(append && page.rows.isEmpty())throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                val rows=if(append)request.before.rows+page.rows else page.rows
                // Equal revision plus a repeated ID is malformed, never a
                // license to dedupe away an omitted successor.
                if(rows.map {it.track.id}.distinct().size!=rows.size)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                recentMutable.value=HomeReadState(rows=rows,visibleCount=if(append)minOf(request.before.visibleCount+5,rows.size) else minOf(5,rows.size),
                    nextOffset=rows.size,revision=page.revision,serverHasMore=page.hasMore)
            }
        } catch(error:Exception) {
            synchronized(this) {if(ownsRecent(request))recentMutable.value=recentMutable.value.copy(
                loading=false,error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network,retryAppend=append)}
        } finally {abandonRecent(request)}
    }
    @Synchronized fun abandonRecent(request:RecentRequest) {
        if(pendingRecent!==request)return
        pendingRecent=null
        if(recentMutable.value===request.loading)recentMutable.value=request.loading.copy(loading=false)
    }
    class HistoryRequest internal constructor(
        internal val repository:HomeFeedRepository,internal val scope:AccountScope,internal val route:HomeRoute,
        internal val generation:Long,internal val before:HistoryReadState,internal val loading:HistoryReadState,
        internal val query:HistoryQuery,internal val append:Boolean,internal val offset:Int,
    ) { internal var entered=false }
    private var pendingHistory:HistoryRequest?=null
    private fun loadHistory(route: HomeRoute, expected: Any?, append: Boolean) {
        claimHistory(route,expected as? HistoryReadState,append)?.let(::executeHistory)
    }
    /** Claim at the rendered input, before scheduling IO, so an old query cannot win a dispatch race. */
    @Synchronized fun claimHistory(route:HomeRoute,expected:HistoryReadState?=null,append:Boolean=false,query:HistoryQuery?=null):HistoryRequest? {
        val before=historyMutable.value
        if(!allowed(route,HomeSection.History) || (expected!=null && (expected!==before || owners[HomeSection.History]?.let {current(HomeSection.History,it)}!=true)))return null
        val scope=session.capture() ?: return null
        val previous=owners[HomeSection.History]
        val same=previous?.route===route && session.current(previous.scope)
        val selected=query ?: if(same)before.query else HistoryQuery()
        if(append && (!same || selected!=before.query || before.loading || !before.hasMore))return null
        val owner=ReadOwner(scope,route,++generation)
        owners[HomeSection.History]=owner
        val loading=if(same && selected==before.query)before.copy(loading=true,error=null)
            else HistoryReadState(loading=true,query=selected)
        historyMutable.value=loading
        return HistoryRequest(this,scope,route,owner.generation,before,loading,selected,append,if(append)before.nextOffset else 0).also {pendingHistory=it}
    }
    private fun ownsHistory(request:HistoryRequest):Boolean = request.repository===this && pendingHistory===request &&
        owners[HomeSection.History]?.let {it.generation==request.generation && current(HomeSection.History,it)}==true
    fun executeHistory(request:HistoryRequest) {
        synchronized(this) {if(request.entered || !ownsHistory(request))return;request.entered=true}
        val valid={synchronized(this){ownsHistory(request)}}
        try {
            var offset=request.offset
            val matches=mutableListOf<HistoryEntry>()
            val seen=(if(request.append)request.before.rows else emptyList()).mapTo(mutableSetOf()){it.id}
            var hasMore:Boolean
            // The server has no text/skip filter. Walk the raw corpus, not the
            // first displayed page. Only matching events consume visible slots.
            while(true) {
                if(!valid())return
                val page=api.history(request.scope,offset,valid)
                var consumed=0
                for(event in page) {
                    consumed++
                    if(request.query.matches(event) && seen.add(event.id))matches+=event
                    if(matches.size==50)break
                }
                offset=Math.addExact(offset,consumed)
                hasMore=consumed<page.size || page.size==50
                if(matches.size==50 || !hasMore)break
            }
            synchronized(this) {
                if(!ownsHistory(request))return
                historyMutable.value=HistoryReadState(
                    rows=if(request.append)request.before.rows+matches else matches,
                    nextOffset=offset,hasMore=hasMore,query=request.query,
                )
            }
        } catch(error:Exception) {
            synchronized(this) {if(ownsHistory(request))historyMutable.value=historyMutable.value.copy(
                loading=false,error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network,retryAppend=request.append,
            )}
        } finally {abandonHistory(request)}
    }
    @Synchronized fun abandonHistory(request:HistoryRequest) {
        if(pendingHistory!==request)return
        pendingHistory=null
        if(historyMutable.value===request.loading)historyMutable.value=request.loading.copy(loading=false)
    }
    fun playAction(route: HomeRoute, section: HomeSection, expected: Any, entry: HomeEntry, eventId: Long? = null, play: (List<Track>, Int) -> Unit): () -> Unit {
        return playActionWithSource(route,section,expected,entry,eventId) {tracks,index,_ -> play(tracks,index)}
    }
    /** Freeze the read owner, route, account and accepted list at binding time.
     * Owner/route/scope identities never revive after replacement, even on ABA.
     * The controller may check this source during staging or registry claim. */
    fun playActionWithSource(route: HomeRoute, section: HomeSection, expected: Any, entry: HomeEntry, eventId: Long? = null, play: (List<Track>, Int, () -> Boolean) -> Unit): () -> Unit {
        val captured = synchronized(this) { owners[section] }
        val valid = { synchronized(this) {
            captured != null && captured.route === route && current(section,captured) && rows(section) === expected
        } }
        return action@{
            val context = synchronized(this) {
                if(!valid() || !entry.eligible) return@action
                if(section == HomeSection.History) {
                    @Suppress("UNCHECKED_CAST") val events = expected as List<HistoryEntry>
                    if(events.none {it.id == eventId && it.entry === entry}) return@action
                    listOf(entry.track) to 0
                } else {
                    @Suppress("UNCHECKED_CAST") val entries = expected as List<HomeEntry>
                    if(entries.none {it === entry}) return@action
                    val eligible = entries.filter {it.eligible}
                    val index = eligible.indexOfFirst {it === entry}
                    if(index < 0) return@action
                    eligible.map {it.track} to index
                }
            }
            // Never enter the context registry while holding the repository:
            // registry claim can invoke valid() in the opposite direction.
            play(context.first,context.second,valid)
        }
    }
    /** A queue capability never invokes playAction or expands the selected context. */
    fun queueAction(route:HomeRoute,section:HomeSection,expected:Any,entry:HomeEntry,eventId:Long?=null,queue:(Track)->Unit):()->Unit {
        val captured=synchronized(this){owners[section]}
        return action@{
            synchronized(this) {
                val owner=captured ?: return@action
                if(owner.route!==route||!current(section,owner)||rows(section)!==expected||!entry.eligible)return@action
                val present=if(section==HomeSection.History) {
                    @Suppress("UNCHECKED_CAST") val events=expected as List<HistoryEntry>
                    events.any {it.id==eventId&&it.entry===entry}
                }else {
                    @Suppress("UNCHECKED_CAST") val entries=expected as List<HomeEntry>
                    entries.any {it===entry}
                }
                if(present)queue(entry.track)
            }
        }
    }
    @Synchronized fun owns(route: HomeRoute, section: HomeSection): Boolean = owners[section]?.let { it.route === route && current(section,it) } == true
    @Synchronized fun retire() {
        generation++; owners.clear(); pendingHistory=null; pendingRecent=null
        recentMutable.value=HomeReadState(); topMutable.value=HomeReadState(); historyMutable.value=HistoryReadState()
    }
}
