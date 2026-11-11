package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** The injected reader delegates to the real HTTPS API, then changes destination after return. */
class PlaylistManagementRecoveryCompletionTest {
    @Test fun successfulRecoveryAfterDetailExitClearsOnlyLoadingWithoutPublishingStaleRead() {
        staleSuccessfulRecovery(reopen = false)
    }

    @Test fun successfulRecoveryAfterSamePlaylistReopensCannotPublishButDoesNotStrandLoading() {
        staleSuccessfulRecovery(reopen = true)
    }

    private fun staleSuccessfulRecovery(reopen: Boolean) {
        HttpsFixture().use { f ->
            val api = SoundQApi(playlistSession(f), f.client)
            val detail = PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            var completedReads = 0
            val owner = PlaylistManagementRepository(api, detail) { scope, id, valid ->
                val result = api.playlistManagementSnapshot(scope, id, valid)
                assertTrue("API returned a successful, still-eligible read", valid())
                completedReads++
                detail.retire()
                if (reopen) detail.select(PlaylistId(41))
                result
            }
            val actions = PlaylistManagementActions(owner) { it() }
            f.reply("{}", 503); actions.rename(actions.capture()!!, "Changed")
            assertEquals(MutationOutcome.Uncertain, owner.state.value.outcome)
            f.reply(managementDetail(name = "Changed")); actions.recover()
            assertEquals(1, completedReads)
            assertFalse("Successful but ineligible read must release its loading ticket", owner.state.value.loading)
            assertFalse(owner.state.value.reconciled)
            assertNull(owner.state.value.observed)
            assertNull(owner.state.value.undo)
            assertNull(detail.state.value.detail)
            assertEquals(if (reopen) PlaylistId(41) else null, detail.state.value.id)
            assertEquals(MutationOutcome.Uncertain, owner.state.value.outcome)
            assertEquals(listOf("GET", "PUT", "GET"), requests(f))
        }
    }

    @Test fun oldSuccessfulCompletionCannotClearNewRecoveryTicketLoading() {
        HttpsFixture().use { f ->
            val api = SoundQApi(playlistSession(f), f.client)
            val detail = PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            val jobs = mutableListOf<() -> Unit>()
            lateinit var actions: PlaylistManagementActions
            lateinit var owner: PlaylistManagementRepository
            var completedReads = 0
            owner = PlaylistManagementRepository(api, detail) { scope, id, valid ->
                val result = api.playlistManagementSnapshot(scope, id, valid)
                assertTrue(valid())
                if (++completedReads == 1) {
                    actions.close()
                    actions = PlaylistManagementActions(owner) { jobs.add(it) }
                    actions.recover()
                    assertTrue(owner.state.value.loading)
                }
                result
            }
            actions = PlaylistManagementActions(owner) { jobs.add(it) }
            f.reply("{}", 503); actions.rename(actions.capture()!!, "Changed"); jobs.removeAt(0)()
            f.reply(managementDetail(name = "Changed")); actions.recover(); jobs.removeAt(0)()
            assertEquals(1, jobs.size)
            assertTrue("Old completion must not clear replacement read loading", owner.state.value.loading)
            assertFalse(owner.state.value.reconciled)
            assertEquals("海辺 — Étude", detail.state.value.detail!!.playlist.name)
            f.reply(managementDetail(name = "Changed")); jobs.removeAt(0)()
            assertEquals(2, completedReads)
            assertFalse(owner.state.value.loading)
            assertTrue(owner.state.value.reconciled)
            assertEquals("Changed", detail.state.value.detail!!.playlist.name)
            assertEquals(listOf("GET", "PUT", "GET", "GET"), requests(f))
        }
    }

    @Test fun successfulOldRecoveryCannotChangeAccountReplacementState() {
        HttpsFixture().use { f ->
            val session = playlistSession(f)
            val api = SoundQApi(session, f.client)
            val detail = PlaylistDetailRepository(api)
            f.reply(managementDetail()); detail.open(PlaylistId(41))
            lateinit var owner: PlaylistManagementRepository
            var replacement: PlaylistManagementState? = null
            owner = PlaylistManagementRepository(api, detail) { scope, id, valid ->
                val result = api.playlistManagementSnapshot(scope, id, valid)
                assertTrue(valid())
                session.revoke()
                check(session.accept(session.beginIntent(), SecretTokens("replacement-test", "replacement-refresh", "replacement-account")))
                owner.retire(); detail.retire()
                replacement = owner.state.value
                result
            }
            val actions = PlaylistManagementActions(owner) { it() }
            f.reply("{}", 503); actions.rename(actions.capture()!!, "Changed")
            f.reply(managementDetail(name = "Changed")); actions.recover()
            assertNotNull(replacement)
            assertSame(replacement, owner.state.value)
            assertFalse(owner.state.value.loading)
            assertNull(detail.state.value.detail)
            assertEquals(listOf("GET", "PUT", "GET"), requests(f))
        }
    }

    private fun requests(f: HttpsFixture): List<String> =
        (1..f.server.requestCount).map { f.server.takeRequest(2, TimeUnit.SECONDS)!!.method }
}
