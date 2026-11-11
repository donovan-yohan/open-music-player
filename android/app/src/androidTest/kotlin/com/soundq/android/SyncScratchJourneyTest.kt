package com.soundq.android

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Real UI -> controller -> service -> JNI -> native callback on owned emulator.
 * Synthetic four-source PCM fixture; not physical touch-to-speaker qualification. */
class SyncScratchJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun fourSourcesKeepPlayingWhileWaveformScratchAndLiveBeatSyncRun() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as PerformanceFixtureApplication
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("performance@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        // Native IME submit avoids clicking an offscreen/IME-covered action in a compact viewport.
        compose.onNodeWithContentDescription("Password").performImeAction()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.library.value.rows.size==4}
        val output=File(app.filesDir,"sync-scratch").apply {mkdirs()}
        // These are this journey's own prior completion files. A later failed
        // attempt must never export an earlier run's successful result.
        listOf("result.json","locks.json","rejoined-native.json","scratch-native.json","scratch-window.json","linked-before.json","linked-semantics.txt","scratch-calls.json","zoom-window.json","zoom-result.json").forEach {File(output,it).delete()}
        val method=app.performancePlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}
        fun native()=JSONObject(method.invoke(app.performancePlayer) as String)
        compose.onNode(hasClickAction() and hasAnyDescendant(hasText("Performance 1")) and hasAnyDescendant(hasContentDescription("More for Performance 1")),useUnmergedTree=true).performClick()
        try {
            compose.waitUntil(20000){model.playback.value.isPlaying&&model.playback.value.positionMs>300}
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            compose.waitUntil(10000){model.timeline.value.document.clips.size==4}
            compose.runOnIdle {
                for(index in 1..3) {
                    val document=model.timeline.value.document
                    assertTrue(model.graph.timeline.commit(TimelineEdit(document.revision,document.clips[index],EditKind.Placement,0)){true})
                }
            }
            val document=compose.runOnIdle {model.timeline.value.document}
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(20000){model.playback.value.canPerformArrangement&&model.playback.value.performanceDecks.size==4&&model.playback.value.performanceDecks.values.all {it.playing&&it.ready}}
            val identity=model.playback.value.arrangement!!.identity
            val incoming=document.clips[1]
            val reference=document.clips[0]
            compose.waitUntil(15000){compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}").fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription].startsWith("Loaded")}
            repeat(6){compose.onNodeWithContentDescription("Zoom in").performClick()}
            compose.onNodeWithContentDescription("2 · ${incoming.title}").performTouchInput {longClick()}
            compose.onNodeWithText("Scratch",substring=false).performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Clip 2").fetchSemanticsNodes().isEmpty()}
            compose.onNodeWithContentDescription("2 · ${incoming.title}").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Selected · Scratch armed"))
            var bounds=compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}").fetchSemanticsNode().boundsInRoot
            var root=compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}").fetchSemanticsNode().root as androidx.compose.ui.platform.ViewRootForTest
            val location=IntArray(2)
            compose.runOnIdle {root.view.getLocationOnScreen(location)}
            var frameRecorder:com.soundq.android.performance.WindowInteractionRecorder?=null
            compose.runOnIdle {
                var parent:android.view.ViewParent?=root.view.parent
                while(parent!=null&&parent !is androidx.compose.ui.window.DialogWindowProvider)parent=parent.parent
                val window=(parent as? androidx.compose.ui.window.DialogWindowProvider)?.window ?: error("Queue dialog window unavailable")
                frameRecorder=com.soundq.android.performance.WindowInteractionRecorder(window).also {it.start()}
            }
            var x=location[0]+bounds.left+bounds.width*.5f
            var y=location[1]+bounds.top+bounds.height*.82f
            var down=SystemClock.uptimeMillis()
            fun inject(action:Int,px:Float,eventTime:Long=SystemClock.uptimeMillis()) {
                if(action==MotionEvent.ACTION_DOWN)down=eventTime
                val properties=MotionEvent.PointerProperties().apply {id=0;toolType=MotionEvent.TOOL_TYPE_FINGER}
                val coords=MotionEvent.PointerCoords().apply {this.x=px;this.y=y;pressure=if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_CANCEL)0f else 1f;size=1f}
                val event=MotionEvent.obtain(down,eventTime,action,1,arrayOf(properties),arrayOf(coords),0,0,1f,1f,0,0,InputDevice.SOURCE_TOUCHSCREEN,0)
                // Mounted Android View input. API37's system injector rejects this
                // window; this does not qualify InputDispatcher/touchscreen latency.
                event.offsetLocation(-location[0].toFloat(),-location[1].toFloat())
                try {instrumentation.runOnMainSync {
                    val handled=root.view.dispatchTouchEvent(event)
                    // AndroidComposeView processCancel returns ProcessResult(false)
                    // after cancelling pointers. The consumed terminal is asserted
                    // through native release below, not this dispatch Boolean.
                    if(action!=MotionEvent.ACTION_CANCEL)assertTrue("Mounted input action $action must reach pointer handling",handled)
                }}finally {event.recycle()}
            }
            val records=mutableListOf<JSONObject>()
            val peersBefore=model.playback.value.performanceDecks.filterKeys {it!=incoming.occurrence}.mapValues {it.value.sourcePositionMs}
            File(output,"before-pointer.json").writeText(JSONObject().put("native",native()).put("projection",model.playback.value.toString()).put("bounds",bounds.toString()).put("location",org.json.JSONArray(location.toList())).put("x",x).put("y",y).toString(2))
            File(output,"before-pointer-semantics.txt").writeText(compose.onAllNodes(isRoot()).printToString())
            File(output,"before-pointer-windows.txt").writeText(instrumentation.uiAutomation.windows.joinToString("\n"))
            for(command in listOf("dumpsys input","dumpsys window windows")) {
                val pipe=instrumentation.uiAutomation.executeShellCommand(command)
                android.os.ParcelFileDescriptor.AutoCloseInputStream(pipe).use {File(output,command.replace(' ','-')+".txt").writeBytes(it.readBytes())}
            }
            compose.runOnIdle {
                val previous=root.view.javaClass.getDeclaredField("previousMotionEvent").apply {isAccessible=true}.get(root.view) as? MotionEvent
                File(output,"pointer-clock.json").writeText(JSONObject().put("nowMs",SystemClock.uptimeMillis()).put("previousEventMs",previous?.eventTime).put("previousAction",previous?.action).toString())
                val bitmap=android.graphics.Bitmap.createBitmap(root.view.width,root.view.height,android.graphics.Bitmap.Config.ARGB_8888)
                try {root.view.draw(android.graphics.Canvas(bitmap));File(output,"before-pointer.png").outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}}finally {bitmap.recycle()}
            }
            try {inject(MotionEvent.ACTION_DOWN,x);compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.scratching==true}}
            finally {
                File(output,"after-down.json").writeText(JSONObject().put("native",native()).put("projection",model.playback.value.toString()).toString(2))
                File(output,"after-down-semantics.txt").writeText(compose.onAllNodes(isRoot()).printToString())
            }
            var px=x
            repeat(40){SystemClock.sleep(8);px+=.5f;inject(MotionEvent.ACTION_MOVE,px);records.add(native())}
            assertTrue("Native forward rate must follow real pointer movement",records.any {j->val d=j.getJSONArray("decks");(0 until d.length()).any {d.getJSONObject(it).let {n->n.optBoolean("scratching")&&n.optDouble("rate")>0}}})
            repeat(40){SystemClock.sleep(8);px-=.5f;inject(MotionEvent.ACTION_MOVE,px);records.add(native())}
            assertTrue("Native reverse rate must follow real pointer movement",records.any {j->val d=j.getJSONArray("decks");(0 until d.length()).any {d.getJSONObject(it).let {n->n.optBoolean("scratching")&&n.optDouble("rate")<0}}})
            compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.let {it.scratching&&it.heldZero&&it.rate==0.0}==true}
            SystemClock.sleep(2);inject(MotionEvent.ACTION_UP,px)
            compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.let {!it.scratching&&it.playing&&it.rate>0}==true}
            compose.waitForIdle()
            // Cancellation has no later physical event. Reuse the last Move's
            // millisecond and require release plus a fresh usable contact.
            inject(MotionEvent.ACTION_DOWN,x)
            compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.scratching==true}
            val cancelTime=SystemClock.uptimeMillis()
            inject(MotionEvent.ACTION_MOVE,x+.25f,cancelTime)
            inject(MotionEvent.ACTION_CANCEL,x+.25f,cancelTime)
            compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.let {!it.scratching&&it.playing&&it.rate>0}==true}
            peersBefore.forEach {(id,position)->assertTrue("Peer must advance during scratch",model.playback.value.performanceDecks.getValue(id).sourcePositionMs>position+200)}
            assertEquals("Scratch must not write draft or Undo",document,model.timeline.value.document)
            File(output,"scratch-snapshots.json").writeText(org.json.JSONArray(records).toString())
            File(output,"scratch-native.json").writeText(native().toString(2))
            compose.runOnIdle {frameRecorder?.write(File(output,"scratch-window.json"));frameRecorder?.close()}
            // Each boundary is independently admitted, reached by the native callback,
            // then explicitly unlinked before another grid request (no absent ACK token).
            val scope=app.graph.session.capture()!!
            val waveA=app.graph.timeline.waveform(scope,com.soundq.android.data.TrackId(reference.track),reference.sourceDurationMs){true}!!
            val waveB=app.graph.timeline.waveform(scope,com.soundq.android.data.TrackId(incoming.track),incoming.sourceDurationMs){true}!!
            val a=QualifiedLiveGrid(120.0,200.0,200.0,waveA.sourceKey,"synthetic-grid-a")
            val b=QualifiedLiveGrid(100.0,200.0,200.0,waveB.sourceKey,"synthetic-grid-b")
            val locks=org.json.JSONArray()
            for(beats in listOf(1,4,16,32)) {
                var admitted:Boolean?=null
                if(beats==1) {
                    compose.onNodeWithContentDescription("Timeline options").performClick()
                    compose.onNodeWithText("Live performance").performClick()
                    compose.onNodeWithContentDescription("Live sync Reference").performScrollTo().performClick()
                    compose.onNode(hasText("1 · ${reference.title}") and hasAnyAncestor(isPopup())).performClick()
                    compose.onNodeWithContentDescription("Live sync Incoming").performScrollTo().performClick()
                    compose.onNode(hasText("2 · ${incoming.title}") and hasAnyAncestor(isPopup())).performClick()
                    compose.onNodeWithContentDescription("Set live source timing").performScrollTo().performClick()
                    listOf("Reference live BPM" to "120","Reference live beat anchor ms" to "200","Reference live group origin ms" to "200",
                        "Incoming live BPM" to "100","Incoming live beat anchor ms" to "200","Incoming live group origin ms" to "200").forEach {(label,value)->
                        compose.onNode(hasText(label) and hasSetTextAction()).performScrollTo().performTextInput(value)
                    }
                    compose.onNodeWithContentDescription("Sync Incoming to Reference").performScrollTo().assertIsEnabled()
                    app.performanceCalls.hold()
                    val before=app.performanceCalls.admissions.get()
                    try {
                        compose.onNodeWithContentDescription("Sync Incoming to Reference").performClick()
                        compose.waitUntil(10000){app.performanceCalls.admissions.get()==before+1}
                        compose.onNodeWithContentDescription("Sync Incoming to Reference").assertIsNotEnabled()
                        compose.onNodeWithContentDescription("Sync boundary, 4 beats").assertIsNotEnabled()
                        compose.onNodeWithContentDescription("Sync Incoming to Reference").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.OnClick){it()}
                        compose.runOnIdle {assertEquals(before+1,app.performanceCalls.admissions.get())}
                        // Pending must retain a usable explicit recovery action.
                        val unlinks=app.performanceCalls.unlinks.get()
                        compose.onNodeWithContentDescription("Disable live sync").assertIsEnabled().performClick()
                        compose.waitUntil(10000){app.performanceCalls.unlinks.get()>unlinks}
                    } finally {app.performanceCalls.release()}
                    compose.waitUntil(10000){!compose.onNodeWithContentDescription("Sync Incoming to Reference").fetchSemanticsNode().config.contains(androidx.compose.ui.semantics.SemanticsProperties.Disabled)&&model.playback.value.performanceDecks[incoming.occurrence]?.syncState==LiveSyncState.Off}
                    compose.onNodeWithContentDescription("Sync Incoming to Reference").assertIsEnabled().performClick()
                    compose.waitUntil(22000){model.playback.value.performanceDecks[incoming.occurrence]?.syncState==LiveSyncState.Locked}
                    compose.onNodeWithContentDescription("Sync Incoming to Reference").assertIsNotEnabled()
                    compose.onNodeWithContentDescription("Close Live performance").performScrollTo().performClick()
                    compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Close Live performance").fetchSemanticsNodes().isEmpty()}
                    admitted=true
                } else compose.runOnIdle {model.controller.syncIncoming(identity,reference.occurrence,incoming.occurrence,beats,a,b){admitted=it}}
                compose.waitUntil(10000){admitted!=null}
                File(output,"sync-$beats-admission.json").writeText(JSONObject().put("admitted",admitted).put("native",native()).put("projection",model.playback.value.toString()).toString(2))
                assertEquals(true,admitted)
                try {compose.waitUntil(22000){model.playback.value.performanceDecks[incoming.occurrence]?.let {it.syncState==LiveSyncState.Locked&&it.syncBeats==beats}==true}}
                finally {File(output,"sync-$beats-observed.json").writeText(JSONObject().put("native",native()).put("projection",model.playback.value.toString()).toString(2))}
                val deck=model.playback.value.performanceDecks.getValue(incoming.occurrence)
                assertEquals(1.2,deck.rate,1e-8)
                assertTrue(kotlin.math.abs(deck.syncPhaseErrorFrames)<=1.0)
                locks.put(JSONObject().put("beats",beats).put("rate",deck.rate).put("phaseErrorFrames",deck.syncPhaseErrorFrames))
                if(beats!=32) {
                    compose.runOnIdle {model.controller.unlinkIncoming(identity,incoming.occurrence)}
                    compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.syncState==LiveSyncState.Off}
                }
            }
            // The same mounted waveform must scratch a linked incoming voice and
            // rejoin at its selected future boundary without touching its master.
            val oldBounds=bounds;val oldRoot=root;val oldLocation=location.toList()
            val fresh=compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}").fetchSemanticsNode()
            bounds=fresh.boundsInRoot;root=fresh.root as androidx.compose.ui.platform.ViewRootForTest
            compose.runOnIdle {root.view.getLocationOnScreen(location)}
            x=location[0]+bounds.left+bounds.width*.5f;y=location[1]+bounds.top+bounds.height*.82f
            File(output,"linked-before.json").writeText(JSONObject().put("native",native()).put("sameRoot",root===oldRoot).put("attached",root.view.isAttachedToWindow).put("oldBounds",oldBounds.toString()).put("bounds",bounds.toString()).put("oldLocation",org.json.JSONArray(oldLocation)).put("location",org.json.JSONArray(location.toList())).put("canPerform",model.playback.value.canPerformArrangement).put("ready",model.playback.value.performanceDecks[incoming.occurrence]?.ready).put("calls",org.json.JSONArray(app.performanceCalls.scratchCalls.toList())).toString(2))
            File(output,"linked-semantics.txt").writeText(compose.onAllNodes(isRoot()).printToString())
            inject(MotionEvent.ACTION_DOWN,x)
            compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.syncState==LiveSyncState.ScratchSuspended}
            px=x
            repeat(12){SystemClock.sleep(8);px-=.25f;inject(MotionEvent.ACTION_MOVE,px)}
            SystemClock.sleep(2);inject(MotionEvent.ACTION_UP,px)
            compose.waitUntil(10000){model.playback.value.performanceDecks[incoming.occurrence]?.syncState==LiveSyncState.Rejoining}
            compose.waitUntil(22000){model.playback.value.performanceDecks[incoming.occurrence]?.syncState==LiveSyncState.Locked}
            val final=native()
            File(output,"rejoined-native.json").writeText(final.toString(2))
            assertTrue(final.getLong("nonSilentCallbacks")>0)
            assertEquals(4,final.getInt("openDecoders"))
            assertEquals(12288000,final.getInt("pcmPoolBytes"))
            assertEquals(document,model.timeline.value.document)
            File(output,"locks.json").writeText(locks.toString(2))
            if(InstrumentationRegistry.getArguments().getString("soundqMeasureZoom")=="true") {
                fun visibleRange():String=compose.onAllNodes(SemanticsMatcher("Visible timeline range"){node->node.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Text)?.any {it.text.matches(Regex("\\d+:\\d{2}–\\d+:\\d{2}"))}==true},useUnmergedTree=true).fetchSemanticsNodes().single().config[androidx.compose.ui.semantics.SemanticsProperties.Text].single().text
                // Undo exactly the six scratch-setup zoom steps. Continuing to
                // the 1px/s floor measures mostly empty timeline, not dense audio.
                repeat(6){compose.onNodeWithContentDescription("Zoom out").performClick()}
                compose.waitForIdle()
                val before=visibleRange()
                val zoomNode=compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}")
                val zoomRoot=zoomNode.fetchSemanticsNode().root as androidx.compose.ui.platform.ViewRootForTest
                var zoomRecorder:com.soundq.android.performance.WindowInteractionRecorder?=null
                compose.runOnIdle {
                    var parent:android.view.ViewParent?=zoomRoot.view.parent
                    while(parent!=null&&parent !is androidx.compose.ui.window.DialogWindowProvider)parent=parent.parent
                    zoomRecorder=com.soundq.android.performance.WindowInteractionRecorder(checkNotNull((parent as? androidx.compose.ui.window.DialogWindowProvider)?.window)).also {it.start()}
                }
                val zoomStart=SystemClock.elapsedRealtimeNanos()
                android.os.Trace.beginSection("SoundQZoomMeasured")
                var pinched=""
                try {
                    repeat(3){compose.onNodeWithContentDescription("Zoom in").performClick();compose.waitForIdle()}
                    assertNotEquals("Button zoom must change actual viewport",before,visibleRange())
                    repeat(3){compose.onNodeWithContentDescription("Zoom out").performClick();compose.waitForIdle()}
                    assertEquals("Inverse buttons must restore actual viewport",before,visibleRange())
                    zoomNode.performTouchInput {
                        down(0,androidx.compose.ui.geometry.Offset(width*.25f,height*.8f));down(1,androidx.compose.ui.geometry.Offset(width*.45f,height*.8f))
                        moveTo(0,androidx.compose.ui.geometry.Offset(width*.15f,height*.8f));moveTo(1,androidx.compose.ui.geometry.Offset(width*.55f,height*.8f))
                        up(0);up(1)
                    }
                    compose.waitForIdle();pinched=visibleRange()
                    assertNotEquals("Two-pointer zoom must change actual viewport",before,pinched)
                } finally {
                    android.os.Trace.endSection()
                    compose.runOnIdle {zoomRecorder?.write(File(output,"zoom-window.json"));zoomRecorder?.close()}
                    File(output,"zoom-result.json").writeText(JSONObject().put("startElapsedNs",zoomStart).put("endElapsedNs",SystemClock.elapsedRealtimeNanos()).put("before",before).put("pinched",pinched).put("native",native()).toString(2))
                }
            }
            compose.runOnIdle {model.controller.returnToSources()}
            compose.waitUntil(10000){model.playback.value.arrangement==null&&model.playback.value.queue.size==4&&!model.playback.value.isPlaying}
            compose.runOnIdle {model.controller.toggle()}
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.positionMs>100}
            File(output,"result.json").writeText(JSONObject().put("fourNativeSources",true).put("actualWaveformPointerForwardReverse",true).put("stationaryNativeZero",true).put("sameTimestampCancelRecovered",true).put("pendingUnlinkRecovered",true).put("peersAdvanced",true).put("draftUnchanged",true).put("ordinaryReturnAndPlay",true).put("beatBoundaries",org.json.JSONArray(listOf(1,4,16,32))).put("keylock",false).toString(2))
        } finally {
            File(output,"terminal-native.json").writeText(native().toString(2))
            File(output,"scratch-calls.json").writeText(org.json.JSONArray(app.performanceCalls.scratchCalls.toList()).toString(2))
            app.performanceCalls.release()
            File(output,"terminal-projection.txt").writeText(model.playback.value.toString())
            if(InstrumentationRegistry.getArguments().getString("soundqExportPerformance")=="true") {
                // Synthetic test-runner artifacts only. Allows shell readback from
                // a non-debuggable release target without changing app security.
                val run=checkNotNull(InstrumentationRegistry.getArguments().getString("soundqPerformanceRun"))
                require(run.matches(Regex("[a-z0-9-]{1,64}")))
                val external=File(checkNotNull(app.getExternalFilesDir(null)),"sync-scratch-$run")
                external.mkdirs()
                output.listFiles()?.filter {it.extension in listOf("json","txt","png")}?.forEach {it.copyTo(File(external,it.name),overwrite=true)}
            }
            compose.runOnIdle {model.controller.pause()}
        }
    }
}
