package com.soundq.android

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.product.ProductApp
import com.soundq.android.product.ProductViewModel
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real ProductApp Library route with controlled width/font scale and the startup fixture graph.
 * NOT compiled or run in the source/host-only phase. ProductFixtureRunner owns transport setup.
 * Native bounds/semantics checks are not a substitute for inspecting the eventual captures. */
class LibraryChromeJourneyTest {
    @get:Rule val compose=createComposeRule()
    private val models=ViewModelStore()
    @After fun closeModel(){compose.runOnIdle {models.clear()}}

    // Independent identity union: Server excludes phone files, not owned downloads.
    private fun expectedServerCount(model:ProductViewModel):Int {
        val library=model.library.value
        val scope=requireNotNull(model.graph.library.projectionScope(library))
        val query=library.query
        val acknowledged=library.rows.map {it.id}.toSet()
        val ids=library.rows.filter {(!query.liked||it.liked==true)&&query.collection?.contains(it)!=false}.map {it.id}.toMutableSet()
        for(row in model.downloads.value.rows) {
            val track=row.track
            if(track.id in acknowledged||!model.graph.downloads.ownsComplete(scope,row))continue
            // Download-only metadata cannot establish server genre/verification matches.
            if(query.genre.isNotBlank()||query.verified!=null)continue
            if(query.liked&&track.liked!=true||query.collection?.contains(track)==false)continue
            val text=query.text.trim()
            if(text.isNotEmpty()&&listOf(track.title,track.artist,track.album).none {it.contains(text,true)})continue
            ids.add(track.id)
        }
        return ids.size
    }

    @Test fun normal320PlaceholderAndContentFitTabs()=journey(320,1f)
    @Test fun normal412PlaceholderAndContentFitTabs()=journey(412,1f)
    @Test fun enlarged320PlaceholderAndContentFitTabs()=journey(320,2f)
    @Test fun enlarged412PlaceholderAndContentFitTabs()=journey(412,2f)

    private fun journey(width:Int,scale:Float) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        val model=compose.runOnIdle {ProductViewModel(app).also {models.put("chrome",it)}}
        var pixelsPerDp=0f
        var gutterDp=0f
        compose.setContent {
            val density=LocalDensity.current
            pixelsPerDp=density.density
            gutterDp=com.soundq.designsystem.SoundQ.spacing.gutter.value
            CompositionLocalProvider(LocalDensity provides Density(density.density,scale)) {
                Box(Modifier.requiredWidth(width.dp)){ProductApp(model)}
            }
        }
        compose.signInThroughSettings("library-chrome@example.test","test-only-password"){graph.session.state.value is AuthState.SignedIn}
        compose.waitUntil(10000){!model.library.value.loading&&model.library.value.error==null}
        // Server excludes phone files; the count also includes eligible owned downloads.
        compose.selectLibrarySource("Server")
        compose.waitUntil(10000){!model.library.value.loading&&model.library.value.error==null}
        val queueBefore=model.playback.value.queue
        val playingBefore=model.playback.value.isPlaying
        val editor=compose.onNode(hasContentDescription("Library search query") and hasSetTextAction())
        // Always address the editor by purpose, not by the empty-only placeholder.
        compose.onNodeWithContentDescription("Clear library search").let {clear->
            if(model.library.value.query.text.isNotEmpty())clear.performClick()
        }
        editor.assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText,androidx.compose.ui.text.AnnotatedString("")))
        val search=compose.onNodeWithContentDescription("Search library").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val placeholder=compose.onNodeWithTag("search-placeholder:Library search query",useUnmergedTree=true).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertEquals("Placeholder shares the search row's vertical center",search.center.y,placeholder.center.y,1f)
        editor.performTextReplacement("Fixture")
        compose.onNodeWithTag("search-placeholder:Library search query",useUnmergedTree=true).assertDoesNotExist()
        compose.runOnIdle {assertEquals("Typing must not submit", "",model.library.value.query.text)}
        editor.performImeAction()
        compose.waitUntil(10000){model.library.value.query.text=="Fixture"&&!model.library.value.loading}
        editor.assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText,androidx.compose.ui.text.AnnotatedString("Fixture")))
        compose.onNodeWithContentDescription("Clear library search").performClick()
        compose.waitUntil(10000){model.library.value.query.text.isEmpty()&&!model.library.value.loading}
        compose.onNodeWithTag("search-placeholder:Library search query",useUnmergedTree=true).assertIsDisplayed()

        val tabRole=SemanticsMatcher.expectValue(SemanticsProperties.Role,Role.Tab)
        fun tab(label:String)=compose.onNode(hasText(label) and tabRole)
        val all=tab("All").assertIsSelected().assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp).fetchSemanticsNode().boundsInRoot
        val liked=tab("Liked").assertIsNotSelected().assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp).fetchSemanticsNode().boundsInRoot
        for((label,cell) in listOf("All" to all,"Liked" to liked)) {
            val text=compose.onNode(hasText(label) and hasAnyAncestor(tabRole),useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
            assertEquals("$label centered horizontally",cell.center.x,text.center.x,1f)
            assertEquals("$label centered vertically",cell.center.y,text.center.y,1f)
            assertEquals("$label fits text plus symmetric gutter, not equal-width allocation",maxOf(48f*pixelsPerDp,text.width+2f*gutterDp*pixelsPerDp),cell.width,1f)
        }
        assertEquals("Touching tab boundary",all.right,liked.left,1f)
        compose.onNodeWithText("All tracks").assertDoesNotExist()
        val refine=compose.onNodeWithContentDescription("Refine library").assertIsDisplayed().assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
        val refineBounds=refine.fetchSemanticsNode().boundsInRoot
        assertTrue("Unused room remains to the right of quick labels",liked.right<refineBounds.left)
        val total=compose.runOnIdle {expectedServerCount(model)}
        if(width/scale>=400) {
            val count=compose.onNodeWithText("$total tracks",useUnmergedTree=true).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            assertTrue("Count remains before the fixed Refine target",count.right<=refineBounds.left+1f)
        }
        if(width>=400&&width/scale<400)compose.onNodeWithText("$total tracks",useUnmergedTree=true).assertDoesNotExist()
        tab("Liked").performClick()
        compose.waitUntil(10000){model.library.value.query.liked&&!model.library.value.loading}
        tab("Liked").assertIsSelected()
        tab("All").performClick()
        compose.waitUntil(10000){!model.library.value.query.liked&&!model.library.value.loading}
        refine.performClick()
        compose.onNodeWithText("Source").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Cancel").performScrollTo().performClick()
        compose.runOnIdle {assertSame(graph,app.graph);assertEquals(queueBefore,model.playback.value.queue);assertEquals(playingBefore,model.playback.value.isPlaying)}
    }
}
