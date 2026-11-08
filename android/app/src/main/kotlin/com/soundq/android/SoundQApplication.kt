package com.soundq.android

import android.app.Application
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.soundq.android.data.*
import kotlinx.coroutines.*
import okhttp3.OkHttpClient
import java.io.File
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

open class SoundQApplication : Application() {
    lateinit var graph: AppGraph
        internal set
    override fun onCreate() {
        super.onCreate()
        graph = createGraph()
        graph.start()
    }
    /** The service owns one callback backend. Legacy output fixtures use the factory below. */
    internal open fun createCallbackLibraryPlayer(
        grants: java.util.concurrent.ConcurrentHashMap<String, com.soundq.android.playback.MediaGrant>,
        jobs: CoroutineScope,
    ): androidx.media3.common.Player = com.soundq.android.playback.nativeengine.NativeCallbackPlayer(graph, grants, jobs)

    /** Construction-only legacy fixture seam. Never selected by the production service. */
    internal open fun createLibraryPlayer(
        output: androidx.media3.exoplayer.ExoPlayer,
        grants: java.util.concurrent.ConcurrentHashMap<String, com.soundq.android.playback.MediaGrant>,
        jobs: CoroutineScope,
    ): androidx.media3.common.Player = com.soundq.android.playback.ServiceQueuePlayer(output)

    protected open fun createGraph(): AppGraph = AppGraph(this, ApiEndpoint.parse(BuildConfig.OMP_API_BASE_URL))
}
/** Application composition, not a visual/global playback coordinator. */
class AppGraph(context: Context, val endpoint: ApiEndpoint, apiClient: OkHttpClient = OkHttpClient(), store: SessionStore? = null, val mediaClient: OkHttpClient = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()) : AutoCloseable {
    internal val applicationContext: Context = context.applicationContext
    val directory=File(context.noBackupFilesDir.canonicalFile,"soundq").apply {mkdirs()}
    internal val contextStarts=com.soundq.android.playback.ContextStartAdmission(File(directory,"context-starts"))
    val queueSettings=QueueSettingsRepository(FileQueuePreferencesStore(File(directory,"queue-settings.v1.json")))
    val session=AccountSession(endpoint,store ?: EncryptedSessionStore(File(directory,"session.v1"),::keystoreKey))
    val appearancePreferences=com.soundq.android.data.preferences.AppearancePreferences(File(directory,"appearance.v1.json"))
    val djModePreferences=com.soundq.android.data.preferences.DjModePreferences(File(directory,"dj-mode.v1.json"))
    val keyNotationPreferences=com.soundq.android.data.preferences.KeyNotationPreferences(File(directory,"key-notation.v1.json"))
    val storagePreferences=com.soundq.android.data.preferences.StoragePreferences(File(directory,"storage-preferences.v1.json"))
    val swipeQueuePreferences=com.soundq.android.data.preferences.SwipeQueuePreferences(File(directory,"swipe-queue.v1.json"))
    val listeningPreferences=com.soundq.android.data.preferences.EndOfQueuePreferences(File(directory,"end-of-queue.v1.json"))
    val crossfadePreferences=com.soundq.android.data.preferences.CrossfadePreferences(File(directory,"crossfade.v1.json"))
    val localUnlock=com.soundq.android.localunlock.LocalUnlock(File(directory,"local-unlock.v1.json"),session)
    val temporaryAudio by lazy {com.soundq.android.data.cache.TemporaryAudioCache(File(directory,"temporary-audio"),session)}
    val api=SoundQApi(session,apiClient,com.soundq.android.data.acquisition.IntakeReceipts(File(directory,"intake-receipts.v1.json")))
    val timeline=com.soundq.android.data.timeline.TimelineRepository(session,File(directory,"timeline"),api::analysisWaveform)
    val arrangementSave=com.soundq.android.data.timeline.ArrangementSave(api,timeline)
    val library=LibraryRepository(session,api::library,api::like,LibrarySortStore(File(directory,"library-sort")))
    internal val libraryArtwork=com.soundq.android.product.artwork.LibraryArtwork(session,mediaClient)
    val trackDetails=com.soundq.android.data.trackdetails.TrackDetailsRepository(api,library)
    val downloads=com.soundq.android.data.offline.DeviceDownloads(File(directory,"device-downloads"),session,api,mediaClient)
    val playlists=com.soundq.android.data.playlists.PlaylistRepository(api)
    val playlistDetail=com.soundq.android.data.playlists.PlaylistDetailRepository(api)
    val playlistBlend=com.soundq.android.data.playlists.PlaylistBlendRepository(api,playlistDetail,downloads)
    val playlistOrder=com.soundq.android.data.playlists.PlaylistOrderRepository(api,playlistDetail)
    val queuePlaylist=com.soundq.android.data.playlists.QueuePlaylistRepository(api)
    val playlistManagement=com.soundq.android.data.playlists.PlaylistManagementRepository(api,playlistDetail)
    val harmonic=com.soundq.android.data.harmonic.HarmonicRepository(api,playlistDetail,djModePreferences)
    val playlistMembership=com.soundq.android.data.playlists.PlaylistMembershipRepository(api,library)
    val home=com.soundq.android.data.home.HomeFeedRepository(session,api)
    val acquisition=com.soundq.android.data.acquisition.AcquisitionRepository(session,api)
    val incomingShares=com.soundq.android.data.acquisition.IncomingShares(File(directory,"incoming-share.v1"))
    val imports=com.soundq.android.data.imports.ImportRepository(session,api,library)
    val catalog=com.soundq.android.data.catalog.CatalogRepository(api,com.soundq.android.data.catalog.CatalogMembershipJournal(File(directory,"catalog-membership.v1.json")))
    val discovery=com.soundq.android.data.discovery.DiscoveryRepository(session,api,historyDirectory=File(directory,"discover-history"))
    val io=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val controllerOwner=lazy {com.soundq.android.playback.ControllerProjection(context)}
    internal val controller by controllerOwner
    private val playerArtworkOwner=lazy {com.soundq.android.product.artwork.SelectedPlayerArtwork(session,mediaClient,controller.state,::track,libraryArtwork,false)}
    internal val playerArtwork by playerArtworkOwner
    val jamAdmission=com.soundq.android.data.jam.JamAdmissionPort(session)
    private val presenceOwner=lazy {com.soundq.android.data.connect.DevicePresence(api,controller.state,io)}
    val presence by presenceOwner
    private val jamOwner=lazy {com.soundq.android.data.jam.JamHostRepository(api,presence,controller.state,jamAdmission,{ticket->controller.sendJamAdmission(ticket){jamAdmission.refused(ticket)}},io,directory)}
    val jam by jamOwner
    private val known=java.util.concurrent.ConcurrentHashMap<TrackId,Pair<AccountScope,Track>>()
    init {localUnlock.loadBeforeRestore()}
    fun start() {presence.start();jam.start();io.launch {appearancePreferences.load();djModePreferences.load();keyNotationPreferences.load();queueSettings.load();storagePreferences.load();listeningPreferences.load();crossfadePreferences.load();swipeQueuePreferences.load();if(session.state.value !is AuthState.LocalLocked)api.restore()};io.launch {session.state.collect {if(it !is AuthState.SignedIn){presence.retire();jam.retire()}}}}
    fun rememberTracks(tracks:List<Track>) {val scope=session.capture() ?: return;tracks.forEach {known[it.id]=scope to it}}
    /** Read existing account-bound acknowledgements only. Restored queue metadata needs no new API fetch. */
    fun track(id:TrackId):Track? {
        val libraryTrack=library.state.value.rows.singleOrNull {it.id==id}?.let {row->
            library.captureTrack(row)?.takeIf {library.owns(it)}?.track
        }
        val playlistTrack=playlistDetail.capturePlayback()?.detail?.tracks?.singleOrNull {it.id==id}
        val remembered=known[id]?.takeIf {session.current(it.first)}?.second
        return libraryTrack ?: playlistTrack ?: remembered
    }
    fun retireCatalog() {retireCatalog(false)}
    internal fun retireCatalogAfterPlaybackAccount() {retireCatalog(true)}
    private fun retireCatalog(preserveCurrentLibrary:Boolean) {contextStarts.retire();harmonic.retire();playlistBlend.retireAccount();timeline.retire();known.clear();trackDetails.retire();downloads.retire();if(preserveCurrentLibrary)library.retireObsolete()else library.retire();playlists.retire();playlistDetail.retire();playlistManagement.retire();playlistOrder.retire();queuePlaylist.retire();playlistMembership.retire();home.retire();imports.retire();discovery.retire();catalog.retire();acquisition.retire()}
    override fun close() {if(playerArtworkOwner.isInitialized())playerArtwork.close();libraryArtwork.close();if(presenceOwner.isInitialized())presence.close();if(jamOwner.isInitialized())jam.close();if(controllerOwner.isInitialized())controller.close();io.cancel();retireCatalog()}
    private fun keystoreKey():SecretKey {
        val store=KeyStore.getInstance("AndroidKeyStore").apply {load(null)}
        val alias="soundq.session.aes.v1"
        (store.getKey(alias,null) as? SecretKey)?.let {return it}
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        }.generateKey()
    }
}
