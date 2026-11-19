package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class DiscoveryGroupedJourneyTest {
    @Test fun groupedReadRefinesExactTitleAndBackRestoresAcceptedPageWithoutImportAuthority() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val r=DiscoveryRepository(session,SoundQApi(session,f.client));val view=r.open()!!
            f.replySong(DiscoveryBoundaryTest.search("seed"));r.edit(view,"seed");r.searchBlocking(view,r.state.value.draft)
            val songPage=r.state.value.results!!;val song=r.inspect(view,songPage.rows.single())!!
            f.takeSongRequests()
            val groupedSearch=r.selectType(view,DiscoveryResultType.Artist)!!
            assertFalse(song.valid());assertNull(r.state.value.results)
            f.reply(grouped());r.searchBlocking(groupedSearch)
            val page=r.state.value.results!!
            assertEquals("youtube,soundcloud,musicbrainz",f.server.takeRequest().url.queryParameter("providers"))
            assertEquals(1,page.rows.size);assertEquals(2,page.entities.size)
            assertNull(r.inspect(view,song.candidate)) // same wire ID is not the new row capability
            assertEquals(listOf("seed"),r.state.value.recent)
            assertNull(r.selectType(view,DiscoveryResultType.Album));assertSame(page,r.state.value.results)
            assertNull(r.selectType(view,DiscoveryResultType.Artist));assertSame(page,r.state.value.results)
            val draft=r.refine(view,page.entities.first())!!
            assertEquals("Exact Artist",draft.text);assertEquals(DiscoveryResultType.Artist,r.state.value.resultType)
            f.reply(DiscoveryBoundaryTest.search("Exact Artist"));r.searchBlocking(view,draft)
            assertTrue(r.back(view));assertSame(page,r.state.value.results);assertEquals("seed",r.state.value.draft.text)
            assertEquals(DiscoveryResultType.Artist,r.state.value.resultType)
            r.close(view);val fresh=r.open()!!;assertSame(page,r.state.value.results)
            val choice=r.inspect(fresh,page.rows.single())!!
            var launched:String?=null
            assertTrue(r.preview(fresh,choice){launched=it});assertEquals(choice.candidate.source.url,launched)
            assertFalse(r.preview(fresh,choice){error("No activity")});assertSame(choice,r.state.value.inspected)
            r.edit(fresh,"");assertFalse(choice.valid());assertFalse(r.preview(fresh,choice){fail("stale preview")})
            assertEquals(4,f.server.requestCount)
        }
    }
    @Test fun sourceProvidersStayClosedAndUnknownGroupedProviderCannotBecomeCandidate() {
        assertEquals(listOf("youtube","soundcloud"),SourceProvider.entries.map {it.wire})
        val invalid=grouped().replace("\"provider\":\"youtube\",\"sourceId\"","\"provider\":\"musicbrainz\",\"sourceId\"")
        assertTrue(runCatching {DiscoveryJson.search(Json.parseToJsonElement(invalid).jsonObject,"seed")}.isFailure)
    }
    companion object {
        fun grouped():String {
            val c=DiscoveryBoundaryTest.candidate()
            return """{"query":"seed","results":[$c],"sections":[{"kind":"sources","title":"Sources","items":[{"kind":"source","candidate":$c}]},{"kind":"artists","title":"Artists","items":[{"kind":"artist","id":"artist-mbid","title":"Exact Artist","subtitle":"Group"}]},{"kind":"albums","title":"Albums","items":[{"kind":"album","id":"album-mbid","title":"Exact Album","subtitle":"Artist"}]}],"providers":[{"provider":"youtube","status":"ok","resultCount":1},{"provider":"soundcloud","status":"timeout","resultCount":0},{"provider":"musicbrainz","status":"ok","resultCount":2}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}"""
        }
    }
}
