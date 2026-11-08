package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistRecoveryRepairTest {
    @Test fun retainedSubmitIsRefusedBeforeReconciliationAndRenewedIntent() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val old = repository.captureList()!!
            fixture.reply("{}", 503)
            repository.create(old, PlaylistDraft("Uncertain original"))
            fixture.reply("{}", 503)
            repository.create(old, PlaylistDraft("Uncertain original"))
            assertEquals("Uncertain intent must not dispatch a second POST", 1, fixture.server.requestCount)
            assertNull(repository.state.value.created)
        }
    }

    @Test fun explicitReadAndDifferentNewIntentRestoreInPlaceCreateWithoutReplayingOldDraft() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val actions = PlaylistActions(repository) { it() }
            val old = actions.capture!!
            val original = PlaylistDraft("Uncertain original")
            val fresh = PlaylistDraft("Deliberately new", "Night listening")
            fixture.reply("{}", 503)
            repository.create(old, original)
            assertFalse(repository.state.value.canCreate(fresh))
            assertFalse(repository.state.value.canStartNew(fresh))
            actions.startNew(fresh)
            assertFalse(repository.state.value.canCreate(fresh))
            fixture.reply("{}", 503); actions.reload()
            assertFalse(repository.state.value.canStartNew(fresh))
            actions.startNew(fresh)
            assertFalse(repository.state.value.canCreate(fresh))
            fixture.reply(playlistPage()); actions.reload()
            assertEquals(MutationOutcome.Uncertain, repository.state.value.mutation?.outcome)
            assertNull(repository.state.value.created)
            assertFalse(repository.state.value.canCreate(fresh))
            assertFalse(repository.state.value.canStartNew(original))
            assertTrue("Successful explicit reconciliation must offer a genuinely new intent", repository.state.value.canStartNew(fresh))
            actions.startNew(fresh)
            assertTrue("New intent must enable the mounted Create action", repository.state.value.canCreate(fresh))
            assertFalse(repository.state.value.canCreate(original))
            assertEquals(MutationOutcome.Uncertain, repository.state.value.mutation?.outcome)
            val count = fixture.server.requestCount
            repository.create(old, fresh)
            repository.create(actions.capture!!, original)
            assertEquals(count, fixture.server.requestCount)
            val summary = playlistSummary().replace("海辺 — Étude", fresh.name)
            fixture.reply(summary, 201)
            fixture.reply(playlistPage().replace("海辺 — Étude", fresh.name))
            actions.create(actions.capture!!, fresh)
            assertEquals(MutationOutcome.Confirmed, repository.state.value.mutation?.outcome)
            assertEquals(fresh.name, repository.state.value.created!!.name)
            val requests = (1..fixture.server.requestCount).map { fixture.server.takeRequest(3, TimeUnit.SECONDS)!! }
            assertEquals(listOf("POST", "GET", "GET", "POST", "GET"), requests.map { it.method })
            assertEquals(listOf(original.name, fresh.name), requests.filter { it.method == "POST" }.map { Json.parseToJsonElement(it.body!!.utf8()).jsonObject.getValue("name").jsonPrimitive.content })
        }
    }

    @Test fun explicitReadbackRecoveryRetiresFailurePresentationWithoutLosingKnownAck() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply(playlistSummary(), 201); fixture.reply("{}", 503)
            repository.create(repository.captureList()!!, PlaylistDraft("海辺 — Étude", "Night listening"))
            val ack = repository.state.value.created!!
            assertEquals(MutationOutcome.ReadbackFailed, repository.state.value.mutation?.outcome)
            fixture.reply(playlistPage()); repository.reload()
            assertEquals(ack, repository.state.value.created)
            assertEquals(MutationOutcome.Confirmed, repository.state.value.mutation?.outcome)
            assertNull(repository.state.value.error)
            assertEquals(3, fixture.server.requestCount)
        }
    }
}
