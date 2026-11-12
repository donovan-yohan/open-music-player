package com.soundq.android

import android.content.ComponentName
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.media3.session.MediaController
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import androidx.media3.session.SessionToken
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.SoundQApi
import com.soundq.android.data.jam.JamHostRepository
import com.soundq.android.data.jam.JamOccurrence
import com.soundq.android.playback.SoundQLibraryService
import com.google.common.util.concurrent.ListenableFuture
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Two-phase owned-fixture protocol. Phase one MUST be externally killed at its
 * declared durable cut; normal completion is a failure, not a simulated restart.
 * Real Go/TLS/service/JNI are retained. Credentials/provider media are synthetic.
 * Never run on a production account, ordinary package or physical phone. */
class NativeJamRecoveryJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val app get()=instrumentation.targetContext.applicationContext as NativeJamBackendApplication
    private val args get()=InstrumentationRegistry.getArguments()
    private val run get()=checkNotNull(args.getString("nativeJamRecoveryRun")).also {require(it.matches(Regex("[A-Za-z0-9_-]{8,80}")))}
    private val cut get()=checkNotNull(args.getString("nativeJamRecoveryCut")).also {require(it in setOf("queue-before-journal","journal-before-dispatch"))}
    private val marker get()=File(instrumentation.targetContext.filesDir,"native-jam-recovery-state.json")
    private fun click(text:String)=compose.onNode(hasText(text) and hasClickAction()).performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
    private fun <T> main(work:()->T):T {
        val result=CompletableFuture<T>()
        Handler(Looper.getMainLooper()).post {try {result.complete(work())}catch(error:Throwable){result.completeExceptionally(error)}}
        return result.get(15,TimeUnit.SECONDS)
    }
    private fun mark(phase:String,extra:JSONObject=JSONObject()) {
        extra.put("phase",phase).put("run",run).put("cut",cut).put("pid",android.os.Process.myPid())
        val stage=File(marker.parentFile,"${marker.name}.stage")
        FileOutputStream(stage).use {it.write(extra.toString().toByteArray());it.fd.sync()}
        Files.move(stage.toPath(),marker.toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
    }
    private fun signIn() {
        require(instrumentation.targetContext.packageName.matches(Regex("com\\.soundq\\.android\\.dev\\.goal[a-z0-9]+")))
        compose.waitUntil(15000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("native-jam@example.invalid")
        compose.onNodeWithContentDescription("Password").performTextInput("fixture-only-password")
        click("Sign in")
        val track=checkNotNull(args.getString("nativeJamHostTrack")).toLong()
        compose.waitUntil(20000){app.graph.session.capture()!=null&&app.graph.library.state.value.rows.any {it.id.value==track}}
    }
    private fun queue():JSONObject=main {
        val player=app.callbackPlayer
        JSONObject().put("rows",JSONArray((0 until player.mediaItemCount).map {index ->
            val item=player.getMediaItemAt(index);val extras=checkNotNull(item.mediaMetadata.extras)
            JSONObject().put("occurrence",item.mediaId).put("track",extras.getLong("trackId"))
                .put("jam",extras.getString("soundqJam") ?: JSONObject.NULL)
        })).put("selected",player.currentMediaItemIndex).put("position",player.currentPosition)
            .put("playing",player.isPlaying).put("playWhenReady",player.playWhenReady)
    }
    private fun sameQueue(expected:JSONObject,actual:JSONObject) {
        val before=expected.getJSONArray("rows");val after=actual.getJSONArray("rows")
        assertEquals(before.length(),after.length())
        for(index in 0 until before.length()) {
            val a=before.getJSONObject(index);val b=after.getJSONObject(index)
            assertEquals(a.getString("occurrence"),b.getString("occurrence"));assertEquals(a.getLong("track"),b.getLong("track"))
            assertEquals(a.optString("jam"),b.optString("jam"))
        }
        assertEquals(expected.getInt("selected"),actual.getInt("selected"))
        assertEquals(expected.getLong("position"),actual.getLong("position"))
        assertFalse(actual.getBoolean("playing"));assertFalse(actual.getBoolean("playWhenReady"))
    }
    private fun awaitQueue(count:Int) {
        compose.waitUntil(15000){runCatching {queue().getJSONArray("rows").length()==count}.getOrDefault(false)}
    }
    @Test fun stopAtDurableAdmissionCutAwaitingExternalProcessKill() {
        run;cut;signIn()
        val hostId=checkNotNull(args.getString("nativeJamHostTrack")).toLong()
        val track=app.graph.library.state.value.rows.single {it.id.value==hostId}
        compose.onNodeWithContentDescription("Library search query").performTextReplacement(track.title)
        compose.onNodeWithContentDescription("Search library").performClick()
        compose.waitUntil(10000){!app.graph.library.state.value.loading&&app.graph.library.state.value.rows.map {it.id.value}==listOf(hostId)}
        val row=hasText(track.title) and hasClickAction() and hasAnyDescendant(hasContentDescription("More for ${track.title}"))
        compose.onNode(row).performScrollTo().performClick()
        compose.waitUntil(20000){main {app.callbackPlayer.isPlaying&&app.callbackPlayer.currentPosition>=300}}
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.waitUntil(10000){!main {app.callbackPlayer.isPlaying||app.callbackPlayer.playWhenReady}}
        val before=queue();assertFalse(before.getBoolean("playing"))
        compose.waitUntil(15000){app.graph.presence.capture()!=null}
        // Retire the application host before installing a single test-owned send
        // collaborator. The production port/service/writer remain unchanged.
        app.graph.jam.close()
        lateinit var connection:ListenableFuture<MediaController>
        instrumentation.runOnMainSync {
            connection=MediaController.Builder(instrumentation.targetContext,SessionToken(instrumentation.targetContext,ComponentName(instrumentation.targetContext,SoundQLibraryService::class.java)))
                .setApplicationLooper(Looper.getMainLooper()).buildAsync()
        }
        val controller=connection.get(15,TimeUnit.SECONDS)
        val requestId=AtomicReference<String>()
        lateinit var host:JamHostRepository
        fun durableCut() {
            val actual=queue();val rows=actual.getJSONArray("rows")
            assertEquals(before.getJSONArray("rows").length()+1,rows.length())
            val matching=(0 until rows.length()).map {rows.getJSONObject(it)}.filter {entry ->
                entry.optString("jam").takeIf {it!="null"&&it.isNotEmpty()}?.let(JamOccurrence::decode)?.requestId==requestId.get()
            }
            assertEquals(1,matching.size);assertEquals(before.getInt("selected"),actual.getInt("selected"))
            assertEquals(before.getLong("position"),actual.getLong("position"));assertFalse(actual.getBoolean("playing"));assertFalse(actual.getBoolean("playWhenReady"))
            mark("kill-ready",JSONObject().put("queue",actual).put("jamId",host.state.value.snapshot!!.id).put("requestId",requestId.get()))
            check(CountDownLatch(1).await(45,TimeUnit.SECONDS)){"Owner did not perform the required external kill"}
            error("A durable-cut phase must not return normally")
        }
        val client=app.fixtureClient.newBuilder().addInterceptor {chain ->
            val request=chain.request()
            if(cut=="journal-before-dispatch"&&request.method=="PUT"&&request.url.encodedPath.endsWith("/requests/${requestId.get()}")) {
                val body=Buffer();request.body?.writeTo(body)
                if(JSONObject(body.readUtf8()).optString("status")=="queued")durableCut()
            }
            chain.proceed(request)
        }.build()
        host=JamHostRepository(SoundQApi(app.graph.session,client),app.graph.presence,app.graph.controller.state,app.graph.jamAdmission,{ticket ->
            val result=main {controller.sendCustomCommand(SessionCommand(SoundQLibraryService.JAM_ADMIT,Bundle.EMPTY),Bundle().apply {putString("ticket",ticket)})}.get(15,TimeUnit.SECONDS)
            assertEquals(SessionResult.RESULT_SUCCESS,result.resultCode)
            if(cut=="queue-before-journal")durableCut()
        },app.graph.io,app.graph.directory)
        val consent=host.open();host.create(consent,listOf(track));host.invite(consent);host.start()
        val party=checkNotNull(host.state.value.snapshot);val invite=checkNotNull(host.state.value.invite)
        val origin=checkNotNull(args.getString("nativeJamOrigin"))
        val parsed=java.net.URI(origin);require(parsed.scheme=="https"&&parsed.host=="127.0.0.1"&&parsed.port>0&&parsed.path.isEmpty()&&parsed.rawQuery==null&&parsed.rawFragment==null&&parsed.rawUserInfo==null)
        mark("invitation-ready",JSONObject().put("url",invite.link(origin,party.id)).put("jamId",party.id).put("offeredTitle",track.title))
        compose.waitUntil(60000){host.state.value.snapshot?.requests?.any {it.status=="pending"}==true&&!host.state.value.busy}
        val pending=host.state.value.snapshot!!.requests.single {it.status=="pending"}
        requestId.set(pending.id);host.decide(consent,pending,true)
        error("Required external kill cut was not reached")
    }
    @Test fun reconstructedProcessChecksExactLocalReceiptWithoutReplayOrAutoplay() {
        val expected=JSONObject(marker.readText())
        assertEquals(run,expected.getString("run"));assertEquals(cut,expected.getString("cut"));assertEquals("kill-ready",expected.getString("phase"))
        assertNotEquals(expected.getInt("pid"),android.os.Process.myPid())
        signIn();awaitQueue(expected.getJSONObject("queue").getJSONArray("rows").length())
        sameQueue(expected.getJSONObject("queue"),queue())
        assertEquals(0,app.queuedReceiptAttempts.get())
        compose.onNodeWithContentDescription("Settings").performClick();click("Music tools");click("Jam")
        compose.waitUntil(15000){compose.onAllNodesWithText("Check same Jam").fetchSemanticsNodes().isNotEmpty()&&app.graph.presence.capture()!=null}
        click("Check same Jam")
        val host=app.graph.jam
        compose.waitUntil(15000){host.state.value.snapshot?.id==expected.getString("jamId")&&!host.state.value.busy}
        val request=host.state.value.snapshot!!.requests.single {it.id==expected.getString("requestId")}
        val title=request.source?.title ?: host.state.value.snapshot!!.catalog.single {it.id==request.catalogId}.title
        compose.onNode(hasText(title) and hasClickAction() and hasAnyAncestor(isDialog())).performScrollTo().performClick();click("Check request")
        compose.waitUntil(15000){!host.state.value.busy&&host.state.value.message=="Saved on this device. Server confirmation unavailable."}
        compose.onNodeWithText("Saved on this device. Server confirmation unavailable.").performScrollTo().assertIsDisplayed()
        sameQueue(expected.getJSONObject("queue"),queue());assertEquals(0,app.queuedReceiptAttempts.get())
        assertNotEquals("queued",host.state.value.snapshot!!.requests.single {it.id==request.id}.status)
        val original=(0 until expected.getJSONObject("queue").getJSONArray("rows").length()).map {expected.getJSONObject("queue").getJSONArray("rows").getJSONObject(it)}
            .mapNotNull {it.optString("jam").takeIf {value->value!="null"&&value.isNotEmpty()}?.let(JamOccurrence::decode)}.single {it.requestId==request.id}
        assertNotEquals(original.sessionId,app.graph.jamAdmission.hostSession(app.graph.session.capture()!!))
        val diagnostics=main {val method=app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true};JSONObject(method.invoke(app.callbackPlayer) as String)}
        assertEquals(0,diagnostics.getInt("error"));assertEquals(0L,diagnostics.getLong("nonSilentCallbacks"))
        compose.waitForIdle();captureListeningStage("native-go-recovered-local-receipt")
        mark("recovered",JSONObject().put("queue",queue()).put("requestId",request.id).put("queuedReceiptAttempts",app.queuedReceiptAttempts.get()))
    }
}
