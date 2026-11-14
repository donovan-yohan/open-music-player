package com.soundq.android

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
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

/** Actual ProductApp consumers. Auth/network are owned by ProductFixtureRunner.
 * Authored for the reserved native gate; NOT compiled/executed in the source-only lane.
 * Selection semantics are native input checks, not proof of a real IME composing session.
 */
class MainPageChromeJourneyTest {
    @get:Rule val compose=createComposeRule()
    private val models=ViewModelStore()
    @After fun closeModel(){compose.runOnIdle {models.clear()}}

    @Test fun ordinary320RealConsumers()=journey(320,1f)
    @Test fun ordinary412RealConsumers()=journey(412,1f)
    @Test fun enlarged320RealConsumers()=journey(320,2f)
    @Test fun enlarged412RealConsumers()=journey(412,2f)

    private fun journey(width:Int,scale:Float) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val model=compose.runOnIdle {ProductViewModel(app).also {models.put("main-chrome",it)}}
        compose.setContent {
            val density=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density,scale)) {
                Box(Modifier.requiredWidth(width.dp)){ProductApp(model)}
            }
        }
        compose.signInThroughSettings("main-chrome@example.test","test-only-password"){app.graph.session.state.value is AuthState.SignedIn}
        compose.waitUntil(10000){!model.library.value.loading}
        val before=model.playback.value
        val heading=SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)
        fun title(page:String)=compose.onNode(hasText(page) and heading)
        fun layout(page:String):TextLayoutResult {
            val values=mutableListOf<TextLayoutResult>()
            title(page).assertIsDisplayed().performSemanticsAction(SemanticsActions.GetTextLayoutResult){it(values)}
            return values.single()
        }
        val reference=layout("Library").layoutInput.style
        for(page in listOf("Home","Discover","Playlists","Library")) {
            compose.onAllNodes(hasText(page) and hasClickAction()).filterToOne(!heading).performClick()
            compose.waitUntil(10000){compose.onAllNodes(hasText(page) and heading).fetchSemanticsNodes().size==1}
            val actual=layout(page).layoutInput.style
            assertEquals("$page uses Library title size",reference.fontSize,actual.fontSize)
            assertEquals("$page uses Library title weight",reference.fontWeight,actual.fontWeight)
        }
        compose.onAllNodes(hasText("Discover") and hasClickAction()).filterToOne(!heading).performClick()
        val discover=compose.onNode(hasContentDescription("Music search query") and hasSetTextAction())
        compose.onNodeWithTag("search-placeholder:Music search query",useUnmergedTree=true).assertIsDisplayed()
        discover.performTextReplacement(" ")
        compose.onNodeWithTag("search-placeholder:Music search query",useUnmergedTree=true).assertDoesNotExist()
        discover.performTextInputSelection(TextRange(0,1))
        discover.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange,TextRange(0,1)))
        compose.onNodeWithContentDescription("Clear search").performClick()
        discover.assert(SemanticsMatcher.expectValue(SemanticsProperties.EditableText,AnnotatedString(""))).assertIsFocused()
        compose.onAllNodes(hasText("Playlists") and hasClickAction()).filterToOne(!heading).performClick()
        compose.waitUntil(10000){!model.playlists.value.loading}
        val query=compose.runOnIdle {model.playlists.value.query}
        val playlist=compose.onNode(hasContentDescription("Playlist search query") and hasSetTextAction())
        playlist.performTextReplacement("native query")
        playlist.performTextInputSelection(TextRange(1,4))
        playlist.assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange,TextRange(1,4)))
        compose.runOnIdle {assertEquals("Editing stays local",query,model.playlists.value.query)}
        playlist.performImeAction()
        compose.waitUntil(10000){model.playlists.value.query.text=="native query"&&!model.playlists.value.loading}
        compose.onNodeWithContentDescription("Clear playlist search").performClick()
        compose.waitUntil(10000){model.playlists.value.query.text.isEmpty()&&!model.playlists.value.loading}
        compose.runOnIdle {
            assertEquals(query.sort,model.playlists.value.query.sort)
            assertEquals(query.ascending,model.playlists.value.query.ascending)
            assertEquals(before.queue,model.playback.value.queue)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertEquals(before.isPlaying,model.playback.value.isPlaying)
        }
    }
}
