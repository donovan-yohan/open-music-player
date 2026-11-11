package com.soundq.android

import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.imports.*
import com.soundq.android.product.imports.ImportsScreen
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Native consuming-layout proof. Compile-only in the imports lane; run with the capture owner. */
class ImportPresentationTest {
    @get:Rule val compose=createComposeRule()
    @Test fun recentImportRowsTouchWhileFormRetainsItsInsetAndIdsStayInDetails() {
        val first=ImportJob(ImportJobId("123e4567-e89b-12d3-a456-426614174071"),ImportStatus.Complete,100,TrackId(71),"youtube")
        val second=ImportJob(ImportJobId("123e4567-e89b-12d3-a456-426614174072"),ImportStatus.Downloading,25,null,"soundcloud")
        val state=ImportsState(selected=first,recent=listOf(first,second))
        compose.setContent {SoundQTheme {Box(Modifier.width(360.dp).height(1200.dp)) {
            ImportsScreen(state,{}, {}, {}, {}, {}, {}, {}, {}, {})
        }}}
        val field=compose.onNodeWithContentDescription("Source URL").fetchSemanticsNode().boundsInRoot
        compose.onNodeWithContentDescription("Account and settings").assertExists()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("SoundCloud import"))
        val youtube=compose.onNode(hasText("YouTube import") and hasClickAction()).fetchSemanticsNode().boundsInRoot
        val soundcloud=compose.onNode(hasText("SoundCloud import") and hasClickAction()).fetchSemanticsNode().boundsInRoot
        assertEquals(0f,youtube.left,1f)
        assertEquals(youtube.left,soundcloud.left,0.1f)
        assertEquals(youtube.right,soundcloud.right,0.1f)
        assertEquals("A page gutter or inter-row gap returned",youtube.bottom,soundcloud.top,0.1f)
        assertTrue(field.left>youtube.left)
        compose.onNodeWithText("Added to server Library").assertDoesNotExist()
        compose.onNodeWithText(first.id.value).assertDoesNotExist()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription("Import details"))
        compose.onNodeWithContentDescription("Import details").performClick()
        compose.onNode(hasText(first.id.value,substring=true)).assertExists()
    }
    @Test fun uncertainSubmissionCannotBeSubmittedAgain() {
        var submits=0
        compose.setContent {SoundQTheme {
            ImportsScreen(ImportsState(consumed=true,pending=true),{}, {submits++}, {}, {}, {}, {}, {}, {}, {})
        }}
        compose.onNodeWithText("Import").assertIsNotEnabled()
        assertEquals(0,submits)
        compose.onNodeWithText("Submitting import").assertExists()
    }
}
