package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.jam.JamOccurrence
import com.soundq.android.data.jam.JamRequest
import com.soundq.android.product.ProductViewModel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Actual owned Go/JWT/Connect/SQL/worker/S3 -> production native service/JNI.
 * External provider/extractor audio is explicitly synthetic. A separate real
 * browser drives the public invitation/search/request UI, coordinated only by
 * this app-private file. No mock dispatcher or admission callback is installed.
 */
class NativeJamBackendJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val app get()=instrumentation.targetContext.applicationContext as NativeJamBackendApplication
    private val host get()=app.graph.jam
    private fun click(text:String)=compose.onNode(hasText(text) and hasClickAction()).performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
    private fun coordinate(phase:String,extra:JSONObject=JSONObject()) {
        val body=JSONObject().put("phase",phase)
        extra.keys().forEach {key->body.put(key,extra.get(key))}
        val file=File(instrumentation.targetContext.filesDir,"native-jam-state.json")
        file.writeText(body.toString())
    }
    private fun request(source:Boolean,status:String):JamRequest?=host.state.value.snapshot?.requests?.singleOrNull {(it.source!=null)==source&&it.status==status}
    private fun approve(source:Boolean) {
        compose.waitUntil(60000){request(source,"pending")!=null&&!host.state.value.busy}
        val snapshot=host.state.value.snapshot!!;val r=request(source,"pending")!!
        val title=r.source?.title ?: snapshot.catalog.single {it.id==r.catalogId}.title
        compose.onNode(hasText(title) and hasClickAction() and isEnabled() and hasAnyAncestor(isDialog())).performScrollTo().performClick()
        click(if(source)"Import & queue" else "Approve & queue")
        compose.waitUntil(60000){request(source,"queued")?.receipt!=null&&!host.state.value.busy}
    }
    @Test fun realGuestOutsideApprovalAndOfferedRequestReturnActualCanonicalABAReceiptsWithoutPlay() {
        val args=InstrumentationRegistry.getArguments()
        val hostId=checkNotNull(args.getString("nativeJamHostTrack")).toLong()
        val origin=checkNotNull(args.getString("nativeJamOrigin"))
        val uri=java.net.URI(origin)
        require(uri.scheme=="https"&&uri.host=="127.0.0.1"&&uri.port>0&&uri.path.isEmpty()&&uri.rawQuery==null&&uri.rawFragment==null&&uri.rawUserInfo==null)
        coordinate("starting")
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("native-jam@example.invalid")
            compose.onNodeWithContentDescription("Password").performTextInput("fixture-only-password")
            click("Sign in")
            compose.waitUntil(15000){app.graph.session.capture()!=null&&app.graph.library.state.value.rows.any {it.id.value==hostId}}
            val model=compose.runOnIdle{ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val track=app.graph.library.state.value.rows.single {it.id.value==hostId}
            compose.onNodeWithContentDescription("Library search query").performTextReplacement(track.title)
            compose.onNodeWithContentDescription("Search library").performClick()
            compose.waitUntil(10000){!app.graph.library.state.value.loading&&app.graph.library.state.value.rows.map {it.id.value}==listOf(hostId)}
            val row=hasText(track.title) and hasClickAction() and hasAnyDescendant(hasContentDescription("More for ${track.title}"))
            compose.onNode(row).performScrollTo().performClick()
            compose.waitUntil(20000){model.playback.value.isPlaying&&model.playback.value.positionMs>=300}
            assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer",app.callbackPlayer.javaClass.name)
            val diagnostics=app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}
            val rendered=JSONObject(diagnostics.invoke(app.callbackPlayer) as String)
            assertEquals(0,rendered.getInt("error"));assertTrue(rendered.getLong("renderedFrames")>0);assertTrue(rendered.getLong("nonSilentCallbacks")>0)
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
            val before=model.playback.value
            assertEquals(listOf(hostId),before.queue.map {it.trackId})
            captureListeningStage("native-go-host-paused")
            compose.onNodeWithContentDescription("Account and settings").performClick()
            click("Jam")
            compose.waitUntil(15000){app.graph.presence.capture()!=null}
            compose.onNode(hasText(track.title) and hasClickAction() and hasAnyAncestor(isDialog()) and
                SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Not selected for Jam")).performScrollTo().performClick()
            compose.onNode(isToggleable()).performScrollTo().performClick()
            click("Create Jam")
            compose.waitUntil(15000){host.state.value.snapshot?.outsideDiscovery==true&&!host.state.value.busy}
            val party=host.state.value.snapshot!!
            assertTrue(party.requests.isEmpty())
            click("Invitation")
            compose.onNode(hasText("Guest website") and hasSetTextAction()).performTextInput(origin)
            click("New invitation")
            compose.waitUntil(15000){host.state.value.invite!=null&&!host.state.value.busy}
            compose.onNodeWithContentDescription("Jam invitation QR code").assertExists()
            val invite=host.state.value.invite!!
            val link=invite.link(origin,party.id)
            // Capability stays in private fixture coordination; never log it.
            captureListeningStage("native-go-invitation")
            coordinate("invitation-ready",JSONObject().put("url",link).put("jamId",party.id).put("offeredTitle",party.catalog.single().title))
            compose.onNodeWithContentDescription("Close Invitation").performScrollTo().performClick()
            approve(true)
            val outside=request(true,"queued")!!
            val outsideId=checkNotNull(outside.trackId).value
            assertNotNull(outside.admissionKey);assertNotNull(outside.downloadJobId)
            compose.waitUntil(10000){model.playback.value.queue.size==2}
            assertEquals(before.queue.map {it.trackId}+outsideId,model.playback.value.queue.map {it.trackId})
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            captureListeningStage("native-go-outside-canonical")
            coordinate("outside-queued",JSONObject().put("requestId",outside.id))
            approve(false)
            val offered=request(false,"queued")!!
            assertEquals(hostId,offered.trackId!!.value)
            compose.waitUntil(10000){model.playback.value.queue.size==3}
            val queue=model.playback.value.queue
            assertEquals(listOf(hostId,outsideId,hostId),queue.map {it.trackId})
            assertEquals(3,queue.map {it.occurrenceId}.distinct().size)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            assertEquals(queue[1].occurrenceId,outside.receipt!!.occurrenceId)
            assertEquals(queue[2].occurrenceId,offered.receipt!!.occurrenceId)
            compose.runOnIdle {
                val player=app.callbackPlayer
                assertFalse(player.playWhenReady);assertFalse(player.isPlaying)
                for((index,r) in listOf(1 to outside,2 to offered)) {
                    val item=player.getMediaItemAt(index)
                    val evidence=JamOccurrence.decode(item.mediaMetadata.extras!!.getString("soundqJam"))!!
                    assertEquals(r.id,evidence.requestId);assertEquals(r.admissionKey,evidence.admissionKey)
                    assertEquals(r.hostSessionId,evidence.sessionId);assertEquals(r.receipt!!.occurrenceId,item.mediaId)
                }
            }
            repeat(3){
                val observed=host.state.value.snapshot
                click("Refresh requests")
                compose.waitUntil(10000){!host.state.value.busy&&host.state.value.snapshot!==observed}
            }
            assertEquals(queue,model.playback.value.queue)
            assertFalse(model.playback.value.isPlaying)
            captureListeningStage("native-go-canonical-aba")
            coordinate("canonical-verified",JSONObject().put("queueCount",queue.size).put("distinctOccurrences",queue.map {it.occurrenceId}.distinct().size))
            click("End Jam")
            compose.onNode(hasText("End Jam") and hasClickAction() and hasAnyAncestor(hasAnyDescendant(hasText("Keep Jam")))).performScrollTo().performClick()
            compose.waitUntil(15000){
                val ended=host.state.value
                ended.snapshot==null&&ended.message=="Jam ended."&&!ended.busy&&!ended.uncertain
            }
            assertNull(host.state.value.invite)
            assertEquals(queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
            compose.waitUntil(10000){compose.onAllNodesWithText("Jam ended.").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Jam ended.").performScrollTo().assertIsDisplayed()
            compose.waitForIdle()
            captureListeningStage("native-go-ended-preserves-queue")
            coordinate("passed",JSONObject().put("queueCount",queue.size).put("distinctOccurrences",queue.map {it.occurrenceId}.distinct().size))
        } catch(error:Throwable) {
            coordinate("failed",JSONObject().put("failureType",error.javaClass.name))
            try {captureListeningStage("native-go-failure")}catch(capture:Throwable){error.addSuppressed(capture)}
            throw error
        }
    }
}
