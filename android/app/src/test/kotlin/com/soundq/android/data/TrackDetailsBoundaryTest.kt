package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import mockwebserver3.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class TrackDetailsBoundaryTest {
    @Test fun analysisWrongRevisionOrCorrectionEchoNeverAcknowledges() {
        for(ack in listOf(analysisBody(3),analysisBody(4,"""{"manual_timing_v2":{"schema_version":2,"bpm":125}}""")))HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply(analysisBody());repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Analysis(repository.state.value.analysis!!,AnalysisCorrection(bpm=128.0)))!!
            f.reply(ack);repository.execute(command)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertEquals(3,f.server.requestCount)
        }
    }

    @Test fun analysisResetSendsClearWithExactRevisionAndConsumesGetReadback() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply(analysisBody(9,"""{"manual_timing_v2":{"schema_version":2,"bpm":121,"revision":9},"key":{"value":"C major"}}"""));repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Analysis(repository.state.value.analysis!!,AnalysisCorrection(reset=true)))!!
            f.reply(analysisBody(10));f.reply(analysisBody(10));repository.execute(command)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(10,repository.state.value.analysis!!.revision)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            val body=Json.parseToJsonElement(requests[2].body!!.utf8()).jsonObject
            assertEquals("clear",body.getValue("timing_mutation").jsonPrimitive.content)
            assertEquals(9,body.getValue("expected_revision").jsonPrimitive.long)
            assertEquals("GET",requests[3].method)
            assertTrue(repository.state.value.analysis!!.overrides.isEmpty())
        }
    }
    @Test fun libraryBackgroundReadCannotResetNewRefinement() {
        HttpsFixture().use {f->
            val session=playlistSession(f);val api=SoundQApi(session,f.client)
            val old=Track(TrackId(7),"Original")
            val library=LibraryRepository(session,{_,query,_->LibraryPage(listOf(if(query.text=="new")Track(TrackId(8),"New") else old),1,20,0)},{_,_,_->})
            library.refine(LibraryQuery(text="old",genre="Jazz"))
            val repository=TrackDetailsRepository(api,library)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft()))!!
            val next=LibraryQuery(text="new",liked=true,verified=true,genre="Funk")
            library.refine(next)
            f.reply("""{"track_id":7,"has_metadata_override":false,"title":null,"artist":null,"album":null}""")
            f.reply(detailsPage());repository.execute(command)
            assertEquals(next,library.state.value.query)
            assertEquals(TrackId(8),library.state.value.rows.single().id)
        }
    }

    @Test fun acceptedMetadataWithFailedGetReportsReadbackFailureAndNeverRepeatsPut() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft()))!!
            f.reply("""{"track_id":7,"has_metadata_override":false,"title":null,"artist":null,"album":null}""")
            f.reply("{}",503);repository.execute(command)
            assertEquals(MutationOutcome.ReadbackFailed,repository.state.value.outcome)
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            assertTrue(repository.state.value.reconciled)
            assertEquals(MutationOutcome.ReadbackFailed,repository.state.value.outcome)
            assertEquals(listOf("GET","GET","PUT","GET","GET","GET"),(1..6).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun removal200DoesNotAcknowledgeOrAutomaticallyRefresh() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Remove)!!
            f.reply("{}",200);repository.execute(command)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome)
            assertFalse(repository.state.value.missing);assertEquals(3,f.server.requestCount)
        }
    }

    @Test fun heldReadCannotPublishAfterRouteCloseOrAccountReplacement() {
        for(replace in listOf(false,true))HttpsFixture().use {f->
            val (api,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(detailsPage()).build()
            }}
            try {
                val task=pool.submit {repository.load(route)}
                assertTrue(entered.await(3,TimeUnit.SECONDS))
                if(replace)api.session.accept(api.session.beginIntent(),SecretTokens("b","br","replacement")) else repository.close(route)
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertNull(repository.state.value.detail);assertEquals(1,f.server.requestCount)
                assertFalse(repository.current(route))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun claimedCommandCannotDispatchAfterCloseAndSameTicketCannotReplay() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Remove)!!
            repository.close(route);repository.execute(command)
            assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun wrongSuccessStatusAndTypedAckRemainUncertainWithoutRefreshOrReplay() {
        for((status,body) in listOf(201 to """{"track_id":7,"has_metadata_override":false,"title":null,"artist":null,"album":null}""",200 to """{"track_id":7,"has_metadata_override":"false","title":null,"artist":null,"album":null}"""))HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply("{}",404);repository.load(route)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Metadata(MetadataDraft()))!!
            f.reply(body,status);repository.execute(command);repository.execute(command)
            assertEquals(MutationOutcome.Uncertain,repository.state.value.outcome);assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun analysisConflictKeepsDraftBaseAndReloadIsGetOnly() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            f.reply(detailsPage());f.reply(analysisBody());repository.load(route)
            val base=repository.state.value.analysis!!
            val action=DetailsAction.Analysis(base,AnalysisCorrection(bpm=128.0))
            val command=repository.claim(route,repository.state.value.detail!!,action)!!
            f.reply("{}",409);repository.execute(command)
            assertEquals(MutationOutcome.Refused,repository.state.value.outcome)
            assertSame(base,repository.state.value.analysis)
            f.reply(detailsPage());f.reply(analysisBody(4));repository.load(route)
            assertEquals(4,repository.state.value.analysis!!.revision)
            assertNull(repository.claim(route,repository.state.value.detail!!,action))
            assertEquals(listOf("GET","GET","PATCH","GET","GET"),(1..5).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun analysisResetAndKeyOnlyPreserveTimingAndLegacyDataAtWireBoundary() {
        val base=AnalysisJson.parse(kotlinx.serialization.json.Json.parseToJsonElement(analysisBody(9,"""{"manual_timing_v2":{"schema_version":2,"bpm":121,"revision":9},"beat_grid":{"beats_ms":[17,513,1025]},"key":{"value":"C major"}}""")).jsonObject,TrackId(7))
        val keyOnly=AnalysisJson.request(base,AnalysisCorrection(key="D minor"))
        assertFalse(keyOnly.containsKey("timing_mutation"))
        assertTrue(keyOnly.toString().contains("beats_ms"))
        val reset=AnalysisJson.request(base,AnalysisCorrection(reset=true))
        assertEquals("clear",reset.getValue("timing_mutation").jsonPrimitive.content)
        assertFalse(reset.toString().contains("beats_ms"))
        assertFalse(reset.toString().contains("manual_timing_v2"))
        assertEquals(9,reset.getValue("expected_revision").jsonPrimitive.long)
    }
    @Test fun invalidCorrectionNeverBecomesAnInventedZeroValue() {
        assertTrue(runCatching {AnalysisCorrection(bpm=Double.NaN)}.isFailure)
        assertTrue(runCatching {AnalysisCorrection(anchorMs=-1)}.isFailure)
        assertTrue(runCatching {AnalysisCorrection(phase=0)}.isFailure)
        assertTrue(runCatching {AnalysisCorrection(meter=4,phase=4)}.isFailure)
        assertNull(AnalysisCorrection(key="D minor").bpm)
    }
}
