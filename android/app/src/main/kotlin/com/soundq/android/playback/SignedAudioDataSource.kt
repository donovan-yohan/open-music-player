package com.soundq.android.playback

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.*
import androidx.media3.datasource.okhttp.OkHttpDataSource
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import java.util.concurrent.ConcurrentHashMap

internal class MediaGrant private constructor(private val serverScope:AccountScope?,private val serverTrack:TrackId?,val localOnly:Boolean,val device:PlaybackRef.Device?,val version:Long,val audioRevision:Long) {
    constructor(scope:AccountScope,track:TrackId,localOnly:Boolean=false):this(scope,track,localOnly,null,scope.owner.version(),0)
    constructor(device:PlaybackRef.Device,version:Long,audioRevision:Long):this(null,null,true,device,version,audioRevision)
    @Volatile var phoneAdmission:com.soundq.android.data.device.PhoneSourceAdmission?=null
    val scope:AccountScope get()=requireNotNull(serverScope) { "Phone audio has no server scope" }
    val track:TrackId get()=requireNotNull(serverTrack) { "Phone audio has no server TrackId" }
    fun current(graph:AppGraph):Boolean=if(device==null)graph.session.current(scope) else graph.phoneAudio.current(version)&&graph.phoneAudio.authorityVersion==audioRevision&&graph.phoneAudio.observed(device)!=null
}
/** Runs on ExoPlayer's loader, not its application looper. Internal URIs never reach the network. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class SignedAudioDataSource(private val graph:AppGraph,private val grants:ConcurrentHashMap<String,MediaGrant>) : DataSource {
    private var upstream:DataSource?=null
    private var local:com.soundq.android.data.offline.LocalAudioLease?=null
    private var writing:com.soundq.android.data.cache.TemporaryAudioCache.Write?=null
    private var expectedCacheBytes=0L
    private var readCacheBytes=0L
    private var remaining=0L
    private var grant:MediaGrant?=null
    private var internalUri:Uri?=null
    private val listeners=mutableListOf<TransferListener>()
    private fun checkCurrent(permit:MediaGrant) {
        graph.session.checkScope(permit.scope)
        if(grants[internalUri.toString()]!==permit)throw SafeFailure(SafeFailure.Reason.Retired)
    }
    override fun addTransferListener(listener:TransferListener) {listeners.add(listener)}
    override fun open(dataSpec:DataSpec):Long {
        val uri=dataSpec.uri
        require(uri.scheme=="soundq" && dataSpec.httpRequestHeaders.keys.none {it.equals("Authorization",true)})
        val permit=grants[uri.toString()] ?: throw SafeFailure(SafeFailure.Reason.Retired)
        grant=permit;internalUri=uri
        graph.session.checkScope(permit.scope)
        graph.downloads.load(permit.scope)
        graph.downloads.acquire(permit.scope,permit.track)?.let {lease ->
            try {
                if(grants[uri.toString()]!==permit)throw SafeFailure(SafeFailure.Reason.Retired)
                lease.seek(dataSpec.position)
                remaining=if(dataSpec.length==C.LENGTH_UNSET.toLong())lease.size-dataSpec.position else minOf(dataSpec.length,lease.size-dataSpec.position)
                local=lease
                return remaining
            } catch(error:Exception){lease.close();throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
        }
        // Explicit device copies retain precedence. Temporary bytes never satisfy explicit local-only intent.
        if(!permit.localOnly&&graph.session.remoteCurrent(permit.scope)&&graph.storagePreferences.state.value.temporaryAudioEnabled)graph.temporaryAudio.acquire(permit.scope,permit.track)?.let {lease ->
            try {lease.seek(dataSpec.position);remaining=if(dataSpec.length==C.LENGTH_UNSET.toLong())lease.size-dataSpec.position else minOf(dataSpec.length,lease.size-dataSpec.position);local=lease;return remaining}
            catch(_:Exception){lease.close()}
        }
        // A local miss is terminal in device-only scope, never descriptor/network fallback.
        if(permit.localOnly||!graph.session.remoteCurrent(permit.scope))throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        for(attempt in 0..1) {
            graph.session.checkRemote(permit.scope)
            val descriptor=graph.api.descriptor(permit.scope,permit.track)
            if(grants[uri.toString()]!==permit) throw SafeFailure(SafeFailure.Reason.Retired)
            graph.session.checkRemote(permit.scope)
            val scopedMedia=graph.mediaClient.newBuilder().addNetworkInterceptor {chain ->
                graph.session.checkRemote(permit.scope)
                if(grants[uri.toString()]!==permit)throw SafeFailure(SafeFailure.Reason.Retired)
                require(chain.request().header("Authorization")==null)
                chain.proceed(chain.request())
            }.build()
            val source=OkHttpDataSource.Factory(scopedMedia).createDataSource()
            listeners.forEach(source::addTransferListener)
            upstream=source
            try {
                // withUri preserves position/length/flags => native Range and seek offset remain intact.
                val opened=source.open(dataSpec.withUri(Uri.parse(descriptor.url)).withRequestHeaders(emptyMap()))
                val size=descriptor.sizeBytes
                if(dataSpec.position==0L&&dataSpec.length==C.LENGTH_UNSET.toLong()&&size!=null&&opened==size&&graph.storagePreferences.state.value.temporaryAudioEnabled) {
                    writing=graph.temporaryAudio.begin(permit.scope,permit.track,size);expectedCacheBytes=size;readCacheBytes=0
                }
                return opened
            } catch(e:HttpDataSource.InvalidResponseCodeException) {
                source.close();upstream=null
                if(attempt==0 && e.responseCode in listOf(401,403)) continue
                throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            } catch(_:Exception) {source.close();upstream=null;throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
        }
        throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
    }
    override fun read(buffer:ByteArray,offset:Int,length:Int):Int {
        val permit=grant ?: throw SafeFailure(SafeFailure.Reason.Retired)
        checkCurrent(permit)
        if(length==0)return 0
        local?.let {lease ->
            if(remaining==0L)return C.RESULT_END_OF_INPUT
            return try {lease.read(buffer,offset,minOf(length.toLong(),remaining).toInt()).also {checkCurrent(permit);if(it>0)remaining-=it}}
            catch(error:SafeFailure){throw error}
            catch(_:Exception){throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
        }
        return try {
            val n=upstream?.read(buffer,offset,length) ?: C.RESULT_END_OF_INPUT
            checkCurrent(permit)
            writing?.let {stage ->
                try {
                    check(graph.storagePreferences.state.value.temporaryAudioEnabled)
                    if(n>0){stage.append(buffer,offset,n);readCacheBytes+=n}
                    if(n==C.RESULT_END_OF_INPUT||readCacheBytes==expectedCacheBytes){if(readCacheBytes==expectedCacheBytes)stage.finish() else stage.close();writing=null}
                }catch(_:Exception){stage.close();writing=null} // Cache failure must not fail listening.
            }
            n
        } catch(error:SafeFailure) {writing?.close();writing=null;throw error}
        catch(_:Exception) {writing?.close();writing=null;throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
    }
    override fun getUri():Uri?=internalUri // never publish signed URL to analytics/controllers
    override fun close() {try {upstream?.close()} finally {try {local?.close();writing?.close()} finally {writing=null;local=null;upstream=null;grant=null;internalUri=null;remaining=0;expectedCacheBytes=0;readCacheBytes=0}}}
}
