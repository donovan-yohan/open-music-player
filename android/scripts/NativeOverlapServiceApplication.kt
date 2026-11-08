package com.soundq.android.playback.nativeengine
import com.soundq.android.SoundQApplication
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import kotlinx.coroutines.CoroutineScope
import java.io.File
internal class NativeOverlapServiceApplication:SoundQApplication() {
    val hardware=NativeArrangementPlayerTest.Hardware()
    override fun onCreate() {
        graph=AppGraph(this,ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        })
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture","fixture","fixture")))
    }
    override fun createCallbackLibraryPlayer(grants:java.util.concurrent.ConcurrentHashMap<String,com.soundq.android.playback.MediaGrant>,jobs:CoroutineScope):androidx.media3.common.Player = NativeCallbackPlayer(graph,grants,jobs,hardware,NativeCallbackSource {item,current->check(current());File(graph.directory,item.mediaId+".encoded").apply{writeBytes(byteArrayOf(1,2,3))}})
}
