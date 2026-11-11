package com.soundq.android.playback

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.media3.common.util.BitmapLoader
import com.google.common.util.concurrent.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import okhttp3.Request
import java.util.concurrent.Executors

/** Explicit no-bearer artwork loader. Scope checked before egress and decoded publication. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ScopedArtworkLoader(private val graph:AppGraph):BitmapLoader,AutoCloseable {
    private val executor=MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor())
    override fun supportsMimeType(mimeType:String)=mimeType.startsWith("image/")
    override fun decodeBitmap(data:ByteArray):ListenableFuture<Bitmap> = executor.submit<Bitmap> {decode(data)}
    override fun loadBitmap(uri:Uri):ListenableFuture<Bitmap> {
        val scope=graph.session.capture() ?: return Futures.immediateFailedFuture(SafeFailure(SafeFailure.Reason.Retired))
        return executor.submit<Bitmap> {
            graph.session.checkRemote(scope)
            if(!SoundQApi.safeMediaUrl(uri.toString()))throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            try {
                graph.mediaClient.newBuilder().addNetworkInterceptor {chain ->graph.session.checkRemote(scope);require(chain.request().header("Authorization")==null);chain.proceed(chain.request())}.build().newCall(Request.Builder().url(uri.toString()).build()).execute().use {response ->
                    if(!response.isSuccessful||response.body.source().request(4_000_001))throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                    val bitmap=decode(response.body.bytes());graph.session.checkRemote(scope);bitmap
                }
            } catch(error:SafeFailure) {throw error} catch(_:Exception) {throw SafeFailure(SafeFailure.Reason.AudioUnavailable)}
        }
    }
    private fun decode(data:ByteArray):Bitmap {
        if(data.size>4_000_000)throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        val options=BitmapFactory.Options().apply {inJustDecodeBounds=true}
        BitmapFactory.decodeByteArray(data,0,data.size,options)
        if(options.outWidth<=0||options.outHeight<=0)throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        options.inJustDecodeBounds=false;options.inSampleSize=1
        while(options.outWidth/options.inSampleSize>1024||options.outHeight/options.inSampleSize>1024)options.inSampleSize*=2
        return BitmapFactory.decodeByteArray(data,0,data.size,options) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
    }
    override fun close(){executor.shutdownNow()}
}
