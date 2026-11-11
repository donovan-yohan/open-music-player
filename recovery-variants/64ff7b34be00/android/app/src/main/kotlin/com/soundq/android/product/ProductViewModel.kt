package com.soundq.android.product

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.data.imports.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import com.soundq.android.data.timeline.*

/** Reserve on the action thread; even a coroutine cancelled before entry must release its own claim. */
internal fun scheduleOnlineRestore(session:AccountSession,api:SoundQApi,scope:AccountScope?,work:CoroutineScope,
    busy:kotlinx.coroutines.flow.MutableStateFlow<AccountSession.OnlineRestoreTicket?>,dispatcher:CoroutineDispatcher=Dispatchers.IO):Job? {
    val ticket=(if(scope==null)session.claimSavedRestore() else session.claimOnlineRestore(scope)) ?: return null
    busy.value=ticket
    return work.launch(dispatcher) {api.restoreOnline(ticket)}.also {job ->
        job.invokeOnCompletion {
            session.abandonOnlineRestore(ticket)
            busy.compareAndSet(ticket,null)
        }
    }
}

class ProductViewModel(app:Application):AndroidViewModel(app) {
    val graph=(app as SoundQApplication).graph
    val auth=graph.session.state
    internal val mixExchange=com.soundq.android.product.mix.MixExchangeRetained(graph.api)
    val library=graph.library.state
    val trackDetails=graph.trackDetails.state
    fun loadTrackDetails(route:com.soundq.android.data.trackdetails.DetailsRoute) {viewModelScope.launch(Dispatchers.IO){graph.trackDetails.load(route)}}
    fun changeTrackDetails(route:com.soundq.android.data.trackdetails.DetailsRoute,observed:com.soundq.android.data.trackdetails.TrackDetails,action:com.soundq.android.data.trackdetails.DetailsAction) {
        val ticket=graph.trackDetails.claim(route,observed,action) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.trackDetails.execute(ticket)}
    }
    val downloads=graph.downloads.state
    fun loadDownloads(scope:AccountScope,valid:()->Boolean) {viewModelScope.launch(Dispatchers.IO){if(valid())graph.downloads.load(scope)}}
    fun downloadLibrary(capture:com.soundq.android.data.playlists.LibraryTrackCapture,valid:()->Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            if(!valid()||!graph.library.owns(capture))return@launch
            graph.downloads.load(capture.scope)
            val ticket=graph.downloads.claim(capture.scope,capture.track){valid()&&graph.library.owns(capture)} ?: return@launch
            graph.downloads.transfer(ticket)
        }
    }
    fun retryDownload(scope:AccountScope,row:com.soundq.android.data.offline.DeviceDownload,valid:()->Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            if(!valid()||graph.downloads.state.value.rows.none {it===row})return@launch
            val ticket=graph.downloads.claim(scope,row.track,valid) ?: return@launch
            graph.downloads.transfer(ticket)
        }
    }
    fun cancelDownload(scope:AccountScope,row:com.soundq.android.data.offline.DeviceDownload,valid:()->Boolean) {
        viewModelScope.launch(Dispatchers.IO){if(valid())graph.downloads.cancel(scope,row)}
    }
    fun removeDownloads(scope:AccountScope,rows:List<com.soundq.android.data.offline.DeviceDownload>,valid:()->Boolean) {
        viewModelScope.launch(Dispatchers.IO){if(valid())graph.downloads.remove(scope,rows)}
    }
    fun playDownload(scope:AccountScope,row:com.soundq.android.data.offline.DeviceDownload,valid:()->Boolean) {
        if(!valid()||!graph.session.current(scope)||row.status!=com.soundq.android.data.offline.DownloadStatus.Complete||downloads.value.rows.none {it===row})return
        graph.rememberTracks(listOf(row.track));controller.playContext(listOf(row.track),0,localOnly=true)
    }
    /** Admission/pending only, never an ACK from the asynchronous MediaController command. */
    fun enqueueDownload(scope:AccountScope,row:com.soundq.android.data.offline.DeviceDownload,valid:()->Boolean,next:Boolean=false):Boolean {
        if(!valid()||!graph.downloads.ownsComplete(scope,row))return false
        viewModelScope.launch {
            val admitted=withContext(Dispatchers.IO) {valid()&&graph.downloads.validateComplete(scope,row)}
            if(!admitted||!valid()||!graph.downloads.ownsComplete(scope,row))return@launch
            graph.rememberTracks(listOf(row.track))
            controller.enqueue(row.track,next,localOnly=true)
        }
        return true
    }
    fun quickQueueDownload(scope:AccountScope,row:com.soundq.android.data.offline.DeviceDownload,valid:()->Boolean):Boolean =
        enqueueDownload(scope,row,valid,graph.swipeQueuePreferences.state.value.mode==com.soundq.android.data.preferences.SwipeQueue.PlayNext)
    val queueSettings=graph.queueSettings.state
    fun keepQueued(capture:QueueSettingsCapture,value:Boolean,valid:()->Boolean) {
        viewModelScope.launch(Dispatchers.IO) {graph.queueSettings.setKeepQueued(capture,value,valid)}
    }
    fun reloadQueueSettings(valid:()->Boolean) {viewModelScope.launch(Dispatchers.IO) {if(valid())graph.queueSettings.load()}}
    val home=graph.home
    fun acquire(work:(() -> Unit)?) {graph.acquisition.schedule(viewModelScope,work)}
    val imports=graph.imports.state
    val playlists=graph.playlists.state
    fun catalogActions() = com.soundq.android.data.catalog.CatalogActions(graph.catalog) {work -> viewModelScope.launch(Dispatchers.IO) {work()}}
    fun playlistActions() = com.soundq.android.data.playlists.PlaylistActions(graph.playlists) { work -> viewModelScope.launch(Dispatchers.IO) { work() } }
    val playlistMembership=graph.playlistMembership.state
    fun libraryPlaylistActions() = com.soundq.android.data.playlists.LibraryPlaylistActions(graph.playlistMembership) { work -> viewModelScope.launch(Dispatchers.IO) { work() } }
    val playlistManagement=graph.playlistManagement.state
    fun playlistManagementActions() = com.soundq.android.data.playlists.PlaylistManagementActions(graph.playlistManagement) { work -> viewModelScope.launch(Dispatchers.IO) { work() } }
    val playlistOrder=graph.playlistOrder.state
    val queuePlaylist=graph.queuePlaylist.state
    fun playlistOrderActions() = com.soundq.android.data.playlists.PlaylistOrderActions(graph.playlistOrder) { work -> viewModelScope.launch(Dispatchers.IO) { work() } }
    fun queuePlaylistActions() = com.soundq.android.data.playlists.QueuePlaylistActions(graph.queuePlaylist, { work -> viewModelScope.launch(Dispatchers.IO) { work() } }, { playback.value })
    val playlistBlend=graph.playlistBlend.state
    fun generatePlaylistBlend(capture:com.soundq.android.data.playlists.BlendCapture) {
        val work=graph.playlistBlend.generate(capture) ?: return
        graph.playlistBlend.schedule(viewModelScope,work,Dispatchers.IO)
    }
    fun recoverPlaylistBlend(capture:com.soundq.android.data.playlists.BlendCapture) {
        val work=graph.playlistBlend.recover(capture) ?: return
        graph.playlistBlend.schedule(viewModelScope,work,Dispatchers.IO)
    }
    val playlistDetail=graph.playlistDetail.state

    fun openPlaylist(capture:com.soundq.android.data.playlists.PlaylistListCapture,row:com.soundq.android.data.playlists.PlaylistSummary){
        val current=graph.playlists.captureList() ?: return
        if(!graph.session.current(capture.scope)||current.lifetime!=capture.lifetime||playlists.value.rows.none {it===row})return
        val request=graph.playlistDetail.select(row.id) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.playlistDetail.load(request)}
    }
    fun harmonicWork(work:(()->Unit)?) {if(work!=null)viewModelScope.launch(Dispatchers.IO){work()}}
    fun harmonicQueue(capture:com.soundq.android.data.harmonic.HarmonicResultCapture,selected:()->Boolean):Boolean {
        if(playback.value.connection!=com.soundq.android.playback.PlaybackProjection.Connection.Connected||playback.value.queue.size>=com.soundq.android.playback.QueuePolicy.MAX_CONTEXT_TRACKS)return false
        val action=graph.harmonic.queueAction(capture,selected){track->graph.rememberTracks(listOf(track));controller.enqueue(track,false)}?:return false
        return action()
    }
    fun closePlaylistDetail(){graph.harmonic.retire();graph.playlistBlend.leave();graph.playlistDetail.retire()}
    fun retryPlaylistDetail(){
        val id=playlistDetail.value.id ?: return
        val request=graph.playlistDetail.select(id) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.playlistDetail.load(request)}
    }
    fun playPlaylist(capture:com.soundq.android.data.playlists.PlaylistPlaybackCapture,id:TrackId,index:Int=capture.detail.tracks.indices.filter {capture.detail.tracks[it].id==id}.singleOrNull() ?: -1){
        if(capture.detail.tracks.getOrNull(index)?.id!=id)return
        when(val launch=graph.playlistBlend.launchAt(capture,index)) {
            is com.soundq.android.data.playlists.PlaylistLaunch.Plain->{graph.rememberTracks(launch.tracks);controller.playContext(launch.tracks,launch.index)}
            is com.soundq.android.data.playlists.PlaylistLaunch.Mixed->{
                val token=graph.playlistBlend.reserveStart(launch) ?: return
                controller.playMix(launch.plan,launch.occurrence,token) {accepted->
                    graph.playlistBlend.cancelStart(token)
                    if(!accepted)graph.playlistBlend.playbackRefused(launch)
                }
            }
            com.soundq.android.data.playlists.PlaylistLaunch.Refused->Unit
        }
    }

    fun shufflePlaylist(capture:com.soundq.android.data.playlists.PlaylistPlaybackCapture,id:TrackId) {
        val launch=graph.playlistBlend.launch(capture,id,shuffle=true) as? com.soundq.android.data.playlists.PlaylistLaunch.Plain ?: return
        graph.rememberTracks(launch.tracks);controller.playContext(launch.tracks,launch.index)
    }
    internal val controller=graph.controller
    val playback=controller.state
    private var loadedAccount:Pair<String,Long>?=null
    private val mainObserverDispatcher:CoroutineDispatcher=Dispatchers.Main
    private var submitting=false
    val timeline=graph.timeline.state
    init {
        viewModelScope.launch(mainObserverDispatcher) {
            combine(playback,auth) {p,_ -> Triple(graph.session.version(),p.accountEpoch to p.connection,p.timelineSources())}.distinctUntilChanged().collect {(_,admission,sources) ->
                val scope=graph.session.capture()
                if(scope!=null&&scope.epoch==admission.first&&admission.second==PlaybackProjection.Connection.Connected&&sources!=null)withContext(Dispatchers.IO) {
                    graph.timeline.observe(scope,sources)
                }
            }
        }
        viewModelScope.observeAccountState(graph.session) {observation ->
                val state=observation.state
                mixExchange.retireObsolete()
                if(state is AuthState.SignedIn) {
                    val owner=state.accountId to observation.revision
                    if(loadedAccount!=owner) {loadedAccount=owner;refine(LibraryQuery(),restore=true)}
                } else if(state is AuthState.DeviceOnly) {loadedAccount=null}
                else {loadedAccount=null;graph.retireCatalog()}
        }
    }
    fun submit(email:String,password:String,username:String?) {
        if(submitting)return
        submitting=true
        viewModelScope.launch {
            try {withContext(Dispatchers.IO){graph.api.authenticate(email,password,username)}} finally {submitting=false}
        }
    }
    fun cancelAuth(){graph.session.retire()}
    fun retrySave(){viewModelScope.launch(Dispatchers.IO){graph.session.retrySave()}}
    fun restore(){viewModelScope.launch(Dispatchers.IO){graph.api.restore()}}
    private val onlineRestoreBusy=kotlinx.coroutines.flow.MutableStateFlow<AccountSession.OnlineRestoreTicket?>(null)
    val onlineRestore:kotlinx.coroutines.flow.StateFlow<AccountSession.OnlineRestoreTicket?> = onlineRestoreBusy
    fun goOnline(scope:AccountScope){scheduleOnlineRestore(graph.session,graph.api,scope,viewModelScope,onlineRestoreBusy)}
    fun reconnectSaved(){scheduleOnlineRestore(graph.session,graph.api,null,viewModelScope,onlineRestoreBusy)}
    fun useDeviceDownloads(){
        val intent=graph.session.claimDeviceDownloads() ?: return
        viewModelScope.launch(Dispatchers.IO){graph.session.loadDeviceDownloads(intent)}
    }
    fun discardStore(){viewModelScope.launch(Dispatchers.IO){graph.session.discardRejectedStore()}}
    fun logout(clearTemporary:Boolean=false){
        val cacheClear=if(clearTemporary)graph.temporaryAudio.captureClear() else null
        mixExchange.retire()
        val retired=graph.api.revokeLogout()
        graph.presence.retire();graph.jam.retire()
        graph.localUnlock.retire(graph.session.version())
        if(cacheClear!=null)viewModelScope.launch(Dispatchers.IO){graph.temporaryAudio.clear(cacheClear)}
        controller.pause()
        viewModelScope.launch(Dispatchers.IO){graph.api.finishLogout(retired)}
    }
    fun submitImport(view:ImportView,draft:ImportDraft) {
        val receipt=graph.imports.claim(view,draft) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.imports.submit(receipt)}
    }
    fun searchSources(view:com.soundq.android.data.discovery.DiscoveryView,draft:com.soundq.android.data.discovery.DiscoveryDraft) {
        val request=graph.discovery.claimSearch(view,draft) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.discovery.search(request)}
    }
    fun submitSourceImport(view:ImportView,choice:com.soundq.android.data.discovery.SourceChoice) {
        graph.imports.prepareSource(view,choice)
    }
    fun confirmSourceImport(view:ImportView,plan:com.soundq.android.data.imports.ImportSourcePlan) {
        val receipt=graph.imports.claimPlannedSource(view,plan) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.imports.submit(receipt)}
    }
    fun recoverSourceImport(view:ImportView,receipt:com.soundq.android.data.discovery.SourceImportReceipt) {viewModelScope.launch(Dispatchers.IO){graph.imports.recoverSource(view,receipt)}}
    fun retrySourceImport(view:ImportView,receipt:com.soundq.android.data.discovery.SourceImportReceipt) {viewModelScope.launch(Dispatchers.IO){graph.imports.retrySource(view,receipt)}}
    fun recoverDurableImport(view:ImportView,receipt:com.soundq.android.data.acquisition.IntakeReceipt){viewModelScope.launch(Dispatchers.IO){graph.imports.recoverDurable(view,receipt)}}
    fun retryDurablePublication(view:ImportView,receipt:com.soundq.android.data.acquisition.IntakeReceipt){viewModelScope.launch(Dispatchers.IO){graph.imports.retryDurablePublication(view,receipt)}}
    fun checkImport(view:ImportView){viewModelScope.launch(Dispatchers.IO){graph.imports.check(view)}}
    fun recentImports(view:ImportView){viewModelScope.launch(Dispatchers.IO){graph.imports.recent(view)}}
    fun openImportLibrary(view:ImportView,onOpened:(TrackId)->Unit) {
        val selected=imports.value.selected ?: return
        val track=selected.track ?: return
        viewModelScope.launch {
            val accepted=withContext(Dispatchers.IO){graph.imports.openLibrary(view,selected)}
            if(accepted && graph.imports.current(view) && imports.value.selected===selected)onOpened(track)
        }
    }
    fun refine(query:LibraryQuery,restore:Boolean=false){
        val request=graph.library.claimRefinement(query,restore) ?: return
        viewModelScope.launch(Dispatchers.IO){graph.library.executeRefinement(request)}
    }
    fun playLibraryCollection(expected:LibraryState,shuffle:Boolean=false,selected:TrackId?=null,current:()->Boolean) {
        val request=graph.library.claimCollectionPlay(expected,selected,shuffle,current) ?: return
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO){graph.library.readCollection(request)}
                graph.library.startCollection(request) {tracks,index->
                    when {
                        !com.soundq.android.playback.QueuePolicy.acceptsContext(tracks.size)->"This collection exceeds the current playback capacity. Nothing was started."
                        playback.value.connection!=PlaybackProjection.Connection.Connected->"Player is not connected. Try again."
                        else->{graph.rememberTracks(tracks);controller.playContext(tracks,index);null}
                    }
                }
            }finally {graph.library.abandonCollection(request)}
        }.invokeOnCompletion {graph.library.abandonCollection(request)}
    }
    fun loadMore(){viewModelScope.launch(Dispatchers.IO){graph.library.loadMore()}}
    fun loadMore(expected:LibraryState,current:()->Boolean) {
        val request=graph.library.claimNextPage(expected,current) ?: return
        viewModelScope.launch(Dispatchers.IO) {
            try {graph.library.executeNextPage(request)}
            finally {graph.library.abandonNextPage(request)}
        }.invokeOnCompletion {graph.library.abandonNextPage(request)}
    }
    fun retryLibraryPage(expected:LibraryState,current:()->Boolean) {
        val request=graph.library.claimPageRetry(expected,current) ?: return
        viewModelScope.launch(Dispatchers.IO) {
            try {graph.library.executeNextPage(request)}finally {graph.library.abandonNextPage(request)}
        }.invokeOnCompletion {graph.library.abandonNextPage(request)}
    }
    fun like(track:Track){viewModelScope.launch(Dispatchers.IO){graph.library.like(track)}}
    fun play(index:Int, expectedRows:List<Track> = library.value.rows){
        graph.library.playAction(expectedRows,index) {tracks,selected->
            graph.rememberTracks(tracks);controller.playContext(tracks,selected)
        }()
    }
    /** Library row intent uses its original acknowledged account/query, never a fresh session. */
    fun likeLibrary(capture:com.soundq.android.data.playlists.LibraryTrackCapture,valid:()->Boolean):Boolean {
        if(!valid()||!graph.library.owns(capture))return false
        val offer=graph.library.offerLike(capture.scope,capture.track.id) ?: return false
        val receipt=graph.library.claimLike(offer) ?: return false
        viewModelScope.launch(Dispatchers.IO) {
            try {if(valid()&&graph.library.owns(capture))graph.library.executeLike(receipt)}
            finally {graph.library.abandonLike(receipt)}
        }.invokeOnCompletion {graph.library.abandonLike(receipt)}
        return true
    }
    /** True means admitted, not an acknowledged queue effect. MediaController remains sole writer. */
    fun enqueueLibrary(capture:com.soundq.android.data.playlists.LibraryTrackCapture,valid:()->Boolean,next:Boolean=false):Boolean {
        if(!valid()||!graph.library.owns(capture))return false
        graph.rememberTracks(listOf(capture.track))
        if(!valid()||!graph.library.owns(capture))return false
        controller.enqueue(capture.track,next)
        return true
    }
    fun quickQueueLibrary(capture:com.soundq.android.data.playlists.LibraryTrackCapture,valid:()->Boolean):Boolean =
        enqueueLibrary(capture,valid,graph.swipeQueuePreferences.state.value.mode==com.soundq.android.data.preferences.SwipeQueue.PlayNext)
    fun quickQueuePlaylist(capture:com.soundq.android.data.playlists.PlaylistPlaybackCapture,index:Int,track:Track,valid:()->Boolean):Boolean {
        if(!valid())return false
        return graph.playlistDetail.queue(capture,index,track) {original->
            if(valid()) {graph.rememberTracks(listOf(original));controller.enqueue(original,graph.swipeQueuePreferences.state.value.mode==com.soundq.android.data.preferences.SwipeQueue.PlayNext)}
        }
    }
    fun homeQueue(route:com.soundq.android.data.home.HomeRoute,section:com.soundq.android.data.home.HomeSection,rows:Any,entry:com.soundq.android.data.home.HomeEntry,eventId:Long?=null):()->Unit =
        home.queueAction(route,section,rows,entry,eventId) {original->graph.rememberTracks(listOf(original));controller.enqueue(original,graph.swipeQueuePreferences.state.value.mode==com.soundq.android.data.preferences.SwipeQueue.PlayNext)}
    fun enqueue(track:Track,next:Boolean){if(graph.session.capture()==null||library.value.rows.none {it===track})return;graph.rememberTracks(listOf(track));controller.enqueue(track,next)}
    fun loadHome(route:com.soundq.android.data.home.HomeRoute,section:com.soundq.android.data.home.HomeSection,expected:Any?=null,append:Boolean=false,query:com.soundq.android.data.home.HistoryQuery?=null) {
        if(section==com.soundq.android.data.home.HomeSection.History) {
            val request=home.claimHistory(route,expected as? com.soundq.android.data.home.HistoryReadState,append,query) ?: return
            viewModelScope.launch(Dispatchers.IO) {
                try {home.executeHistory(request)}finally {home.abandonHistory(request)}
            }.invokeOnCompletion {home.abandonHistory(request)}
        } else viewModelScope.launch(Dispatchers.IO){home.load(route,section,expected,append)}
    }
    fun homePlay(route:com.soundq.android.data.home.HomeRoute,section:com.soundq.android.data.home.HomeSection,rows:Any,entry:com.soundq.android.data.home.HomeEntry,eventId:Long?=null):()->Unit =
        home.playAction(route,section,rows,entry,eventId) {tracks,index -> graph.rememberTracks(tracks);controller.playContext(tracks,index)}
    override fun onCleared(){mixExchange.retire();super.onCleared()}
}
