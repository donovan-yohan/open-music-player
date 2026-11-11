package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test

class PlaylistCallerRepairTest {
    @Test fun queuedOpenCannotAcquireAuthorityAfterClose() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val queue = ArrayDeque<() -> Unit>()
            val actions = PlaylistActions(repository) { queue.add(it) }
            fixture.reply(playlistPage())
            actions.reload()
            assertEquals(1, queue.size)
            actions.close()
            queue.removeFirst().invoke()
            assertEquals("Queued old open must not dispatch GET", 0, fixture.server.requestCount)
            assertEquals(PlaylistState(), repository.state.value)
        }
    }

    @Test fun retainedReloadCannotDispatchAfterSameRouteReopensButFreshReloadSucceeds() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val queue = ArrayDeque<() -> Unit>()
            val old = PlaylistActions(repository) { queue.add(it) }
            old.close()
            val current = PlaylistActions(repository) { queue.add(it) }
            fixture.reply(playlistPage())
            old.reload()
            assertTrue("Retained old Reload is refused before enqueue", queue.isEmpty())
            assertEquals("Retained old Reload must not borrow reopened authority", 0, fixture.server.requestCount)
            current.reload()
            queue.removeFirst().invoke()
            assertEquals(1, fixture.server.requestCount)
            assertEquals(1, repository.state.value.total)
            old.close()
            fixture.reply(playlistPage(empty = true))
            current.reload(); queue.removeFirst().invoke()
            assertEquals("Late old disposal must not retire current destination", 2, fixture.server.requestCount)
            assertEquals(0, repository.state.value.total)
        }
    }

    @Test fun queuedReadCannotBorrowReplacementAccount() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            val repository = PlaylistRepository(SoundQApi(session, fixture.client))
            val queue = ArrayDeque<() -> Unit>()
            val actions = PlaylistActions(repository) { queue.add(it) }
            fixture.reply(playlistPage())
            actions.reload()
            assertTrue(session.accept(session.beginIntent(), SecretTokens("replacement", "replacement-refresh", "replacement-account")))
            queue.removeFirst().invoke()
            assertEquals(0, fixture.server.requestCount)
            assertEquals(PlaylistState(), repository.state.value)
        }
    }
}
