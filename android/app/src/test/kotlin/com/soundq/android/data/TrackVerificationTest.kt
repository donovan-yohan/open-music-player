package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

private const val recording="12345678-1234-1234-1234-123456789abc"
class TrackVerificationTest {
    @Test fun rematchAndSuggestionConfirmationUseDifferentAcknowledgements() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            val suggestion="""{"mb_recording_id":"$recording","title":"Candidate","artist":"Ensemble","confidence":0.75,"release_id":"12345678-1234-1234-1234-123456789aaa"}"""
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val rematch=repository.claim(route,repository.state.value.detail!!,DetailsAction.Verification(VerificationAction.Rematch))!!
            f.reply("""{"track_id":7,"verified":false,"suggestions":[$suggestion],"parsed_title":null}""")
            f.reply(detailsPage(detailsRow().dropLast(1)+",\"mb_suggestions\":[$suggestion]}"));repository.execute(rematch)
            val observed=repository.state.value.detail!!
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertFalse(observed.verified)
            val confirm=repository.claim(route,observed,DetailsAction.Verification(VerificationAction.Confirm(observed.suggestions.single())))!!
            f.reply("""{"success":true,"trackId":7,"verified":true}""")
            f.reply(detailsPage(detailsRow(verified=true).dropLast(1)+",\"mb_recording_id\":\"$recording\"}"));repository.execute(confirm)
            assertTrue(repository.state.value.detail!!.verified)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            val requests=(1..6).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("/api/v1/tracks/7/match",requests[2].url.encodedPath)
            assertEquals("{}",requests[2].body!!.utf8())
            assertEquals("/api/v1/tracks/7/confirm-match",requests[4].url.encodedPath)
            assertEquals("""{"recordingMbid":"$recording","releaseMbid":"12345678-1234-1234-1234-123456789aaa"}""",requests[4].body!!.utf8())
        }
    }
    @Test fun stringVerifiedAndWrongTrackCannotAcknowledgeMatching() {
        for(body in listOf("""{"track_id":8,"mb_recording_id":"$recording","verified":true,"metadata_updated":false}""","""{"track_id":7,"mb_recording_id":"$recording","verified":"true","metadata_updated":false}"""))HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val ticket=repository.claim(route,repository.state.value.detail!!,DetailsAction.Verification(VerificationAction.Link(RecordingMbid(recording))))!!
            f.reply(body);repository.execute(ticket)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertEquals(3,f.server.requestCount)
        }
    }

    @Test fun manualLinkKeepsRecordingIdentitySeparateAndSendsMetadataChoiceExplicitly() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Verification(VerificationAction.Link(RecordingMbid(recording))))!!
            f.reply("""{"track_id":7,"mb_recording_id":"$recording","verified":true,"metadata_updated":false}""")
            f.reply(detailsPage(detailsRow(verified=true).dropLast(1)+",\"mb_recording_id\":\"$recording\"}"))
            repository.execute(command)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertTrue(repository.state.value.detail!!.verified)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("/api/v1/tracks/7/link-mb",requests[2].url.encodedPath)
            assertEquals("""{"mb_recording_id":"$recording","update_metadata":false}""",requests[2].body!!.utf8())
        }
    }
    @Test fun invalidRecordingTokenIsRejectedWithoutNormalization() {
        listOf("7","12345678123412341234123456789abc"," $recording",recording+" ").forEach {assertTrue(runCatching {RecordingMbid(it)}.isFailure)}
    }
}
