package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

private const val selectedRecording="12345678-1234-1234-1234-123456789abc"
private const val differentRecording="12345678-1234-1234-1234-123456789def"

/** Real repository and certificate-validated HTTP; the numeric Library identity stays 7. */
class TrackDetailsExactRecordingTest {
    @Test fun sameNamedSuggestionMustReadBackItsOwnRecordingAndCannotUseACopiedSuggestion() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            val suggestions="""[{"mb_recording_id":"$selectedRecording","title":"Same","artist":"Same"},{"mb_recording_id":"$differentRecording","title":"Same","artist":"Same"}]"""
            f.reply(detailsPage(detailsRow().dropLast(1)+",\"mb_suggestions\":$suggestions}"));f.reply("{}",404);repository.load(route)
            val before=repository.state.value.detail!!
            val chosen=before.suggestions[1]
            assertNull(repository.claim(route,before,DetailsAction.Verification(VerificationAction.Confirm(chosen.copy()))))
            val command=repository.claim(route,before,DetailsAction.Verification(VerificationAction.Confirm(chosen)))!!
            f.reply("""{"success":true,"trackId":7,"verified":true}""")
            f.reply(detailsPage(detailsRow(verified=true).dropLast(1)+",\"mb_recording_id\":\"$selectedRecording\"}"));repository.execute(command)
            assertEquals(MutationOutcome.ReadbackFailed,repository.state.value.outcome)
            assertSame(before,repository.state.value.detail)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("""{"recordingMbid":"$differentRecording"}""",requests[2].body!!.utf8())
            assertEquals("/api/v1/tracks/7/confirm-match",requests[2].url.encodedPath)
        }
    }
    @Test fun validUuidCaseReadbackPreservesTheLiteralSubmittedTokenAndNumericTrack() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val query=library.state.value.query
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val token=selectedRecording.uppercase()
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Verification(VerificationAction.Link(RecordingMbid(token))))!!
            f.reply("""{"track_id":7,"mb_recording_id":"$token","verified":true,"metadata_updated":false}""")
            f.reply(detailsPage(detailsRow(verified=true).dropLast(1)+",\"mb_recording_id\":\"$selectedRecording\"}"));repository.execute(command)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(TrackId(7),repository.state.value.detail!!.track.id)
            assertEquals(query,library.state.value.query)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("""{"mb_recording_id":"$token","update_metadata":false}""",requests[2].body!!.utf8())
            assertEquals("/api/v1/tracks/7/link-mb",requests[2].url.encodedPath)
        }
    }
    @Test fun acceptedWriteStaysPendingUntilAuthoritativeReadbackFinishes() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft("Personal")))!!
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                if(request.method=="PUT")return mockwebserver3.MockResponse.Builder().body("""{"track_id":7,"has_metadata_override":true,"title":"Personal","artist":null,"album":null}""").build()
                entered.countDown();check(release.await(10,TimeUnit.SECONDS))
                return mockwebserver3.MockResponse.Builder().body(detailsPage(detailsRow("Personal",true))).build()
            }}
            val task=pool.submit {repository.execute(command)}
            try {
                assertTrue(entered.await(5,TimeUnit.SECONDS))
                assertEquals("Saving includes the owned readback",MutationOutcome.Pending,repository.state.value.outcome)
            } finally {release.countDown();task.get(10,TimeUnit.SECONDS);pool.shutdownNow()}
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals("Personal",repository.state.value.detail!!.track.title)
        }
    }
    @Test fun differentOrAbsentRecordingReadbackCannotConfirmAnExactLink() {
        for(recording in listOf(differentRecording,null))HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val before=repository.state.value.detail!!
            val command=repository.claim(route,before,DetailsAction.Verification(VerificationAction.Link(RecordingMbid(selectedRecording))))!!
            f.reply("""{"track_id":7,"mb_recording_id":"$selectedRecording","verified":true,"metadata_updated":false}""")
            val readback=detailsRow(verified=true).dropLast(1)+(recording?.let {",\"mb_recording_id\":\"$it\""}?:"")+"}"
            f.reply(detailsPage(readback));repository.execute(command);repository.execute(command)
            assertEquals("An ACK is not proof of the chosen recording",MutationOutcome.ReadbackFailed,repository.state.value.outcome)
            assertSame(before,repository.state.value.detail)
            assertNull(repository.claim(route,before,DetailsAction.Remove))
            assertEquals(4,f.server.requestCount)
            assertEquals(listOf("GET","GET","POST","GET"),(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!.method})
        }
    }
}
