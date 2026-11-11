package com.soundq.android.data.harmonic

import com.soundq.android.data.*
import com.soundq.android.data.playlists.*
import com.soundq.android.data.preferences.DjModePreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class HarmonicRoute internal constructor(internal val scope:AccountScope,internal val detail:PlaylistDetail,internal val version:Long,internal val djRevision:Long)
class HarmonicResultCapture internal constructor(internal val route:HarmonicRoute,internal val revision:Long,internal val result:NearbyResult,internal val index:Int,val row:NearbyTrack)
data class HarmonicState(val open:Boolean=false,val draft:HarmonicDraft=HarmonicDraft(),val result:NearbyResult?=null,val loading:Boolean=false,val disabled:Boolean=false,val failed:Boolean=false,val inputsChanged:Boolean=false,val notice:String?=null)
/** Playlist-screen-local read/action capabilities. Membership writes remain in PlaylistManagement. */
class HarmonicRepository(private val api:SoundQApi,private val detail:PlaylistDetailRepository,private val dj:DjModePreferences) {
    private val mutable=MutableStateFlow(HarmonicState())
    val state:StateFlow<HarmonicState> = mutable
    private var route:HarmonicRoute?=null
    private var revision=0L
    private var retained:PlaylistDetail?=null
    private var retainedVersion=-1L
    private var retainedDj=-1L
    private var exclude:TrackId?=null
    private var initial=false
    @Synchronized fun open():HarmonicRoute? {
        val source=detail.managementDetail()?:return null
        val scope=api.session.capture()?:return null
        if(!dj.enabled())return null
        revision++
        val version=detail.managementVersion();val djRevision=dj.state.value.revision
        if(retained!==source||retainedVersion!=version||retainedDj!=djRevision) {
            val seed=harmonicSeed(source);exclude=seed.exclude;initial=seed.exclude!=null&&seed.draft.query()!=null
            mutable.value=HarmonicState(draft=seed.draft)
            retained=source;retainedVersion=version;retainedDj=djRevision
        }
        return HarmonicRoute(scope,source,version,djRevision).also {route=it;mutable.value=mutable.value.copy(open=true,loading=false,notice=null)}
    }
    @Synchronized fun owns(owner:HarmonicRoute):Boolean=route===owner&&api.session.current(owner.scope)&&dj.enabled()&&dj.state.value.revision==owner.djRevision&&detail.managementVersion()==owner.version&&detail.managementDetail()===owner.detail
    @Synchronized fun close(owner:HarmonicRoute) {if(route===owner){route=null;revision++;initial=false;mutable.value=mutable.value.copy(open=false,loading=false)}}
    @Synchronized fun retire() {route=null;retained=null;revision++;initial=false;mutable.value=HarmonicState()}
    @Synchronized fun edit(owner:HarmonicRoute,draft:HarmonicDraft) {
        if(!owns(owner)||!mutable.value.open||mutable.value.loading||draft==mutable.value.draft)return
        revision++;mutable.value=mutable.value.copy(draft=draft,inputsChanged=mutable.value.result!=null,notice=null)
    }
    @Synchronized fun initial(owner:HarmonicRoute):(() -> Unit)? {
        if(!owns(owner)||!mutable.value.open||!initial)return null
        initial=false;return search(owner)
    }
    @Synchronized fun search(owner:HarmonicRoute):(() -> Unit)? {
        val query=mutable.value.draft.query()?:return null
        if(!owns(owner)||!mutable.value.open||mutable.value.loading)return null
        revision++;val request=revision
        mutable.value=mutable.value.copy(loading=true,result=null,disabled=false,failed=false,notice=null,inputsChanged=false)
        return {
            fun current()=synchronized(this){owns(owner)&&revision==request}
            try {
                val result=api.nearbyTracks(owner.scope,query,::current)
                synchronized(this){if(current())mutable.value=mutable.value.copy(loading=false,result=result.copy(tracks=result.tracks.filter {it.id!=exclude}))}
            }catch(e:Exception){synchronized(this){if(current())mutable.value=mutable.value.copy(loading=false,result=null,disabled=e is NearbyDisabled,failed=e !is NearbyDisabled)}}
        }
    }
    @Synchronized fun capture(owner:HarmonicRoute,index:Int,row:NearbyTrack):HarmonicResultCapture? {
        val s=mutable.value;val result=s.result?:return null
        if(!owns(owner)||!s.open||s.loading||s.inputsChanged||result.tracks.getOrNull(index)!==row)return null
        return HarmonicResultCapture(owner,revision,result,index,row)
    }
    @Synchronized fun current(capture:HarmonicResultCapture)=owns(capture.route)&&capture.revision==revision&&mutable.value.result===capture.result&&capture.result.tracks.getOrNull(capture.index)===capture.row&&!mutable.value.loading&&!mutable.value.inputsChanged
    @Synchronized fun queueTrack(capture:HarmonicResultCapture):Track?=if(current(capture))capture.row.queueTrack(capture.route.detail)else null
    @Synchronized fun queue(capture:HarmonicResultCapture,consume:(Track)->Unit):Boolean {
        if(!mutable.value.open)return false
        val track=queueTrack(capture)?:return false
        consume(track);return true
    }
    /** Consume the mounted selection before closing the sheet; the captured host continuation alone survives that close. */
    @Synchronized fun queueAction(capture:HarmonicResultCapture,selected:()->Boolean,consume:(Track)->Unit):(() -> Boolean)? {
        val track=queueTrack(capture)?:return null
        if(!mutable.value.open||!selected())return null
        mutable.value=mutable.value.copy(open=false)
        var used=false
        return {synchronized(this) {
            if(used||!current(capture))false else {used=true;consume(track);true}
        }}
    }
    /** Capture selection lifetime too: a result handle alone cannot authorize a later selected row. */
    fun membership(capture:HarmonicResultCapture,target:PlaylistManagementTarget,manager:PlaylistManagementRepository,selected:()->Boolean):(() -> Unit)? {
        synchronized(this) {if(!mutable.value.open||!current(capture)||target.detail!==capture.route.detail||!selected())return null}
        // Do not hold the read-owner monitor while entering the shared mutation owner.
        val work=manager.addHarmonic(target,capture.row.id){current(capture)}?:return null
        synchronized(this) {if(current(capture))mutable.value=mutable.value.copy(open=false)}
        return work
    }
}
