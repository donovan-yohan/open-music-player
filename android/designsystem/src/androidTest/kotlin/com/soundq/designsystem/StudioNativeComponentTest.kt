package com.soundq.designsystem

import android.graphics.Bitmap
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import soundq.design.generated.SoundQAppearance

/** Native component host; no production Activity security flags are changed. */
class StudioNativeComponentTest {
    @get:Rule val compose = createComposeRule()

    @Test fun captureNativeComponentMatrix() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        assumeTrue("Native studio capture requires explicit opt-in", arguments.containsKey("studioRequestFile"))
        val requestFile = arguments.getString("studioRequestFile")
        require(requestFile == "studio-render-request.json") { "Pass the fixed private request filename as studioRequestFile" }
        val request = JSONObject(File(instrumentation.context.filesDir, requestFile).readText(Charsets.UTF_8))
        // This asset is stamped in the private source snapshot BEFORE compilation.
        // The request is an expectation, never the authority for compiled-source identity.
        val build = instrumentation.context.assets.open("studio-build.json").bufferedReader().use { JSONObject(it.readText()) }
        assertEquals(1, build.getInt("schema"))
        assertEquals("isolated-source-snapshot", build.getString("build_mode"))
        val compiledSources = build.getJSONObject("sources")
        val requestedSources = request.getJSONObject("sources")
        assertEquals("Compiled/request source keys differ", compiledSources.keys().asSequence().toSet(), requestedSources.keys().asSequence().toSet())
        compiledSources.keys().forEach { key ->
            assertEquals("Compiled source $key differs; rebuild the isolated capture APK", requestedSources.getString(key), compiledSources.getString(key))
        }
        val config = instrumentation.targetContext.resources.configuration
        val environment = JSONObject()
            .put("sdk", Build.VERSION.SDK_INT).put("fingerprint", Build.FINGERPRINT)
            .put("model", Build.MODEL).put("density", 2).put("fontScale", 1)
            .put("locale", config.locales[0].toLanguageTag())
            .put("renderer", "compose-captureToImage").put("widthDp", 360)
        val expectedEnvironment = request.getJSONObject("environment")
        assertEquals("Environment keys differ", environment.keys().asSequence().toSet(), expectedEnvironment.keys().asSequence().toSet())
        environment.keys().forEach { key -> assertEquals("Environment $key changed", expectedEnvironment.get(key).toString(), environment.get(key).toString()) }
        val cases = JSONArray()
        val expectedCases = (0 until request.getJSONArray("cases").length()).map { request.getJSONArray("cases").getString(it) }
        val all = listOf("light", "dark").flatMap { mode -> listOf("default", "disabled", "focused", "large-text").map { state -> "components-$mode-$state" } }
        assertEquals(all, expectedCases)
        val output = File(instrumentation.targetContext.filesDir, "design-studio").apply { mkdirs() }
        File(output, "receipt.json").delete() // interrupted runs must not retain a complete receipt
        var caseId by mutableStateOf(all.first())
        val focus = FocusRequester()
        compose.setContent {
            val dark = caseId.contains("-dark-")
            val enabled = !caseId.endsWith("-disabled")
            key(caseId) { CompositionLocalProvider(LocalDensity provides Density(2f, if (caseId.endsWith("large-text")) 2f else 1f)) {
                SoundQTheme(reducedMotion = true, appearance = if (dark) SoundQAppearance.Dark else SoundQAppearance.Light) {
                    Column(Modifier.requiredSize(360.dp, 600.dp).testTag("studio-capture")
                        .background(SoundQ.colors.background).padding(SoundQ.spacing.medium),
                        verticalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) {
                        SoundQButton("Apply history filters", {}, enabled = enabled)
                        SoundQTextField("Recent", {}, "History search", modifier = Modifier.focusRequester(focus), enabled = enabled)
                        SoundQTabs(listOf("All", "Listened", "Skipped"), 0, {})
                        SoundQMediaRow("Listening history", "Local native component fixture", true, {}, {}, supporting = "Listened", enabled = enabled)
                        SoundQIconButton(SoundQIcon.Search, "Search history", {}, enabled = enabled)
                    }
                }
            } }
        }
        for (id in all) {
            compose.runOnIdle { caseId = id }
            compose.waitForIdle()
            if (id.endsWith("-focused")) {
                compose.runOnIdle { focus.requestFocus() }
                compose.onNode(hasSetTextAction()).assertIsFocused()
            }
            if (id.endsWith("-disabled")) compose.onNodeWithText("Apply history filters").assertIsNotEnabled()
            compose.waitForIdle()
            // captureToImage reads the mounted component layer, not a secure Activity screenshot.
            val bitmap = compose.onNodeWithTag("studio-capture").captureToImage().asAndroidBitmap()
            assertEquals(720, bitmap.width)
            assertEquals(1200, bitmap.height)
            val file = File(output, "$id.png")
            file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            val hash = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it.toInt() and 255) }
            cases.put(JSONObject().put("id", id).put("file", file.name).put("sha256", hash))
        }
        File(output, "receipt.json").writeText(JSONObject().put("schema", 1)
            .put("kind", "android-compose-native").put("producer", "StudioNativeComponentTest.captureNativeComponentMatrix")
            .put("sources", compiledSources).put("build_binding", build).put("environment", environment)
            .put("cases", cases).toString(2))
    }
}
