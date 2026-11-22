package com.soundq.android.product.discovery

import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.discovery.DiscoverBrowsePage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class DiscoverEntityVisitTest {
    @Test fun stillCurrentRejectedPageSettlesAndRetriesTheSameOffsetOnlyOnDemand() = runBlocking {
        val visit = EntityBrowseVisit { true }
        val slot = EntityBrowseSlot<String> { it }
        var accepted = 0
        val offsets = mutableListOf<Int>()
        suspend fun load(result: () -> DiscoverBrowsePage<String>) {
            slot.load(visit, false, { offset, _, _ -> offsets.add(offset); result() }, { _, _ -> accepted++ })
        }
        load { DiscoverBrowsePage(listOf("retained"), 20, false) }
        val retained = slot.rows
        slot.request()
        load { throw SafeFailure(SafeFailure.Reason.Retired) }
        assertTrue(visit.current())
        assertTrue(slot.failed)
        assertFalse(slot.waiting)
        assertTrue(slot.canContinue)
        assertSame(retained, slot.rows)
        assertEquals(1, accepted)
        load { error("a failed slot must not retry on re-entry without demand") }
        assertEquals(listOf(0, 20), offsets)
        slot.request()
        load { DiscoverBrowsePage(listOf("recovery"), null, false) }
        assertEquals(listOf(0, 20, 20), offsets)
        assertEquals(listOf("retained", "recovery"), slot.rows)
        assertEquals(2, accepted)
        assertFalse(slot.failed)
    }

    @Test fun backRestoresTheScopedSearchThenTheSameArtistOverviewThenExits() {
        val artist = EntityArtist(ArtistMbid("821797e1-94c0-4e9c-88be-b49f971ada3b"), "Fixture artist")
        val album = EntityAlbum(ReleaseGroupMbid("b139f140-6a40-4dd5-af24-d7df33beb6a9"), "Fixture album", null, null)
        val navigation = EntityBrowseNavigation(artist) { true }
        val overview = artist.scroll
        navigation.setResumed(true)
        assertTrue(artist.edit(TextFieldValue("Fixture album")))
        navigation.renew()
        val search = artist.search
        val scopedVisit = checkNotNull(navigation.visit)
        navigation.push(album)
        assertFalse(scopedVisit.current())
        assertSame(album, navigation.destination)

        var exits = 0
        navigation.back { exits++ }
        assertSame(artist, navigation.destination)
        assertSame(search, artist.search)
        assertEquals("Fixture album", artist.editor.text)
        val restored = checkNotNull(navigation.visit)
        navigation.back { exits++ }
        assertFalse(restored.current())
        assertSame(artist, navigation.destination)
        assertSame(overview, artist.scroll)
        assertNull(artist.search)
        assertEquals("", artist.editor.text)
        assertEquals(0, exits)

        navigation.back { exits++ }
        assertEquals(1, exits)
        assertNull(navigation.visit)
    }

    @Test fun retirementCancelsHeldTransportBeforeReleaseAndDoesNotReviveOldVisit() = runBlocking {
        val entered = CountDownLatch(1)
        val canceled = CountDownLatch(1)
        val release = CountDownLatch(1)
        val exited = CountDownLatch(1)
        val oldCurrentAfterRelease = AtomicBoolean(true)
        val rendered = AtomicBoolean(false)
        val visit = EntityBrowseVisit { true }
        val old = async {
            visit.read { calls, current ->
                assertTrue(calls.track { canceled.countDown() })
                entered.countDown()
                try {
                    assertTrue(release.await(5, TimeUnit.SECONDS))
                    oldCurrentAfterRelease.set(current())
                    "old rows"
                } finally { exited.countDown() }
            }
            rendered.set(true)
        }
        try {
            // Await off the runBlocking thread so the read may start.
            assertTrue(kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })
            visit.retire()
            assertTrue(canceled.await(1, TimeUnit.SECONDS))
            withTimeout(1_000) { old.join() }
            assertEquals(1L, release.count)
            assertFalse(rendered.get())
            val successor = EntityBrowseVisit { true }
            assertEquals("new rows", successor.read { _, current -> assertTrue(current()); "new rows" })
            release.countDown()
            assertTrue(exited.await(2, TimeUnit.SECONDS))
            assertFalse(oldCurrentAfterRelease.get())
            assertTrue(successor.current())
        } finally { release.countDown(); old.cancel() }
    }

    @Test fun anAlreadyRetiredVisitDoesNotDispatch() = runBlocking {
        val visit = EntityBrowseVisit { true }
        visit.retire()
        val dispatched = AtomicBoolean(false)
        val attempt = async { visit.read { _, _ -> dispatched.set(true) } }
        withTimeout(1_000) { attempt.join() }
        assertTrue(attempt.isCancelled)
        assertFalse(dispatched.get())
    }
}
