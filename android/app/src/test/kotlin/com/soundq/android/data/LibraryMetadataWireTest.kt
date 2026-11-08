package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Original bytes emitted by the candidate Go GetLibrary handler/repository scanner. */
class LibraryMetadataWireTest {
    private fun produced()=checkNotNull(javaClass.getResource("/library-current-go/native-current.json")).readText()
    @Test fun actualGoCompactFactsSurviveLibraryDecodeWithoutChangingTrackAuthority() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture"))
            f.reply(produced())
            val page=SoundQApi(session,f.client).library(session.capture()!!,LibraryQuery(),0)
            assertEquals(setOf(7L,8L,9L,10L),page.analysis.keys.map {it.value}.toSet())
            page.analysis.values.forEach {assertEquals(LibraryAnalysisFacts("analyzed",128.0,"A minor","8A"),it)}
            assertEquals(listOf(7L,8L,9L,10L),page.tracks.map {it.id.value})
            assertTrue(page.tracks.all {it.durationMs==12000L&&it.liked==false})
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun ordinaryLibraryRequestsCompactFactsWithoutPerRowAnalysisFetches() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture"))
            f.reply(produced())
            val page=SoundQApi(session,f.client).library(session.capture()!!,LibraryQuery(),0)
            assertEquals(4,page.tracks.size)
            val request=checkNotNull(f.server.takeRequest(2,TimeUnit.SECONDS))
            val fields=request.url.queryParameter("fields").orEmpty().split(',')
            assertTrue("Compact Go analysis_summary must be requested with the library page","analysis_summary" in fields)
            assertTrue("Analysis status travels with compact facts","analysis_status" in fields)
            assertEquals(1,f.server.requestCount)
        }
    }
}
