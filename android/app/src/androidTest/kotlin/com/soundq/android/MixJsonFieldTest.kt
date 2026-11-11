package com.soundq.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.product.mix.MixJsonField
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Native component checks. Compilation does not establish executed editor acceptance. */
class MixJsonFieldTest {
    @get:Rule val compose=createComposeRule()

    @Test fun multilineInputAndSelectionSurvivePendingReadOnlyAndReturnToEditing() {
        var value by mutableStateOf(TextFieldValue())
        var readOnly by mutableStateOf(false)
        var changes=0
        compose.setContent {SoundQTheme {MixJsonField(value,{value=it;changes++},readOnly=readOnly)}}
        val editor=compose.onNodeWithContentDescription("Mix JSON")
        val raw=" \n{\"name\":\"Été 😀\",\n  \"clips\":[]}\n"
        editor.assertIsDisplayed().assertIsEnabled().performTextReplacement(raw)
        editor.performTextInputSelection(TextRange(3,12))
        val before=compose.runOnIdle {assertEquals(raw,value.text);assertEquals(TextRange(3,12),value.selection);value}
        val node=editor.fetchSemanticsNode().id
        val beforeChanges=changes
        compose.runOnIdle {readOnly=true}
        editor.assertIsDisplayed().assertIsEnabled().assertTextContains(raw)
        assertEquals(node,editor.fetchSemanticsNode().id)
        compose.runOnIdle {assertEquals(before,value);assertEquals(beforeChanges,changes)}
        // Read-only is not disabled. Native selection and copy remain available.
        editor.performTextInputSelection(TextRange(0,2))
        compose.runOnIdle {assertEquals(raw,value.text);assertEquals(TextRange(0,2),value.selection)}
        compose.runOnIdle {readOnly=false}
        editor.performTextReplacement(raw+" ")
        compose.runOnIdle {assertEquals(raw+" ",value.text)}
    }

    @Test fun validationDoesNotReplaceOrTruncateTheNativeDraft() {
        val raw="é".repeat(131073)
        var value by mutableStateOf(TextFieldValue(raw,TextRange(4,9)))
        var error by mutableStateOf<String?>(null)
        compose.setContent {SoundQTheme {MixJsonField(value,{value=it},error=error)}}
        val editor=compose.onNodeWithContentDescription("Mix JSON")
        compose.runOnIdle {error="Mix metadata must be 256 KiB or smaller."}
        compose.onNodeWithText("Mix metadata must be 256 KiB or smaller.").assertExists()
        editor.assertIsEnabled()
        compose.runOnIdle {assertEquals(raw,value.text);assertEquals(TextRange(4,9),value.selection)}
        compose.runOnIdle {error=null}
        compose.onNodeWithText("Maximum 256 KiB of UTF-8 metadata.").assertExists()
        compose.runOnIdle {assertEquals(raw,value.text)}
    }
}
