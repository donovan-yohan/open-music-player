package com.soundq.android

import android.content.ComponentName
import android.content.ContentValues
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.SystemClock
import android.provider.MediaStore
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.media3.common.MediaItem
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionToken
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.playback.*
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.random.Random

/** CallbackFrontendFixtureRunner only. Unanalysed phone files -> real provider/repository ->
 * canonical service -> real native callback engine. Rates are measured from the native
 * source cursor (not controller extrapolation). Emulator evidence: not acoustic quality. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class PlaybackSpeedJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private val app get()=context.applicationContext as CallbackFrontendFixtureApplication
    private val owned=mutableListOf<Uri>()
    private var future:com.google.common.util.concurrent.ListenableFuture<MediaController>?=null
    private lateinit var c:MediaController

    private fun <T> main(block:()->T):T {var result:Result<T>?=null;instrumentation.runOnMainSync {result=runCatching(block)};return result!!.getOrThrow()}
    private fun await(message:String,seconds:Long=30,ready:()->Boolean) {
        val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(seconds)
        while(System.nanoTime()<deadline){if(ready())return;Thread.sleep(20)}
        assertTrue(message,ready())
    }
    private fun native():JSONObject {
        val method=app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}
        return JSONObject(method.invoke(app.callbackPlayer) as String)
    }
    /** The ordinary deck currently assigned to the selected occurrence's source. */
    private fun deck():JSONObject? {
        val decks=native().getJSONArray("decks")
        val assigned=(0 until decks.length()).map {decks.getJSONObject(it)}.filter {it.getLong("identity")!=0L&&it.getBoolean("ready")}
        return assigned.firstOrNull {it.getBoolean("playing")} ?: assigned.firstOrNull()
    }
    private fun decksSummary():String {
        val decks=native().getJSONArray("decks")
        return (0 until decks.length()).map {decks.getJSONObject(it)}.filter {it.getLong("identity")!=0L}
            .joinToString(";") {"id=${it.getLong("identity")} ready=${it.getBoolean("ready")} playing=${it.getBoolean("playing")} pos=${it.getLong("positionMs")} rate=${it.getDouble("rate")}"}
    }
    /** After a selection change the retiring deck can stay assigned for a few blocks; wait
     * until one playing assignment is stable before measuring the new occurrence. */
    private fun awaitSettledDeck(message:String) {
        var last=-1L;var stable=0
        await(message) {
            val d=deck()?.takeIf {it.getBoolean("playing")}
            val id=d?.getLong("identity") ?: -1L
            if(id!=last) {println("SPEED_EVIDENCE decks while settling: ${decksSummary()}");last=id;stable=0} else if(id>0)stable++
            Thread.sleep(100)
            stable>=5
        }
    }
    /** Playing ordinary deck plus the output clock, from ONE native snapshot. Selected by
     * assignment, not by the momentary `ready` coverage flag, which can flap during a
     * refill (observed at 1x too) while the cursor and its PCM stay valid. */
    private fun clocked():Pair<JSONObject,JSONObject> {
        val root=native();val decks=root.getJSONArray("decks")
        val assigned=(0 until decks.length()).map {decks.getJSONObject(it)}.filter {it.getLong("identity")!=0L}
        return root to checkNotNull(assigned.firstOrNull {it.getBoolean("playing")} ?: assigned.firstOrNull {it.getBoolean("ready")}) {"no assigned deck"}
    }
    /** Source seconds advanced per OUTPUT second, from native acknowledgements only. Both
     * cursors come from the same snapshot as the engine's rendered-frame clock, so the
     * 50 ms diagnostics poll and host scheduling cannot skew the ratio; a PCM stall still
     * lowers it (the cursor holds while output frames render). Wall pace is logged too. */
    private fun measuredRate(wallMs:Long=3000):Double {
        val (r0,a)=clocked();val t0=SystemClock.elapsedRealtime()
        Thread.sleep(wallMs)
        val (r1,b)=clocked();val t1=SystemClock.elapsedRealtime()
        assertEquals("same assignment",a.getLong("identity"),b.getLong("identity"))
        val source=(b.getDouble("sourceFrame")-a.getDouble("sourceFrame"))/b.getDouble("sourceRate")
        val output=(r1.getLong("renderedFrames")-r0.getLong("renderedFrames")).toDouble()/r1.getLong("sampleRate")
        assertTrue("output clock advanced",output>wallMs/2000.0)
        val rate=source/output
        println("SPEED_EVIDENCE measured id=${a.getLong("identity")} pos ${a.getLong("positionMs")}->${b.getLong("positionMs")} "+
            "output ${"%.3f".format(output)}s wall ${t1-t0}ms wallRate=${source*1000.0/(t1-t0)} "+
            "missingPcm ${a.getLong("missingPcmFrames")}->${b.getLong("missingPcmFrames")} rate=$rate")
        // The output clock really runs at wall pace (coarse: the poll is up to 50 ms stale).
        assertEquals("wall pace follows the output clock",rate,source*1000.0/(t1-t0),rate*0.15)
        return rate
    }
    private fun speedState():ListeningSpeedState? = main {c.sessionExtras.getString(LISTENING_SPEED_STATE)}?.let {Json.decodeFromString<ListeningSpeedState>(it)}
    private fun setSpeed(occurrence:String,speed:Double):Int {
        val result=main {c.sendCustomCommand(SessionCommand(SET_LISTENING_SPEED,Bundle.EMPTY),Bundle().apply {putString("occurrence",occurrence);putDouble("speed",speed)})}
        return result.get(15,TimeUnit.SECONDS).resultCode
    }
    private fun prefs()=ListeningSpeedPreferences(java.io.File(app.graph.directory,"listening-speed.json"))
    private fun current()=main {c.currentMediaItem!!.mediaId}

    @Before fun connect() {
        main {app.graph.session.retire()}
        await("Accepted signed-out local catalog") {app.graph.session.state.value is AuthState.SignedOut&&app.graph.phoneAudio.state.value.ready}
        future=main {MediaController.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).buildAsync()}
        c=requireNotNull(future).get(15,TimeUnit.SECONDS)
    }
    @After fun cleanup() {
        runCatching {main {c.pause();c.stop();c.clearMediaItems()}}
        future?.let {f->main {MediaController.releaseFuture(f)}}
        owned.forEach {uri->assertEquals("Delete only test-owned MediaStore items",1,context.contentResolver.delete(uri,null,null))}
    }
    /** Unique bytes each run, so a previous run's per-track preference never applies. */
    private fun phoneFile(seconds:Int,frequency:Int):PlaybackRef.Device {
        val version=app.graph.session.version()
        // 64 random bits in the final samples: content (and so the preference key) is unique per run.
        val rate=16000;val frames=rate*seconds;val bytes=frames*2;val salt=Random.nextLong()
        val wave=ByteBuffer.allocate(44+bytes).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36+bytes).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(bytes)
            repeat(frames){i->val tail=frames-1-i
                putShort(if(tail<4)(salt ushr (16*tail)).toShort() else (kotlin.math.sin(i*2*Math.PI*frequency/rate)*4000).toInt().toShort())}
        }.array()
        val values=ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-speed-${UUID.randomUUID()}.wav")
            put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }
        val resolver=context.contentResolver
        val uri=checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values)).also(owned::add)
        resolver.openOutputStream(uri,"w")!!.use {it.write(wave)}
        resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)
        val row=app.graph.phoneAudio.awaitIndexed(uri,{app.graph.session.owns(version)})
        return app.graph.phoneAudio.reference(row)
    }
    private fun request(ref:PlaybackRef.Device)=MediaItem.Builder().setMediaId("device:${ref.id}")
        .setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply {putString("playbackRef",ref.wire())}).build()).build()
    private fun playQueue(vararg refs:PlaybackRef.Device) {
        main {c.setMediaItems(refs.map(::request),0,0);c.prepare();c.play()}
        await("Real native source advancement") {main {c.isPlaying&&c.duration>0}&&(deck()?.getLong("positionMs") ?: 0)>200}
    }

    @Test fun unanalysedLocalFileChangesNativeRateFromNowPlayingWithSeekBoundsAndReset() {
        val a=phoneFile(40,223);val b=phoneFile(10,557)
        playQueue(a,b)
        val occurrence=current()
        val initial=speedState()!!
        assertEquals(occurrence,initial.occurrence);assertEquals(1.0,initial.accepted,0.0);assertNull(initial.unavailable)
        assertEquals(0.5,initial.min,0.0);assertEquals(2.0,initial.max,0.0)
        val duration=main {c.duration}
        // Ordinary user path: compact player -> Now playing -> speed cell -> 1.5x shortcut.
        compose.onNode(hasClickAction() and SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Playing")).performClick()
        compose.onNodeWithTag("player-speed-cell").assertIsDisplayed().performClick()
        compose.onNodeWithTag("player-speed-panel").assertIsDisplayed()
        compose.onNodeWithTag("player-speed-shortcut-1.5x").performClick()
        await("Accepted 1.5x from native receipt") {speedState()?.accepted==1.5}
        compose.waitUntil(5000) {compose.onAllNodesWithText("1.5x").fetchSemanticsNodes().size>=2}
        compose.onNodeWithTag("player-speed-accepted").assertTextEquals("1.5x")
        assertEquals(1.5f,main {c.playbackParameters.speed})
        assertEquals("speed is not a BPM/analysis edit; duration stays source time",duration,main {c.duration})
        val d=deck()!!;assertEquals(1.5,d.getDouble("rate"),0.0);assertEquals(1.5,d.getDouble("speed"),0.0)
        val fast=measuredRate();println("SPEED_EVIDENCE rate@1.5=$fast")
        assertTrue("native source cursor advances at 1.5x, was $fast",fast in 1.38..1.62)
        captureListeningStage("speed-product-accepted-1-5")
        // Seek at non-1x lands in original source coordinates and keeps the pace.
        main {c.seekTo(20_000)}
        await("Native seek acknowledgement") {deck()?.let {it.getLong("positionMs") in 19_800..20_900&&it.getBoolean("playing")}==true}
        val afterSeek=measuredRate(2000);println("SPEED_EVIDENCE rate@1.5 after seek=$afterSeek")
        assertTrue(afterSeek in 1.38..1.62)
        // Engine bounds: 2.0x and 0.5x keep coverage (no missing PCM) on this emulator.
        assertEquals(SessionResult.RESULT_SUCCESS,setSpeed(occurrence,2.0))
        val missing=deck()!!.getLong("missingPcmFrames")
        val double=measuredRate();println("SPEED_EVIDENCE rate@2.0=$double")
        assertTrue(double in 1.84..2.16)
        assertEquals("2x refills keep ahead of the cursor",missing,deck()!!.getLong("missingPcmFrames"))
        main {c.seekTo(5_000)}
        await("Native seek") {deck()?.let {it.getLong("positionMs") in 4_800..5_900&&it.getBoolean("playing")}==true}
        assertEquals(SessionResult.RESULT_SUCCESS,setSpeed(occurrence,0.5))
        val slow=measuredRate();println("SPEED_EVIDENCE rate@0.5=$slow")
        assertTrue(slow in 0.44..0.56)
        assertNotEquals(SessionResult.RESULT_SUCCESS,setSpeed(occurrence,2.5))
        assertEquals(0.5,speedState()!!.accepted,0.0)
        // Reset is the visible 1.0x shortcut; it clears this track's preference.
        compose.onNodeWithContentDescription("Normal speed, 1 times. Resets this track").performClick()
        await("Reset accepted") {speedState()?.accepted==1.0}
        val normal=measuredRate();println("SPEED_EVIDENCE rate@1.0 after reset=$normal")
        assertTrue(normal in 0.92..1.08)
        assertNull(prefs().speed(ListeningSpeedKey.device(a)))
        assertEquals(duration,main {c.duration})
    }

    @Test fun trackIsolationPendingRetirementAndPerTrackPersistence() {
        val a=phoneFile(30,223);val b=phoneFile(30,557)
        playQueue(a,b)
        val first=current()
        assertEquals(SessionResult.RESULT_SUCCESS,setSpeed(first,1.5))
        assertEquals(1.5,prefs().speed(ListeningSpeedKey.device(a))!!,0.0)
        main {c.seekToNextMediaItem()}
        await("B selected and advancing") {current()!=first&&deck()?.getBoolean("playing")==true}
        awaitSettledDeck("B assignment settled")
        val second=current()
        assertEquals("never-configured B starts normal",1.0,speedState()!!.accepted,0.0)
        val bRate=measuredRate(2000);println("SPEED_EVIDENCE B rate=$bRate")
        assertTrue(bRate in 0.92..1.08)
        // A request captured for A cannot change B.
        assertNotEquals(SessionResult.RESULT_SUCCESS,setSpeed(first,1.25))
        assertEquals(1.0,deck()!!.getDouble("rate"),0.0)
        // An in-flight request for B is retired by a selection change before acceptance;
        // it never applies to A. If the receipt raced ahead it is B's, never A's.
        val pending=main {
            val f=c.sendCustomCommand(SessionCommand(SET_LISTENING_SPEED,Bundle.EMPTY),Bundle().apply {putString("occurrence",second);putDouble("speed",1.25)})
            c.seekToPreviousMediaItem();f
        }
        val code=pending.get(15,TimeUnit.SECONDS).resultCode
        await("A selected and advancing") {current()==first&&deck()?.getBoolean("playing")==true}
        awaitSettledDeck("A assignment settled")
        println("SPEED_EVIDENCE in-flight retirement result=$code")
        assertEquals("A restores its own accepted speed",1.5,speedState()!!.accepted,0.0)
        val restored=measuredRate(2000);println("SPEED_EVIDENCE A restored rate=$restored")
        assertTrue(restored in 1.38..1.62)
        assertEquals(1.5,prefs().speed(ListeningSpeedKey.device(a))!!,0.0)
        if(code!=SessionResult.RESULT_SUCCESS)assertNull(prefs().speed(ListeningSpeedKey.device(b)))
        else assertEquals(1.25,prefs().speed(ListeningSpeedKey.device(b))!!,0.0)
        assertEquals(SessionResult.RESULT_SUCCESS,setSpeed(first,1.0))
        assertNull(prefs().speed(ListeningSpeedKey.device(a)))
    }

    @Test fun naturalCompletionExactlyOnceAtNonNormalSpeed() {
        val short=phoneFile(8,223);val next=phoneFile(20,557)
        val completions=java.util.concurrent.ConcurrentHashMap<String,Int>()
        val listener:(MediaItem)->Unit={item->completions.merge(item.mediaId,1,Int::plus)}
        main {(app.callbackPlayer as com.soundq.android.playback.listening.ListeningCompletionPlayer).addCompletionListener(listener)}
        try {
            playQueue(short,next)
            val first=current()
            assertEquals(SessionResult.RESULT_SUCCESS,setSpeed(first,1.5))
            main {c.seekTo(5_000)}
            await("Seek acknowledged") {deck()?.getLong("positionMs")?.let {it in 4_800..6_500}==true}
            val start=SystemClock.elapsedRealtime()
            await("Natural advance to the next track",20) {current()!=first}
            println("SPEED_EVIDENCE remaining 3s source at 1.5x took ${SystemClock.elapsedRealtime()-start}ms wall")
            await("Successor advancing") {deck()?.getBoolean("playing")==true&&deck()!!.getLong("positionMs")>300}
            Thread.sleep(1500)
            assertEquals("exactly one completion of the 1.5x occurrence",1,completions[first])
            assertEquals("next track is never-configured: normal",1.0,speedState()!!.accepted,0.0)
            assertNotEquals("no tail replay",first,current())
        } finally {
            main {(app.callbackPlayer as com.soundq.android.playback.listening.ListeningCompletionPlayer).removeCompletionListener(listener)}
        }
    }
}
