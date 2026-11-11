package com.soundq.android

import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.product.LibraryNearBottomPagination
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Retain the original failure and attach metadata before the fixture retires its owner. */
internal fun paginationAttempt(wait:()->Unit,snapshot:()->String) {
    try {wait()} catch(primary:Throwable) {
        try {primary.addSuppressed(AssertionError("Pagination observation: ${snapshot()}"))}
        catch(diagnostic:Throwable) {primary.addSuppressed(diagnostic)}
        throw primary
    }
}

/** Real LazyList layout, recomposition and disposal. No fixture network or product state writes. */
class LibraryPaginationObserverTest {
    @get:Rule val compose=createComposeRule()
    private fun page()=LibraryState(rows=(1L..30L).map {Track(TrackId(it),"Track $it")},total=90,nextOffset=30,pageRevision=1)

    @Test fun scrollPrefetchIsOncePerPageAndUnchangedRecompositionDoesNotRepeat() {
        val library=mutableStateOf(page());val enabled=mutableStateOf(true)
        val callbacks=mutableListOf<Pair<LibraryState,()->Boolean>>()
        compose.setContent {
            val scroll=rememberLazyListState()
            LibraryNearBottomPagination(scroll,library.value,"account-A",enabled.value,{enabled.value},{state,valid->callbacks+=state to valid})
            LazyColumn(Modifier.height(160.dp).testTag("library"),state=scroll) {
                items(library.value.rows,key={it.id.value}){Text(it.title,Modifier.height(40.dp))}
            }
        }
        compose.runOnIdle {assertTrue(callbacks.isEmpty())}
        compose.onNodeWithTag("library").performScrollToIndex(25)
        compose.waitUntil(5000){callbacks.size==1}
        compose.runOnIdle {
            assertTrue(callbacks.single().second())
            library.value=library.value.copy(mutations=mapOf(TrackId(1) to MutationOutcome.Refused))
        }
        compose.waitForIdle();compose.runOnIdle {assertEquals(1,callbacks.size)}
        compose.runOnIdle {enabled.value=false}
        compose.waitForIdle();compose.runOnIdle {assertFalse(callbacks.single().second())}
        compose.runOnIdle {enabled.value=true}
        compose.waitUntil(5000){callbacks.size==2}
        compose.runOnIdle {assertFalse(callbacks.first().second());assertTrue(callbacks.last().second())}
        compose.runOnIdle {library.value=library.value.copy(error=SafeFailure.Reason.Network)}
        compose.waitForIdle();compose.runOnIdle {assertEquals(2,callbacks.size)}
    }

    @Test fun removalPermanentlyRetiresCapturedPredicateAndRemountRenewsIntent() {
        val mounted=mutableStateOf(true);val callbacks=CopyOnWriteArrayList<()->Boolean>()
        val callbackObservations=CopyOnWriteArrayList<String>()
        var observedScroll:LazyListState?=null
        var observedLifecycle:Lifecycle?=null
        var compositions=0
        var stage="first-mount"
        fun snapshot():String {
            val json=JSONObject().put("stage",stage).put("callbackCount",callbacks.size)
                .put("enabled",true).put("callerCurrent",true).put("rows",1).put("total",2)
                .put("nextOffset",1).put("pageRevision",1).put("loading",false)
                .put("error",JSONObject.NULL).put("endReached",false)
                .put("callbacks",JSONArray(callbackObservations.take(16)))
            try {
                InstrumentationRegistry.getInstrumentation().runOnMainSync {
                    val layout=observedScroll?.layoutInfo
                    json.put("mounted",mounted.value).put("compositions",compositions)
                        .put("lifecycle",observedLifecycle?.currentState?.name ?: JSONObject.NULL)
                        .put("resumed",observedLifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) ?: false)
                        .put("totalItems",layout?.totalItemsCount ?: JSONObject.NULL)
                        .put("lastVisible",layout?.visibleItemsInfo?.lastOrNull()?.index ?: JSONObject.NULL)
                        .put("callbackValidity",JSONArray(callbacks.take(16).map {it()}))
                }
            } catch(diagnostic:Throwable) {json.put("mainObservationFailure",diagnostic.javaClass.name)}
            return json.toString()
        }
        compose.setContent {
            if(mounted.value) {
                val state=LibraryState(rows=listOf(Track(TrackId(1),"One")),total=2,nextOffset=1,pageRevision=1)
                val scroll=rememberLazyListState()
                val lifecycle=LocalLifecycleOwner.current.lifecycle
                SideEffect {observedScroll=scroll;observedLifecycle=lifecycle;compositions++}
                LibraryNearBottomPagination(scroll,state,"account-A",true,{true},{_,valid->
                    callbacks+=valid
                    if(callbackObservations.size<16)callbackObservations.add(
                        "count=${callbacks.size},current=${valid()},lifecycle=${lifecycle.currentState.name},compositions=$compositions")
                })
                LazyColumn(Modifier.height(160.dp),state=scroll){items(state.rows){Text(it.title,Modifier.height(40.dp))}}
            }
        }
        paginationAttempt({
            compose.waitUntil(5000){callbacks.size==1}
            compose.runOnIdle {assertTrue(callbacks.single()());mounted.value=false}
            stage="removed"
            compose.waitForIdle();compose.runOnIdle {assertFalse(callbacks.single()());mounted.value=true}
            stage="remounted"
            compose.waitUntil(5000){callbacks.size==2}
            compose.runOnIdle {assertFalse(callbacks[0].invoke());assertTrue(callbacks[callbacks.lastIndex].invoke())}
        },::snapshot)
    }
}
