package com.soundq.android

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.product.mix.*
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** State/action presentation only. Transport and ordinary routed acceptance are separate. */
class MixExchangeContentTest {
    @get:Rule val compose=createComposeRule()

    @Test fun chooseExposesOnlyAnActuallySavedExportAndImportDoesNotSubmitOnMount() {
        var saved by mutableStateOf<String?>(null)
        var imports=0;var exports=0;var submits=0
        compose.setContent {SoundQTheme {Column(Modifier.verticalScroll(rememberScrollState())) {
            MixExchangeContent(MixExchangePage.Choose,TextFieldValue(),{},savedName=saved,
                onChooseImport={imports++},onChooseExport={exports++},onImport={submits++})
        }}}
        compose.onNodeWithText("Import mix").assertIsEnabled()
        compose.onNodeWithText("Export saved mix").assertDoesNotExist()
        compose.runOnIdle {assertEquals(0,submits);saved="Saved performance"}
        compose.onNodeWithText("Export saved mix").performClick()
        compose.runOnIdle {assertEquals(1,exports);assertEquals(0,imports);assertEquals(0,submits)}
        compose.onNodeWithText("Import mix").performClick()
        compose.runOnIdle {assertEquals(1,imports);assertEquals(0,submits)}
    }

    @Test fun pendingImportPreservesDraftAndRequiresAnExplicitEnabledSubmit() {
        var draft by mutableStateOf(TextFieldValue(" \n{\"clips\":[]}\n"))
        var pending by mutableStateOf(false);var submits=0
        compose.setContent {SoundQTheme {Column(Modifier.verticalScroll(rememberScrollState())) {
            MixExchangeContent(MixExchangePage.Import,draft,{draft=it},busy=pending,canImport=true,onImport={submits++})
        }}}
        compose.runOnIdle {assertEquals(0,submits);pending=true}
        compose.onNodeWithText("Import mix").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Mix JSON").assertIsEnabled().assertTextContains(draft.text)
        compose.onNodeWithContentDescription("Back to mix exchange").assertIsNotEnabled()
        compose.runOnIdle {pending=false}
        compose.onNodeWithText("Import mix").performScrollTo().performClick()
        compose.runOnIdle {assertEquals(1,submits);assertEquals(" \n{\"clips\":[]}\n",draft.text)}
    }

    @Test fun pendingImportStillAllowsNativeSelectionWithoutRewritingText() {
        val raw=" {\"name\":\"Retained\"}\n"
        var draft by mutableStateOf(TextFieldValue(raw))
        compose.setContent {SoundQTheme {Column(Modifier.verticalScroll(rememberScrollState())) {
            MixExchangeContent(MixExchangePage.Import,draft,{draft=it},busy=true)
        }}}
        compose.onNodeWithContentDescription("Mix JSON").performTextInputSelection(androidx.compose.ui.text.TextRange(2,8))
        compose.runOnIdle {assertEquals(raw,draft.text);assertEquals(androidx.compose.ui.text.TextRange(2,8),draft.selection)}
        compose.onNodeWithText("Import mix").assertIsNotEnabled()
    }

    @Test fun exportCopyRequiresReadyPayloadAndNeverChangesImportDraft() {
        val raw=" {\"format\":\"soundq-mix\"}\n"
        var payload by mutableStateOf<String?>(null);var copied=0;var submitted=0
        val draft=TextFieldValue("private unsaved draft")
        compose.setContent {SoundQTheme {Column(Modifier.verticalScroll(rememberScrollState())) {
            MixExchangeContent(MixExchangePage.Export,draft,{},savedName="Saved performance",exportText=payload,
                onCopy={copied++},onImport={submitted++})
        }}}
        compose.onNodeWithText("Copy JSON").assertIsNotEnabled()
        compose.runOnIdle {assertEquals(0,copied);payload=raw}
        compose.onNodeWithContentDescription("Mix JSON").assertIsEnabled().assertTextContains(raw)
        compose.onNodeWithContentDescription("Mix JSON").performTextInputSelection(androidx.compose.ui.text.TextRange(2,8))
        compose.onNodeWithContentDescription("Mix JSON").assert(SemanticsMatcher.expectValue(
            androidx.compose.ui.semantics.SemanticsProperties.TextSelectionRange,androidx.compose.ui.text.TextRange(2,8)))
        compose.onNodeWithText("Copy JSON").performScrollTo().performClick()
        compose.runOnIdle {assertEquals(1,copied);assertEquals(0,submitted);assertEquals("private unsaved draft",draft.text)}
    }
}
