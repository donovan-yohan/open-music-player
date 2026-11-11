package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class DiscoveryQueryRepairTest {
    @Test fun ellipsisUnicodeAndAmpersandReachActualTlsSearchAndLibraryUnchanged() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val discovery=DiscoveryRepository(session,api);val view=discovery.open()!!
            val query="...Baby One More Time 海 & music"
            discovery.edit(view,query);f.reply(DiscoveryBoundaryTest.search(query));discovery.search(view,discovery.state.value.draft)
            assertEquals("query punctuation is not URL traversal",DiscoveryPhase.Ready,discovery.state.value.phase)
            f.reply("""{"tracks":[],"total":0,"limit":20,"offset":0}""")
            assertEquals(0,api.library(session.capture()!!,LibraryQuery(text=query,genre="...Ambient & 海"),0).total)
            for(path in listOf("/api/v1/discovery/search","/api/v1/library")) {
                val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
                assertEquals(path,request.url.encodedPath);assertEquals(query,request.url.queryParameter("q"));assertEquals("Bearer a",request.headers["Authorization"])
                assertEquals("",request.url.username);assertEquals("",request.url.password)
            }
            assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun literalAndEncodedTraversalPathsRemainRefusedBeforeTls() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))};val api=SoundQApi(session,f.client)
            val wire=SoundQApi::class.java.declaredMethods.single {it.name=="wire"}.apply {isAccessible=true}
            for(path in listOf("/../auth/login","/library/../auth/login","/library/./tracks","/%2e%2e/auth/login","/library/%2E./tracks","//evil.test/api/v1/library","/library\\..\\auth/login","/library#fragment")) {
                f.reply("{}")
                assertTrue("path must be refused: $path",runCatching {wire.invoke(api,path,"GET",null,"a",null,{true})}.isFailure)
                assertEquals(0,f.server.requestCount)
            }
        }
    }
}
