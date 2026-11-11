package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.util.concurrent.TimeUnit

@RunWith(Parameterized::class)
class PlaylistAckRepairTest(private val label: String, private val body: String) {
    @Test fun malformedPrivateAckStaysUncertainAcrossExplicitInventoryRead() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply(body, 201)
            repository.create(repository.captureList()!!, PlaylistDraft("海辺 — Étude"))
            assertEquals("$label must not grant confirmation", MutationOutcome.Uncertain, repository.state.value.mutation?.outcome)
            assertNull(repository.state.value.created)
            assertEquals("Malformed ACK must not trigger automatic readback/replay", 1, fixture.server.requestCount)
            fixture.reply(playlistPage()); repository.reload()
            assertEquals(MutationOutcome.Uncertain, repository.state.value.mutation?.outcome)
            assertNull(repository.state.value.created)
            assertEquals(1, repository.state.value.rows.size)
            assertEquals(listOf("POST", "GET"), (1..2).map { fixture.server.takeRequest(3, TimeUnit.SECONDS)!!.method })
        }
    }
    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}") fun cases(): List<Array<String>> {
            val base = playlistSummary()
            return listOf(
                arrayOf("null-name", base.replace("\"海辺 — Étude\"", "null")),
                arrayOf("number-name", base.replace("\"海辺 — Étude\"", "42")),
                arrayOf("boolean-name", base.replace("\"海辺 — Étude\"", "true")),
                arrayOf("public-ack", base.replace("\"isPublic\":false", "\"isPublic\":true")),
                arrayOf("string-private", base.replace("\"isPublic\":false", "\"isPublic\":\"false\"")),
                arrayOf("string-id", base.replace("\"id\":41", "\"id\":\"41\"")),
                arrayOf("string-count", base.replace("\"trackCount\":0", "\"trackCount\":\"0\"")),
                arrayOf("string-duration", base.replace("\"durationMs\":0", "\"durationMs\":\"0\"")),
                arrayOf("number-description", base.replace("\"description\":\"Night listening\"", "\"description\":7")),
                arrayOf("null-description", base.replace("\"description\":\"Night listening\"", "\"description\":null")),
                arrayOf("boolean-cover", base.dropLast(1) + ",\"coverUrl\":false}"),
                arrayOf("null-cover", base.dropLast(1) + ",\"coverUrl\":null}"),
            )
        }
    }
}

class PlaylistAckCompatibilityTest {
    @Test fun unicodePrivate201WithOmittedOptionalStringsRemainsConfirmed() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val summary = """{"id":41,"name":"海辺 — Étude","isPublic":false,"trackCount":0,"durationMs":0}"""
            fixture.reply(summary, 201)
            fixture.reply("""{"data":[$summary],"total":1,"limit":20,"offset":0}""")
            repository.create(repository.captureList()!!, PlaylistDraft("海辺 — Étude"))
            assertEquals(MutationOutcome.Confirmed, repository.state.value.mutation?.outcome)
            assertEquals(PlaylistId(41), repository.state.value.created!!.id)
            assertEquals(PlaylistDraft("海辺 — Étude"), repository.state.value.created!!.draft)
            assertEquals(repository.state.value.created, repository.state.value.rows.single())
            assertEquals(2, fixture.server.requestCount)
        }
    }
}
