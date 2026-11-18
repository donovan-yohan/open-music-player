package com.soundq.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import com.soundq.android.data.playlists.*
import com.soundq.android.product.playlists.PlaylistDetailScreen
import com.soundq.designsystem.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Production detail, rows, sheet and real repository action owners in a bounded phone host.
 * Only the API response is intercepted; no provider, disk, service or audio is exercised.
 * Authored for parent-owned native execution. This is not an installed-app acceptance receipt. */
class PlaylistDetailSurfaceTest {
    @get:Rule val compose=createComposeRule()
    private enum class Branch { Private, Public, ReadOnly, Mixed }

    private class Fixture(public:Boolean=false) : AutoCloseable {
        val requests=mutableListOf<String>()
        val jobs=mutableListOf<()->Unit>()
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens) {}
            override fun clear() {}
        })
        val tracks=(1L..39L).map {Track(TrackId(it),"Surface song $it","Synthetic artist",durationMs=12000)}
        val client=OkHttpClient.Builder().addInterceptor {chain->
            val request=chain.request()
            check(request.method=="GET"&&request.url.encodedPath=="/api/v1/playlists/41")
            requests.add("GET /api/v1/playlists/41")
            val body=buildJsonObject {
                put("id",41);put("name","Surface playlist");put("description","Playlist description")
                put("isPublic",public);put("canManage",true);put("trackCount",39);put("durationMs",468000)
                put("tracks",buildJsonArray {tracks.forEach {track->add(buildJsonObject {
                    put("id",track.id.value);put("title",track.title);put("artist",track.artist);put("durationMs",track.durationMs)
                })}})
            }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("Synthetic fixture")
                .body(body.toString().toResponseBody("application/json".toMediaType())).build()
        }.build()
        val api=SoundQApi(session,client)
        val detail=PlaylistDetailRepository(api)
        val management=PlaylistManagementRepository(api,detail)
        val order=PlaylistOrderRepository(api,detail)
        val actions:PlaylistManagementActions
        val orderActions:PlaylistOrderActions
        init {
            check(session.accept(session.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","surface-owner")))
            detail.open(PlaylistId(41))
            check(detail.state.value.detail?.tracks?.size==39)
            actions=PlaylistManagementActions(management) {jobs.add(it)}
            orderActions=PlaylistOrderActions(order) {jobs.add(it)}
        }
        override fun close() {
            actions.close();orderActions.close();detail.retire();session.revoke()
            client.dispatcher.executorService.shutdown();client.connectionPool.evictAll()
        }
    }

    private fun mount(f:Fixture,branch:Branch,fontScale:Float=1f,onPlayed:(TrackId)->Unit={},onQueued:(TrackId)->Unit={}) {
        val accepted=f.detail.state.value
        val capture=f.detail.capturePlayback()!!
        val plan=if(branch==Branch.Mixed)SavedMix("123e4567-e89b-12d3-a456-426614174041",1,"Surface Blend",f.tracks.mapIndexed {index,track->
            MixJson.clip(buildJsonObject {
                put("clipId","clip-$index");put("queueItemId","occurrence-$index");put("trackId",track.id.value)
                put("sourceStartMs",0);put("sourceEndMs",12000);put("timelineStartMs",index*12000)
            })
        }) else null
        compose.setContent {
            val context=androidx.compose.ui.platform.LocalContext.current
            val configuration=androidx.compose.ui.platform.LocalConfiguration.current
            // Material3 creates the dialog from LocalView.current.context, not LocalContext.
            // Attach a real scaled-context host so the dialog's own density is scaled too.
            val scaledContext=remember(context,configuration,fontScale) {context.createConfigurationContext(
                android.content.res.Configuration(configuration).apply {this.fontScale=fontScale})}
            androidx.compose.ui.viewinterop.AndroidView(
                modifier=Modifier.width(360.dp).height(780.dp),
                factory={androidx.compose.ui.platform.ComposeView(scaledContext).apply {
                    setContent {SoundQTheme {
                        val management by f.management.state.collectAsState()
                        val order by f.order.state.collectAsState()
                        Column(Modifier.width(360.dp).height(780.dp).background(SoundQ.colors.background).testTag("phone-host")) {
                            Box(Modifier.weight(1f).fillMaxWidth()) {
                                PlaylistDetailScreen(accepted,capture,{}, {},
                                    onPlay={owner,id->f.detail.play(owner,id) {_,_->onPlayed(id)}},
                                    management=management,actions=if(branch==Branch.ReadOnly)null else f.actions,
                                    order=order,orderActions=if(branch==Branch.ReadOnly)null else f.orderActions,
                                    blend=PlaylistBlendState(status=if(plan!=null)BlendStatus.Ready else BlendStatus.Plain,enabled=plan!=null),plan=plan,
                                    onQueue={owner,index,track,valid->if(valid())f.detail.queue(owner,index,track) {onQueued(it.id)}})
                            }
                            // Parent-owned transport boundary, not another list implementation.
                            Box(Modifier.fillMaxWidth().height(72.dp).testTag("parent-player")) {Text("Persistent player")}
                        }
                    }}
                }})
        }
    }

    private fun list()=compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange) and !hasAnyAncestor(isDialog()))
    private fun row(title:String)=hasClickAction() and hasText(title) and hasAnyDescendant(hasContentDescription("More for $title"))
    private fun action(text:String)=compose.onNode(hasText(text) and hasClickAction() and hasAnyAncestor(isDialog()))
    private fun viewport(branch:Branch,fontScale:Float=1f) {
        Fixture(branch==Branch.Public).use {f->
            mount(f,branch,fontScale)
            compose.onAllNodes(hasScrollAction() and !hasAnyAncestor(isDialog())).assertCountEquals(1)
            val viewport=list().fetchSemanticsNode().boundsInRoot
            val player=compose.onNodeWithTag("parent-player").fetchSemanticsNode().boundsInRoot
            val controlsBottom=maxOf(compose.onNodeWithContentDescription("Play playlist").fetchSemanticsNode().boundsInRoot.bottom,
                compose.onNodeWithContentDescription("Plain listening").fetchSemanticsNode().boundsInRoot.bottom)
            assertEquals("Actual list must meet the parent player, with no sheet-height gap",player.top,viewport.bottom,1f)
            assertEquals(360f*compose.density.density,viewport.width,1f)
            assertEquals("Body begins directly below fixed listening controls",controlsBottom,viewport.top,1f)
            assertEquals("Body consumes all remaining height",player.top-controlsBottom,viewport.height,1f)
            compose.waitForIdle()
            captureListeningStage("playlist-${branch.name}-${if(fontScale>1f)"enlarged" else "normal"}-first")
            list().performScrollToNode(row("Surface song 39"))
            val last=compose.onNode(row("Surface song 39")).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            assertTrue(last.top>=viewport.top)
            assertEquals("Last member is fully reachable directly above the player",player.top,last.bottom,1f)
            compose.onNodeWithContentDescription("Back to playlists").assertIsDisplayed()
            if(branch==Branch.Private)compose.onNodeWithContentDescription("Reorder Surface song 39").assertIsDisplayed()
            else compose.onAllNodesWithContentDescription("Reorder Surface song 39").assertCountEquals(0)
            if(branch==Branch.ReadOnly)compose.onAllNodesWithContentDescription("Playlist actions").assertCountEquals(0)
            assertEquals(listOf("GET /api/v1/playlists/41"),f.requests)
            assertTrue(f.jobs.isEmpty())
            compose.waitForIdle()
            captureListeningStage("playlist-${branch.name}-${if(fontScale>1f)"enlarged" else "normal"}-last")
        }
    }

    @Test fun privatePlainListFillsViewportAndReachesLastMember()=viewport(Branch.Private)
    @Test fun enlargedPrivatePlainListFillsViewportAndReachesLastMember()=viewport(Branch.Private,1.6f)
    @Test fun publicListKeepsItsNonReorderBranchAndLastMember()=viewport(Branch.Public)
    @Test fun readOnlyListKeepsItsActionsFencedAndLastMember()=viewport(Branch.ReadOnly)
    @Test fun mixedListKeepsItsOccurrenceBranchAndLastMember()=viewport(Branch.Mixed)

    @Test fun heldGripEdgeScrollAndCancellationKeepTheFullHeightOwner() {
        Fixture().use {f->
            mount(f,Branch.Private)
            val viewport=list().fetchSemanticsNode().boundsInRoot
            val grip=compose.onNodeWithContentDescription("Reorder Surface song 1")
            val origin=grip.fetchSemanticsNode().boundsInRoot
            fun offset()=list().fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value()
            val before=offset()
            var held=false
            var failure:Throwable?=null
            try {
                compose.mainClock.autoAdvance=false
                held=true
                grip.performTouchInput {down(center);moveBy(Offset(0f,viewport.bottom-origin.center.y-8.dp.toPx()),300)}
                repeat(30) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
                // Native user-scroll actions are intentionally disabled during grip ownership.
                compose.onAllNodes(hasScrollAction() and !hasAnyAncestor(isDialog())).assertCountEquals(0)
                assertTrue("A held grip near the actual bottom must scroll members",offset()>before)
                assertTrue("A held gesture must not dispatch a reorder",f.jobs.isEmpty())
                grip.performTouchInput {cancel()};held=false
                repeat(3) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
                assertTrue("Cancellation must not dispatch the preview",f.jobs.isEmpty())
            } catch(error:Throwable) {failure=error;throw error}
            finally {
                try {if(held)grip.performTouchInput {cancel()}}
                catch(error:Throwable) {failure?.addSuppressed(error) ?: throw error}
                finally {compose.mainClock.autoAdvance=true}
            }
            list().performScrollToNode(row("Surface song 39"))
            compose.onNode(row("Surface song 39")).assertIsDisplayed()
        }
    }

    @Test fun privateRowsKeepPlaySwipeMoreAndHeaderIndependentReorderOrdinals() {
        Fixture().use {f->
            val played=mutableListOf<TrackId>();val queued=mutableListOf<TrackId>()
            mount(f,Branch.Private,onPlayed={played.add(it)},onQueued={queued.add(it)})
            compose.onNode(row("Surface song 1")).performClick()
            assertEquals(listOf(TrackId(1)),played)
            val swipe=compose.onNode(SemanticsMatcher("first song swipe owner") {
                it.config.getOrNull(SemanticsActions.CustomActions)?.any {a->a.label=="Reveal actions for Surface song 1"}==true
            },useUnmergedTree=true)
            swipe.performTouchInput {down(Offset(width-1f,centerY));moveBy(Offset(-180.dp.toPx(),0f),300);up()}
            compose.waitForIdle()
            assertEquals(listOf(TrackId(1)),queued)
            compose.onNodeWithContentDescription("More for Surface song 1").performClick()
            compose.onNodeWithText("Move later").assertIsDisplayed()
            compose.onNodeWithText("Remove from playlist").assertIsDisplayed()
            compose.onNodeWithText("Move later").performClick()
            compose.runOnIdle {
                assertEquals(1,f.jobs.size)
                assertEquals(MutationOutcome.Pending,f.order.state.value.outcome)
                assertEquals(listOf(TrackId(2),TrackId(1))+f.tracks.drop(2).map {it.id},f.order.state.value.proposed)
                assertEquals(listOf(TrackId(1)),played)
                assertEquals(listOf(TrackId(1)),queued)
            }
        }
    }

    @Test fun playlistActionsTouchEdgesAdjoinAndKeepCapturedEditorsAndCancel()=menu(1f)
    @Test fun enlargedPlaylistActionsKeepFullTargetsAndCallbacks()=menu(1.6f)
    private fun menu(fontScale:Float) {
        Fixture().use {f->
            mount(f,Branch.Private,fontScale)
            fun open()=compose.onNodeWithContentDescription("Playlist actions").performClick()
            open()
            val names=listOf("Rename playlist","Select tracks","Delete playlist")
            names.forEach {name->
                val layouts=mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                compose.onNode(hasText(name) and hasAnyAncestor(isDialog()),useUnmergedTree=true)
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult){it(layouts)}
                assertEquals("The actual dialog label must use the requested font scale",fontScale,
                    layouts.single().layoutInput.density.fontScale,0.001f)
            }
            val bounds=names.map {action(it).assertIsEnabled().assertHeightIsAtLeast(56.dp).fetchSemanticsNode().boundsInRoot}
            val sheet=compose.onNode(hasScrollAction() and hasAnyAncestor(isDialog())).fetchSemanticsNode().boundsInRoot
            bounds.forEach {assertEquals(sheet.left,it.left,1f);assertEquals(sheet.right,it.right,1f)}
            bounds.zipWithNext().forEach {(a,b)->assertEquals("Action rows must adjoin",a.bottom,b.top,1f)}
            compose.waitForIdle()
            captureListeningStage("playlist-actions-${if(fontScale>1f)"enlarged" else "normal"}")
            action("Rename playlist").performClick()
            compose.onNodeWithContentDescription("Playlist name").assertIsDisplayed()
            action("Cancel").performScrollTo().performClick()
            open();action("Select tracks").performClick()
            compose.onNodeWithContentDescription("Close Select tracks").performClick()
            open();action("Delete playlist").performClick()
            compose.onNodeWithText("Delete playlist?").assertIsDisplayed()
            action("Cancel").performClick()
            assertTrue("Opening editors and cancelling confirmation never dispatches a write",f.jobs.isEmpty())
            open()
            compose.runOnIdle {f.actions.close()}
            // Retiring the owner cannot lend this captured menu another action admission.
            compose.onNodeWithContentDescription("Close Playlist actions").performClick()
            compose.onNodeWithContentDescription("Playlist actions").assertIsNotEnabled()
            names.forEach {action(it).assertDoesNotExist()}
            assertTrue(f.jobs.isEmpty())
        }
    }
}
