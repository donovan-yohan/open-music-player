package com.soundq.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Notification
import android.app.NotificationManager
import android.graphics.Rect
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Real SystemUI media controls; no direct PendingIntent/MediaController transport substitute. */
class SystemNotificationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun systemMediaCardPauseResumeAndReturnPreserveTheOrdinaryOccurrence() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        val automation=instrumentation.uiAutomation
        val automationInfo=checkNotNull(automation.serviceInfo)
        val automationFlags=automationInfo.flags
        val activity=compose.activity
        val launchIntent=compose.runOnIdle {android.content.Intent(activity.intent)}
        val fallback=ProductTransportFixture.server.dispatcher
        // A longer synthetic recording keeps natural EOF out of this system-control journey.
        val rate=16000;val frames=rate*60
        val audio=ByteBuffer.allocate(44+frames*2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36+frames*2).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16)
            put("data".toByteArray()).putInt(frames*2)
            repeat(frames){i->putShort((kotlin.math.sin(i*2*Math.PI*220/rate)*800).toInt().toShort())}
        }.array()
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path=="/api/v1/library")return MockResponse.Builder().body("""{"tracks":[{"id":1,"title":"System fixture song","artist":"Synthetic ensemble","duration_ms":60000,"is_liked":false}],"total":1,"limit":20,"offset":0}""").build()
                if(path=="/api/v1/playback/urls")return MockResponse.Builder().body("""{"urls":[{"trackId":1,"url":"${ProductTransportFixture.origin.resolve("/system-media/1.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":${audio.size}}]}""").build()
                if(path=="/system-media/1.wav") {
                    assertNull(request.headers["Authorization"])
                    val start=request.headers["Range"]?.substringAfter("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
                    val response=MockResponse.Builder().code(if(start>0)206 else 200).addHeader("Content-Type","audio/wav").addHeader("Accept-Ranges","bytes")
                    if(start>0)response.addHeader("Content-Range","bytes $start-${audio.size-1}/${audio.size}")
                    return response.body(Buffer().write(audio.copyOfRange(start.coerceIn(0,audio.size),audio.size))).build()
                }
                return fallback.dispatch(request)
            }
        }
        fun visible(node:AccessibilityNodeInfo):Boolean {
            val bounds=Rect();node.getBoundsInScreen(bounds)
            return node.isVisibleToUser&&!bounds.isEmpty
        }
        fun descendants(root:AccessibilityNodeInfo):List<AccessibilityNodeInfo> {
            val result=mutableListOf<AccessibilityNodeInfo>();val pending=java.util.ArrayDeque<AccessibilityNodeInfo>()
            pending.add(root)
            while(pending.isNotEmpty()) {
                check(result.size<2000){"SystemUI tree exceeds this bounded probe"}
                val node=pending.removeFirst();result.add(node)
                for(i in 0 until node.childCount)node.getChild(i)?.let(pending::add)
            }
            return result
        }
        fun mediaCard():AccessibilityNodeInfo? {
            for(window in automation.windows) {
                val root=window.root ?: continue
                if(root.packageName?.toString()!="com.android.systemui")continue
                val title=descendants(root).firstOrNull {visible(it)&&it.text?.toString()=="System fixture song"} ?: continue
                var ancestor:AccessibilityNodeInfo?=title
                repeat(10) {
                    val node=ancestor ?: return@repeat
                    val nodes=descendants(node)
                    if(nodes.any {it.contentDescription?.toString() in setOf("Pause","Play")&&it.isClickable&&visible(it)})return node
                    ancestor=node.parent
                }
            }
            return null
        }
        fun awaitSystemControl(label:String):AccessibilityNodeInfo {
            val deadline=SystemClock.uptimeMillis()+8000
            do {
                val control=mediaCard()?.let(::descendants)?.singleOrNull {
                    it.contentDescription?.toString()==label&&it.isClickable&&it.isEnabled&&visible(it)
                }
                if(control!=null)return control
                SystemClock.sleep(20)
            }while(SystemClock.uptimeMillis()<deadline)
            throw AssertionError("Visible enabled SystemUI media $label control was not published")
        }
        try {
            automationInfo.flags=automationFlags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            automation.serviceInfo=automationInfo
            compose.onNodeWithContentDescription("Email").performTextInput("system-notification@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){graph.library.state.value.rows.singleOrNull()?.title=="System fixture song"}
            val row=hasText("System fixture song")and hasClickAction()and hasAnyDescendant(hasContentDescription("More for System fixture song"))
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(row)
            compose.onNode(row).assertIsDisplayed().assertIsEnabled().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            val before=model.playback.value
            val manager=app.getSystemService(NotificationManager::class.java)
            compose.waitUntil(8000){manager.activeNotifications.any {n->n.packageName==app.packageName&&n.notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()=="System fixture song"&&n.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)}}
            assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS))
            // Android's actual media card can live in Quick Settings rather than the app row list.
            if(mediaCard()==null)assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS))
            assertTrue(awaitSystemControl("Pause").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            val paused=compose.settledPausedPlayback(model)
            compose.runOnIdle {
                assertEquals(before.queue,paused.projection.queue)
                assertEquals(before.selectedOccurrence,paused.projection.selectedOccurrence)
                assertFalse(paused.projection.isPlaying)
                assertActualPausedUnchanged(paused)
            }
            assertTrue(awaitSystemControl("Play").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.positionMs>paused.servicePositionMs}
            val card=checkNotNull(mediaCard())
            val title=descendants(card).single {visible(it)&&it.text?.toString()=="System fixture song"}
            var target:AccessibilityNodeInfo?=title
            while(target!=null&&!target!!.isClickable)target=target!!.parent
            val open=checkNotNull(target){"Media card title has no clickable return target"}
            assertTrue(open.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            compose.waitUntil(8000){compose.activity.lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)}
            compose.onNodeWithContentDescription("Pause").assertIsDisplayed().assertIsEnabled().performClick()
            val returned=compose.settledPausedPlayback(model)
            compose.runOnIdle {
                assertEquals(before.queue,returned.projection.queue)
                assertEquals(before.selectedOccurrence,returned.projection.selectedOccurrence)
                assertEquals("System fixture song",returned.projection.title)
                assertFalse(returned.projection.isPlaying)
            }
            assertEquals(1,manager.activeNotifications.count {it.packageName==app.packageName&&it.notification.extras.containsKey(Notification.EXTRA_MEDIA_SESSION)})
        } finally {
            try {
                instrumentation.runOnMainSync {activity.intent=launchIntent}
                automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            } finally {
                try {
                    automationInfo.flags=automationFlags
                    automation.serviceInfo=automationInfo
                } finally {ProductTransportFixture.server.dispatcher=fallback;graph.session.retire()}
            }
        }
    }
}
