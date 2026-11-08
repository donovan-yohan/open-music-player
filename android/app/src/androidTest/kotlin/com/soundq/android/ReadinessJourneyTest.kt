package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Rule
import org.junit.Test

/** Failure evidence must never replace the original wait/assertion failure. */
internal fun readinessAttempt(wait:()->Unit,snapshot:()->String,emit:(String)->Unit) {
    try {wait()} catch(primary:Throwable) {
        try {emit(snapshot())} catch(diagnostic:Throwable) {primary.addSuppressed(diagnostic)}
        throw primary
    }
    emit(snapshot())
}

/** Bounded, metadata-only observation. No request bodies, credentials or account identifiers. */
internal class ReadinessProbe(private val graph:AppGraph):AutoCloseable {
    private val server=ProductTransportFixture.server
    private val fallback=server.dispatcher
    private var count=0
    private val phases=ArrayDeque<JSONObject>()
    private fun record(request:RecordedRequest,phase:String,status:Int?)=synchronized(this) {
        if(phase=="entered")count++
        if(phases.size==16)phases.removeFirst()
        phases.addLast(JSONObject().put("method",request.method).put("path",request.url.encodedPath)
            .put("limit",request.url.queryParameter("limit")?:JSONObject.NULL)
            .put("offset",request.url.queryParameter("offset")?:JSONObject.NULL)
            .put("phase",phase).put("status",status?:JSONObject.NULL))
    }
    init {
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            record(request,"entered",null)
            return fallback.dispatch(request).also {record(request,"responded",it.code)}
        }}
    }
    fun snapshot():String {
        val library=graph.library.state.value
        val appearance=graph.appearancePreferences.state.value
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        return JSONObject().put("libraryReady",library.rows.size>=3).put("appearanceReady",appearance.ready)
            .put("authClass",graph.session.state.value.javaClass.simpleName)
            .put("acceptedRows",library.rows.size).put("libraryLoading",library.loading)
            .put("libraryError",library.error?.name?:JSONObject.NULL)
            .put("appearanceError",appearance.error?.toString()?:JSONObject.NULL)
            .put("graphIdentity",System.identityHashCode(graph)).put("applicationGraphSame",app.graph===graph)
            .put("fixtureEndpointSame",graph.endpoint.identity==ProductTransportFixture.endpoint.identity)
            .put("bootstrapRetired",!app.bootstrapThread.isAlive)
            .put("networkingOffMain",ProductTransportFixture.networkingStayedOffMain)
            .also {json->synchronized(this){json.put("requestCount",count).put("requestPhases",JSONArray(phases.toList()))}}.toString()
    }
    override fun close(){server.dispatcher=fallback}
}

/** Ordinary Activity, sign-in and unchanged compound readiness. No feature action shortcuts. */
class ReadinessJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinarySignInDiscriminatesOriginalLibraryAndAppearanceReadiness() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        ReadinessProbe(graph).use {probe->
            readinessAttempt({
                graph.session.retire()
                compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
                compose.onNodeWithContentDescription("Email").performTextInput("readiness@example.test")
                compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
                compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
                compose.waitUntil(10000){graph.library.state.value.rows.size>=3&&graph.appearancePreferences.state.value.ready}
                compose.runOnIdle {check(ViewModelProvider(compose.activity)[ProductViewModel::class.java].graph===graph)}
            },probe::snapshot,{android.util.Log.i("NativeReadiness",it)})
        }
    }
}
