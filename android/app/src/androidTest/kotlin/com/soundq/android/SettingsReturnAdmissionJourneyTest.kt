package com.soundq.android

import androidx.compose.ui.test.*
import com.soundq.android.data.AuthState
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.semantics.*
import androidx.compose.ui.platform.ViewRootForTest
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.findViewTreeLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Bounded mounted native observations. No dispatch substitution or extra polling. */
class SettingsReturnAdmissionJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    /** Reveal the real lazy item before resolving an otherwise uncomposed target. */
    private fun reveal(matcher:SemanticsMatcher):SemanticsNodeInteraction {
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher)
        return compose.onNode(matcher).assertIsDisplayed().assertIsEnabled()
    }

    /** The Library gear sits in the pinned header, outside the lazy list. */
    private fun gear()=compose.onNodeWithContentDescription("Settings").assertIsDisplayed().assertIsEnabled()

    private fun click(label:String)=compose.onNode(hasText(label) and hasClickAction()).performScrollTo().performClick()
    private val phases=JSONArray()
    private val lifecycle=JSONArray()
    /** Inspect only bounded callback captures, never invoke a callback or stringify state. */
    private fun callbackCaptures(action:Any?):JSONArray {
        val result=JSONArray();val pending=ArrayDeque<Pair<Any,Int>>()
        val seen=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any,Boolean>())
        if(action!=null)pending.add(action to 0)
        while(pending.isNotEmpty()&&seen.size<96) {
            val (value,depth)=pending.removeFirst();if(!seen.add(value))continue
            val type=value.javaClass
            val row=JSONObject().put("identity",System.identityHashCode(value)).put("class",type.name).put("depth",depth)
            if(type.name=="com.soundq.android.product.LibraryRowLifetime") {
                row.put("current",type.getDeclaredMethod("current").apply {isAccessible=true}.invoke(value))
                val alive=type.getDeclaredField("alive").apply {isAccessible=true}.get(value) as java.util.concurrent.atomic.AtomicBoolean
                row.put("alive",alive.get())
            }
            if(value is java.util.concurrent.atomic.AtomicBoolean)row.put("boolean",value.get())
            result.put(row)
            if(depth<8&&(value is kotlin.Function<*>||type.name.startsWith("kotlin.jvm.internal.Ref$")||type.name.startsWith("androidx.compose.runtime.internal."))) {
                for(field in type.declaredFields.take(24))if(!java.lang.reflect.Modifier.isStatic(field.modifiers)) {
                    try {field.isAccessible=true;val child=field.get(value)
                        if(child!=null&&(child is kotlin.Function<*>||child is java.util.concurrent.atomic.AtomicBoolean||child.javaClass.name=="com.soundq.android.product.LibraryRowLifetime"||child.javaClass.name.startsWith("kotlin.jvm.internal.Ref$")||child.javaClass.name.startsWith("androidx.compose.runtime.internal.")))pending.add(child to depth+1)
                    }catch(_:ReflectiveOperationException) {row.put("captureReadFailure",field.name)}
                }
            }
        }
        return result
    }
    private fun observe(stage:String,graph:com.soundq.android.AppGraph) {
        val phase=JSONObject().put("stage",stage).put("uptimeMs",android.os.SystemClock.uptimeMillis())
        phases.put(phase) // Retain partial snapshot if a later observation itself fails.
        compose.runOnIdle {
            val state=graph.library.state.value;val row=state.rows.firstOrNull()
            val capture=row?.let(graph.library::captureTrack)
            phase.put("activity",System.identityHashCode(compose.activity)).put("lifecycle",compose.activity.lifecycle.currentState.name)
                .put("windowFocus",compose.activity.hasWindowFocus()).put("touchMode",compose.activity.window.decorView.isInTouchMode)
                .put("accountVersion",graph.session.version()).put("loading",state.loading).put("errorPresent",state.error!=null)
                .put("rowCount",state.rows.size).put("firstRowIdentity",row?.let(System::identityHashCode))
                .put("freshCapture",capture!=null).put("freshCaptureOwned",capture?.let(graph.library::owns))
        }
        val trees=JSONObject();phase.put("trees",trees)
        for(unmerged in listOf(false,true)) {
            val nodes=compose.onAllNodes(SemanticsMatcher("all diagnostic nodes"){true},useUnmergedTree=unmerged).fetchSemanticsNodes()
            val rows=JSONArray();val roots=java.util.IdentityHashMap<Any,JSONObject>()
            for(node in nodes) {
                val root=node.root ?: continue
                if(!roots.containsKey(root)) {
                    val view=(root as? ViewRootForTest)?.view
                    roots[root]=JSONObject().put("identity",System.identityHashCode(root)).put("class",root.javaClass.name)
                        .put("viewIdentity",view?.let(System::identityHashCode)).put("attached",view?.isAttachedToWindow)
                        .put("windowFocus",view?.hasWindowFocus()).put("touchMode",view?.isInTouchMode)
                        .put("lifecycle",view?.findViewTreeLifecycleOwner()?.lifecycle?.currentState?.name)
                }
                val config=node.config
                val texts=config.getOrNull(SemanticsProperties.Text)?.map {it.text}.orEmpty()
                val descriptions=config.getOrNull(SemanticsProperties.ContentDescription).orEmpty()
                val heading=config.contains(SemanticsProperties.Heading)
                val selected=heading||texts.any {it in setOf("Fixture 1","Song details","Settings","Account","Library","Now playing","Download to device","Play loaded library here")}||descriptions.any {it in setOf("More for Fixture 1","Close Settings","Close Song details","Account and preview information")}
                if(selected)rows.put(JSONObject().put("id",node.id).put("root",System.identityHashCode(root))
                    .put("parent",node.parent?.id).put("heading",heading).put("text",JSONArray(texts))
                    .put("descriptions",JSONArray(descriptions)).put("enabled",!config.contains(SemanticsProperties.Disabled))
                    .put("click",config.contains(SemanticsActions.OnClick)).put("focus",config.getOrNull(SemanticsProperties.Focused))
                    .put("bounds",node.boundsInRoot.toString()).put("actions",JSONArray(config.filter {it.key.name in setOf("OnClick","RequestFocus","ScrollBy","Dismiss")}.map {it.key.name}))
                    .put("callbackCaptures",if(descriptions.contains("More for Fixture 1"))callbackCaptures(config.getOrNull(SemanticsActions.OnClick)?.action) else null))
            }
            trees.put(if(unmerged)"unmerged" else "merged",JSONObject().put("nodeCount",nodes.size).put("nodes",rows).put("roots",JSONArray(roots.values.toList())))
        }
    }
    @Test fun repeatedSettingsReturnAdmitsLibraryMoreAndCanonicalSongDetailsWithoutPlayback() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        graph.session.retire()
        val observer=LifecycleEventObserver {_,event->if(lifecycle.length()<64)lifecycle.put(JSONObject().put("event",event.name).put("uptimeMs",android.os.SystemClock.uptimeMillis()))}
        compose.runOnIdle {compose.activity.lifecycle.addObserver(observer)}
        var primary:Throwable?=null
        try {
            compose.signInThroughSettings("settings-return@example.test","test-only-password"){graph.session.state.value is AuthState.SignedIn}
            compose.waitUntil(10000){graph.library.state.value.rows.size>=3}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val before=compose.runOnIdle {model.playback.value}
            fun openDetails(stage:String) {
                reveal(hasContentDescription("More for Fixture 1"))
                observe("$stage-before-more",graph)
                compose.onNodeWithContentDescription("More for Fixture 1").assertIsDisplayed().assertIsEnabled().performClick()
                observe("$stage-after-more",graph)
                // No polling/extended deadline around the control missing in the retained run.
                compose.onNode(hasText("Song details") and hasClickAction()).assertExists().assertIsEnabled()
                click("Song details")
                compose.onNodeWithContentDescription("Close Song details").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
                observe("$stage-after-details-close",graph)
            }
            openDetails("before-settings-control")
            repeat(3) {cycle ->
                gear().performClick()
                observe("settings-$cycle-mounted",graph)
                compose.onNodeWithContentDescription("Back").assertIsDisplayed().assertIsEnabled().performClick()
                openDetails("after-settings-$cycle")
                compose.runOnIdle {
                    assertFalse(model.playback.value.isPlaying)
                    assertEquals(before.queue,model.playback.value.queue)
                    assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
                }
            }
        } catch(failure:Throwable) {
            primary=failure
            try {observe("failure",graph)}catch(diagnostic:Throwable){failure.addSuppressed(diagnostic)}
            throw failure
        } finally {
            try {
                compose.runOnIdle {compose.activity.lifecycle.removeObserver(observer)}
                val report=JSONObject().put("phases",phases).put("lifecycle",lifecycle).put("failureClass",primary?.javaClass?.name)
                InstrumentationRegistry.getInstrumentation().targetContext.filesDir.resolve("settings-return-diagnostic.json").writeText(report.toString())
            }catch(diagnostic:Throwable){val failure=primary;if(failure!=null)failure.addSuppressed(diagnostic) else throw diagnostic}
            finally {graph.session.retire()}
        }
    }
}
