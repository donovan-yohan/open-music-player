package com.soundq.android.data

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** These pages are unmodified bytes emitted by Go GetLibrary through its real repository scanner. */
class LibraryArtworkWireTest {
    private fun produced(name:String)=checkNotNull(javaClass.getResource("/library-go/$name.json")).readText()
    private fun read(body:String,assertion:(LibraryPage,Set<String>)->Unit) {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture"))
            f.reply(body)
            val page=SoundQApi(session,f.client).library(session.capture()!!,LibraryQuery(),0)
            val request=checkNotNull(f.server.takeRequest(2,TimeUnit.SECONDS))
            assertion(page,request.url.queryParameter("fields").orEmpty().split(',').toSet())
        }
    }
    @Test fun actualGoCanonicalCoverAndReleaseFallbackReachTrackArtwork()=read(produced("canonical")){page,_->
        assertEquals(listOf(7L,8L),page.tracks.map {it.id.value})
        assertEquals(listOf("https://media.invalid/canonical-cover.png","https://coverartarchive.org/release/123e4567-e89b-12d3-a456-426614174000/front-250"),page.tracks.map {it.artwork})
    }
    @Test fun requestsTheCanonicalGoFieldInsteadOfAnUnrecognizedAlias()=read(produced("canonical")){_,fields->
        assertTrue("The Go producer only emits requested cover_art_url", "cover_art_url" in fields)
        assertTrue(setOf("id","title","artist","album","duration_ms","is_liked").all {it in fields})
    }
    @Test fun actualGoAliasOnlyRequestHasNoArtworkAndKeepsRows()=read(produced("legacy-request")){page,_->
        assertEquals(2,page.tracks.size);assertTrue(page.tracks.all {it.artwork==null})
    }
    @Test fun legacyAliasRemainsCompatibleOnlyWhenCanonicalIsAbsent() {
        val page=Json.parseToJsonElement(produced("canonical")).jsonObject
        val first=page.getValue("tracks").jsonArray.first().jsonObject
        val legacy=JsonObject(first.minus("cover_art_url")+mapOf("artwork_url" to JsonPrimitive("https://media.invalid/legacy.png")))
        read(JsonObject(page+mapOf("tracks" to JsonArray(listOf(legacy)),"total" to JsonPrimitive(1))).toString()){result,_->
            assertEquals("https://media.invalid/legacy.png",result.tracks.single().artwork)
        }
    }
    @Test fun canonicalWinsAndUnsafeCanonicalCannotBorrowLegacy() {
        val page=Json.parseToJsonElement(produced("canonical")).jsonObject
        val first=page.getValue("tracks").jsonArray.first().jsonObject
        for((canonical,expected)in listOf("https://media.invalid/canonical.png" to "https://media.invalid/canonical.png","http://unsafe.invalid/cover" to null)) {
            val row=JsonObject(first+mapOf("cover_art_url" to JsonPrimitive(canonical),"artwork_url" to JsonPrimitive("https://media.invalid/legacy.png")))
            read(JsonObject(page+mapOf("tracks" to JsonArray(listOf(row)),"total" to JsonPrimitive(1))).toString()){result,_->
                assertEquals(expected,result.tracks.single().artwork)
            }
        }
    }
}
