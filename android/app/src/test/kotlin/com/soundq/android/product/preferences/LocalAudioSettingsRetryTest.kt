package com.soundq.android.product.preferences

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.soundq.android.data.device.EnrichmentApplyBoundaryTest.Fixture
import com.soundq.android.data.device.EnrichmentApplyBoundaryTest.PermissionApplication
import com.soundq.android.data.device.PhoneAudioState
import com.soundq.android.data.deviceaudio.LocalDisplayText
import com.soundq.android.data.deviceaudio.MetadataApplyResult
import com.soundq.designsystem.SoundQSettingsScaffold
import com.soundq.designsystem.SoundQTheme
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The actual Local audio composable, button and refresh callback on a Robolectric Compose host. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = PermissionApplication::class, qualifiers = "w412dp-h915dp")
class LocalAudioSettingsRetryTest {
    @get:Rule val compose = createComposeRule()
    private val retry get() = compose.onNode(hasText("Try again") and hasClickAction())

    private fun mount(f: Fixture, visible: () -> Boolean = { true }) {
        // Capture the same session version at entry as SettingsHost's LocalAudio route.
        val version = f.graph.session.version()
        compose.setContent {
            SoundQTheme {
                if (visible()) SoundQSettingsScaffold("Local audio", {}) { LocalAudioDetail(f.graph, version) }
            }
        }
    }

    private fun abandonApply(f: Fixture): AbandonedApply = runBlocking {
        val visit = f.visit()
        val source = f.capture(visit)
        val change = LocalDisplayText("Recovered through Settings", null, null)
        val prior = f.disk.readBytes()
        f.fault = "afterReplace"
        val receipt = try { f.repo.applyEnrichment(source, change) { visit.active() } }
        finally { f.fault = null }
        assertTrue(receipt is MetadataApplyResult.Unconfirmed)
        val attempted = f.disk.readBytes()
        assertFalse(prior.contentEquals(attempted))
        val failed = f.refreshOnce()
        assertTrue(f.repo.current(f.graph.session.version()))
        assertTrue("This is a completed current-scope failure with access", failed.permission && !failed.refreshing && !failed.ready)
        assertNull(failed.snapshot)
        assertNotNull(failed.message)
        assertTrue(visit.active())
        visit.close()
        assertNull(f.repo.observed(f.repo.reference(visit.row)))
        assertEquals(1, f.replaces.get())
        AbandonedApply(visit.row, change, attempted)
    }

    @Test fun nullSnapshotTryAgainRepublishesExactAbandonedApply() {
        Fixture().use { f ->
            val attempt = abandonApply(f)
            mount(f)
            retry.assertIsDisplayed().assertIsEnabled()
            compose.onNodeWithText("Allowed").assertIsDisplayed()
            compose.onNodeWithText("Songs").assertDoesNotExist()
            compose.onNodeWithText("Scan again").assertDoesNotExist()
            // No implicit recovery when the route mounts or receives its initial Resume.
            assertNull(f.repo.state.value.snapshot)

            val release = CountDownLatch(1)
            f.app.query = {
                if (f.repo.state.value.refreshing) check(release.await(10, SECONDS))
                f.app.allowed
            }
            try {
                retry.performClick()
                compose.waitUntil(10_000) { f.repo.state.value.refreshing }
                compose.onNodeWithText("Scanning…").assertIsDisplayed()
                retry.assertDoesNotExist()
                compose.onNode(hasText("Scan again") and hasClickAction()).assertIsNotEnabled()
            } finally { release.countDown(); f.app.query = null }
            compose.waitUntil(10_000) { f.repo.state.value.let { it.ready && !it.refreshing && it.snapshot != null } }
            val recovered = f.repo.state.value.snapshot!!.files.single()
            assertEquals(attempt.change, recovered.displayOverride?.text)
            assertEquals(attempt.row, recovered.copy(displayOverride = attempt.row.displayOverride))
            assertArrayEquals(attempt.attempted, f.disk.readBytes())
            assertEquals("One original Apply replacement, no retry of Apply", 1, f.replaces.get())
            assertEquals(1, f.writerOpens.get())
            assertEquals("Settings recovery may not initiate any lookup", 0, f.requests.get())
            retry.assertDoesNotExist()
            compose.onNodeWithText("Songs").assertIsDisplayed()
            compose.onNode(hasText("Scan again") and hasClickAction()).assertIsEnabled()
        }
    }

    @Test fun startupBeforePhoneOwnerPublicationOnlyLoads() {
        Fixture(start = false).use { f ->
            mount(f)
            assertEquals(PhoneAudioState(), f.repo.state.value)
            compose.onNodeWithText("Loading…").assertIsDisplayed()
            retry.assertDoesNotExist()
            compose.onNodeWithText("Scan again").assertDoesNotExist()
            compose.onNodeWithText("Allow file access").assertDoesNotExist()
            assertEquals(0, f.writerOpens.get())
        }
    }

    @Test fun retryRefusesRevokedPermissionWhileButtonIsStillMounted() {
        Fixture().use { f ->
            val attempt = abandonApply(f)
            mount(f)
            retry.assertIsDisplayed()
            val permissionSamples = AtomicInteger()
            f.app.allowed = false
            f.app.query = { permissionSamples.incrementAndGet(); f.app.allowed }
            retry.performClick()
            assertEquals("Only the UI's guard sampled permission; refresh was not admitted", 1, permissionSamples.get())
            assertNull(f.repo.state.value.snapshot)
            assertArrayEquals(attempt.attempted, f.disk.readBytes())

            f.app.allowed = true
            retry.performClick()
            compose.waitUntil(10_000) { f.repo.state.value.snapshot?.files?.singleOrNull()?.displayOverride?.text == attempt.change }
            assertEquals(1, f.replaces.get())
        }
    }

    @Test fun retainedRetryRefusesRetiredSessionBeforeDisposal() {
        Fixture().use { f ->
            abandonApply(f)
            mount(f)
            val action = retry.assertIsDisplayed().fetchSemanticsNode().config[SemanticsActions.OnClick].action!!
            val version = f.graph.session.version()
            val callerSamples = AtomicInteger()
            compose.runOnIdle {
                val uiThread = Thread.currentThread()
                f.app.query = { if (Thread.currentThread() === uiThread) callerSamples.incrementAndGet(); true }
                assertTrue(f.graph.session.lockLocal())
                assertFalse(f.repo.current(version))
                // Same UI turn, before the mounted route can recompose or dispose.
                action()
            }
            assertEquals("Retired owner cannot request a refresh", 0, callerSamples.get())
            assertEquals(1, f.replaces.get())
        }
    }

    @Test fun disposingDuringHeldRetryLeavesTheFailureRetryableOnFreshEntry() {
        Fixture().use { f ->
            val attempt = abandonApply(f)
            val visible = mutableStateOf(true)
            mount(f) { visible.value }
            retry.assertIsDisplayed()
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            f.app.query = {
                if (f.repo.state.value.refreshing) { entered.countDown(); check(release.await(10, SECONDS)) }
                true
            }
            try {
                retry.performClick()
                compose.waitUntil(10_000) { entered.count == 0L }
                compose.runOnIdle { visible.value = false }
                retry.assertDoesNotExist()
            } finally { release.countDown(); f.app.query = null }
            compose.waitUntil(10_000) { !f.repo.state.value.refreshing }
            assertNull("Retirement during the access sample must not reconcile the abandoned Apply", f.repo.state.value.snapshot)
            assertArrayEquals(attempt.attempted, f.disk.readBytes())
            assertNull("The admitted refresh had already cleared the transient message", f.repo.state.value.message)

            compose.runOnIdle { visible.value = true }
            retry.assertIsDisplayed().performClick()
            compose.waitUntil(10_000) { f.repo.state.value.snapshot?.files?.singleOrNull()?.displayOverride?.text == attempt.change }
            assertEquals(1, f.replaces.get())
        }
    }

    private data class AbandonedApply(val row: com.soundq.android.data.deviceaudio.DeviceAudio,
        val change: LocalDisplayText, val attempted: ByteArray)
}
