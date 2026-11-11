package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

internal fun detailsRow(title:String="Original",edited:Boolean=false,verified:Boolean=false)="""{"id":7,"title":"$title","artist":"Ensemble","album":"Source album","mb_verified":$verified,"has_metadata_override":$edited,"codec":"flac","sample_rate_hz":48000}"""
internal fun detailsPage(row:String?=detailsRow())="""{"tracks":[${row.orEmpty()}],"total":${if(row==null)0 else 1},"limit":100,"offset":0}"""
internal fun detailsSetup(f:HttpsFixture):Triple<SoundQApi,LibraryRepository,TrackDetailsRepository> {
    val session=playlistSession(f); val api=SoundQApi(session,f.client)
    val library=LibraryRepository(session,{_,q,_->LibraryPage(listOf(Track(TrackId(7),"Original")),1,20,0)},{_,_,_->})
    library.refine(LibraryQuery(text="Ensemble",liked=true,genre="Jazz"))
    return Triple(api,library,TrackDetailsRepository(api,library))
}
internal fun analysisBody(revision:Long=3,overrides:String="{}")="""{"track_id":7,"schema_version":1,"status":"analyzed","summary":{"bpm":{"value":123.5,"confidence":0.8},"key":{"value":"A minor"}},"effective_timing":{"bpm":{"value":123.5},"beat_grid":{"offset_ms":17}},"overrides":$overrides,"override_revision":$revision,"requested_at":"2026-10-29T00:00:00Z","updated_at":"2026-10-29T00:00:00Z"}"""
class TrackDetailsTest {
    @Test fun analysisUsesRevisionAndOnlyExplicitFactsWithServerOwnedTiming() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply(analysisBody());repository.load(route)
            val analysis=repository.state.value.analysis!!
            assertEquals(3,analysis.revision)
            assertEquals(123.5,analysis.number("bpm")!!,0.0)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Analysis(analysis,AnalysisCorrection(bpm=128.25,anchorMs=17,meter=4,phase=1,key="D minor")))!!
            val document="""{"manual_timing_v2":{"schema_version":2,"bpm":128.25,"beat_anchor_ms":17,"beats_per_bar":4,"downbeat_phase_index":1,"confidence":1.0,"provenance":"manual_override","revision":4},"key":{"value":"D minor","provenance":"manual_override"}}"""
            f.reply(analysisBody(4,document));f.reply(analysisBody(4,document));repository.execute(command)
            assertEquals(4,repository.state.value.analysis!!.revision)
            assertEquals("D minor",repository.state.value.analysis!!.text("key"))
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("PATCH",requests[2].method)
            val payload=kotlinx.serialization.json.Json.parseToJsonElement(requests[2].body!!.utf8()).toString()
            assertTrue(payload.contains("\"expected_revision\":3"))
            assertTrue(payload.contains("\"timing_mutation\":\"replace\""))
            assertFalse(payload.contains("beats_ms"))
            assertFalse(payload.contains("phrase_length_bars"))
            assertEquals("/api/v1/tracks/7/analysis",requests[3].url.encodedPath)
        }
    }

    @Test fun removeRequiresTyped204AndMissingOwnerReadback() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val observed=repository.state.value.detail!!
            // A cancelled confirmation does not claim or send anything.
            assertEquals(2,f.server.requestCount)
            val command=repository.claim(route,observed,DetailsAction.Remove)!!
            f.reply("{}",204);f.reply(detailsPage(null));repository.execute(command)
            assertTrue(repository.state.value.missing)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("DELETE",requests[2].method)
            assertEquals("/api/v1/library/tracks/7",requests[2].url.encodedPath)
        }
    }

    @Test fun resetUsesExplicitNullsAndDoesNotOverwritePlaybackOrRefinement() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage(detailsRow("Personal",true)));f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft()))!!
            f.reply("""{"track_id":7,"has_metadata_override":false,"title":null,"artist":null,"album":null}""")
            f.reply(detailsPage());repository.execute(command)
            assertFalse(repository.state.value.detail!!.edited)
            assertEquals("Original",repository.state.value.detail!!.track.title)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals("""{"title":null,"artist":null,"album":null}""",requests[2].body!!.utf8())
        }
    }
    @Test fun malformedAcknowledgementNeverReplaysAndExplicitGetRecoversWithoutClaimingConfirmation() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val action=DetailsAction.Metadata(MetadataDraft("Personal"))
            val command=repository.claim(route,repository.state.value.detail!!,action)!!
            f.reply("""{"track_id":"7","has_metadata_override":true,"title":"Personal","artist":null,"album":null}""")
            repository.execute(command)
            assertEquals(3,f.server.requestCount)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertNull(repository.claim(route,repository.state.value.detail!!,action))
            f.reply(detailsPage(detailsRow("Personal",true)));f.reply("{}",404);repository.load(route)
            assertEquals("Personal",repository.state.value.detail!!.track.title)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertTrue(repository.state.value.reconciled)
            assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun closedRouteRefusesRetainedActionAndLateGetPublication() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val old=repository.state.value.detail!!
            repository.close(route)
            assertNull(repository.claim(route,old,DetailsAction.Metadata(MetadataDraft("Wrong"))))
            assertNull(repository.state.value.detail)
            assertEquals(2,f.server.requestCount)
        }
    }

    @Test fun metadataSaveReadsEffectiveDetailsAndPreservesLibraryRefinement() {
        HttpsFixture().use {f ->
            val (_,library,repository)=detailsSetup(f)
            val query=library.state.value.query
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val observed=repository.state.value.detail!!
            val ticket=repository.claim(route,observed,DetailsAction.Metadata(MetadataDraft("Personal title","Ensemble","Source album")))!!
            f.reply("""{"track_id":7,"has_metadata_override":true,"title":"Personal title","artist":"Ensemble","album":"Source album"}""")
            f.reply(detailsPage(detailsRow("Personal title",true)))
            repository.execute(ticket)
            assertEquals("Personal title",repository.state.value.detail?.track?.title)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(query,library.state.value.query)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","GET","PUT","GET"),requests.map {it.method})
            assertEquals("/api/v1/tracks/7/metadata-override",requests[2].url.encodedPath)
            assertEquals("""{"title":"Personal title","artist":"Ensemble","album":"Source album"}""",requests[2].body!!.utf8())
            assertEquals("100",requests[3].url.queryParameter("limit"))
        }
    }
}
