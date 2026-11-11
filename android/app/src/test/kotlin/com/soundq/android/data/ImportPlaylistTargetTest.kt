package com.soundq.android.data

import com.soundq.android.data.acquisition.IntakeReceipts
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class ImportPlaylistTargetTest {
    private val selection="123e4567-e89b-12d3-a456-426614174010"
    private val decision="123e4567-e89b-12d3-a456-426614174020"
    private val job="123e4567-e89b-12d3-a456-426614174071"
    @Test fun capturedSourcePlanLoadsLaterPlaylistsWithoutWritingAndRejectsStaleChoice() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client)
            val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like))
            val discovery=com.soundq.android.data.discovery.DiscoveryRepository(session,api)
            val route=discovery.open()!!
            discovery.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discovery.search(route,discovery.state.value.draft)
            val choice=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
            val view=imports.open()!!
            assertTrue(imports.prepareSource(view,choice))
            val plan=imports.state.value.sourcePlan!!
            val firstPage=buildJsonObject {put("data",buildJsonArray {for(id in 1..20)add(buildJsonObject {put("id",id);put("name","Playlist $id");put("isPublic",false);put("trackCount",0);put("durationMs",0)})});put("total",21);put("limit",20);put("offset",0)}
            f.reply(firstPage.toString());imports.loadSourcePlaylists(view,plan)
            f.reply("""{"data":[{"id":41,"name":"Captured target","isPublic":false,"trackCount":0,"durationMs":0}],"total":21,"limit":20,"offset":20}""")
            imports.loadSourcePlaylists(view,plan,more=true)
            val row=imports.state.value.playlistChoices.last()
            assertEquals(21,imports.state.value.playlistChoices.size)
            assertTrue(imports.chooseSourcePlaylist(view,plan,row))
            assertFalse(imports.chooseSourcePlaylist(view,plan,row.copy()))
            assertEquals(3,f.server.requestCount)
            discovery.edit(route,"different source")
            assertNull(imports.claimPlannedSource(view,plan))
            assertEquals(3,f.server.requestCount)
        }
    }

    @Test fun actualCapturedTargetIsDurableBeforeDecisionAndRecoversLostPublicationWithoutPlaylistWrites() {
        HttpsFixture().use {f->
            val dir=Files.createTempDirectory("captured-import-target").toFile()
            val entered=java.util.concurrent.CountDownLatch(1)
            val release=java.util.concurrent.CountDownLatch(1)
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val file=dir.resolve("intake.json")
                val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
                val api=SoundQApi(session,f.client,IntakeReceipts(file))
                val library=LibraryRepository(session,api::library,api::like)
                val imports=ImportRepository(session,api,library)
                val discover=com.soundq.android.data.discovery.DiscoveryRepository(session,api)
                val route=discover.open()!!
                discover.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discover.search(route,discover.state.value.draft)
                val choice=discover.inspect(route,discover.state.value.results!!.rows.single())!!
                val view=imports.open()!!
                assertTrue(imports.prepareSource(view,choice));val plan=imports.state.value.sourcePlan!!
                f.reply(playlistPage());imports.loadSourcePlaylists(view,plan)
                assertTrue(imports.chooseSourcePlaylist(view,plan,imports.state.value.playlistChoices.single()))
                val post=imports.claimPlannedSource(view,plan)!!
                assertNull(imports.claimPlannedSource(view,plan))
                val paths=java.util.concurrent.CopyOnWriteArrayList<String>()
                f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    val path=request.url.encodedPath;paths.add(request.method+" "+path)
                    if(path=="/api/v1/source-selections") {
                        entered.countDown();check(release.await(10,TimeUnit.SECONDS))
                        return mockwebserver3.MockResponse.Builder().code(201).body(DiscoveryOwnershipTest.decision()).build()
                    }
                    return mockwebserver3.MockResponse.Builder().code(503).body("{}").build()
                }}
                val work=pool.submit {imports.submit(post)}
                assertTrue(entered.await(5,TimeUnit.SECONDS))
                val captured=IntakeReceipts(file).entries(f.endpoint.identity,"A").single()
                assertEquals("pending",captured.phase);assertEquals(41L,captured.playlistId)
                assertEquals(selection,captured.sessionId);assertEquals("candidate-1",captured.candidateId)
                assertNull(captured.decisionId);assertNull(captured.job)
                release.countDown();work.get(10,TimeUnit.SECONDS)
                imports.submit(post);assertNull(imports.claimSource(view,choice))
                assertNull(imports.state.value.acknowledgement)
                assertEquals(com.soundq.android.data.discovery.SourceImportPhase.QueueUncertain,imports.state.value.sourceReceipt?.phase)
                assertTrue(library.state.value.rows.isEmpty())
                val restoredApi=SoundQApi(session,f.client,IntakeReceipts(file))
                val restoredLibrary=LibraryRepository(session,restoredApi::library,restoredApi::like)
                val restored=ImportRepository(session,restoredApi,restoredLibrary)
                val current=restored.open()!!
                assertEquals(41L,restored.state.value.durableReceipt?.playlistId)
                val member=java.util.concurrent.atomic.AtomicBoolean(false)
                val membershipReadFails=java.util.concurrent.atomic.AtomicBoolean(false)
                f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    val path=request.url.encodedPath;paths.add(request.method+" "+path)
                    if(path=="/api/v1/playlists/41"&&membershipReadFails.get())return mockwebserver3.MockResponse.Builder().code(503).body("{}").build()
                    return mockwebserver3.MockResponse.Builder().code(if(request.method=="POST")202 else 200).body(when {
                        path=="/api/v1/source-selections/$decision"->DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"$job\"")
                        path=="/api/v1/queue/items"->{
                            val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                            assertEquals(41L,body.getValue("playlistId").jsonPrimitive.long)
                            assertEquals(decision,body.getValue("sourceDecisionId").jsonPrimitive.content)
                            """{"queue":{"items":[]},"downloadJobId":"$job","idempotent":true}"""
                        }
                        path=="/api/v1/downloads/$job"->jobBody()
                        path=="/api/v1/library"->libraryBody(request.url.queryParameter("limit")?.toInt() ?: 20)
                        path=="/api/v1/playlists/41"->playlistDetail(member.get())
                        else->error("unexpected fixture request $path")
                    }).build()
                }}
                restored.retryDurablePublication(current,restored.state.value.durableReceipt!!)
                assertEquals(job,restored.state.value.acknowledgement?.id?.value)
                assertNull(restored.state.value.selected)
                restored.check(current)
                assertEquals(TrackId(71),restored.state.value.selected?.track)
                assertEquals(ImportPlaylistPhase.AwaitingMembership,restored.state.value.playlistConfirmation?.phase)
                assertTrue("Membership checks must not replace ordinary Library filters/rows",restoredLibrary.state.value.rows.isEmpty())
                membershipReadFails.set(true);restored.check(current)
                assertNotNull(restored.state.value.error)
                assertFalse(restored.state.value.loading)
                assertEquals(ImportPlaylistPhase.AwaitingMembership,restored.state.value.playlistConfirmation?.phase)
                membershipReadFails.set(false);member.set(true);restored.check(current)
                val confirmation=restored.state.value.playlistConfirmation!!
                assertEquals(ImportPlaylistPhase.Confirmed,confirmation.phase)
                assertEquals(job,confirmation.job.value);assertEquals(TrackId(71),confirmation.track)
                assertEquals(com.soundq.android.data.playlists.PlaylistId(41),confirmation.playlist)
                f.server.takeRequest(3,TimeUnit.SECONDS)!! // original search
                f.server.takeRequest(3,TimeUnit.SECONDS)!! // destination read
                assertEquals(listOf("POST /api/v1/source-selections","POST /api/v1/queue/items","POST /api/v1/queue/items"),paths.filter {it.startsWith("POST")})
                assertFalse(paths.any {it.endsWith("/tracks")})
                assertFalse(file.readText().contains("https://youtu.be"))
                // Explicit Open uses the ordinary acknowledged Library owner, not the playlist read.
                assertTrue(restored.openLibrary(current))
                assertEquals(TrackId(71),restoredLibrary.state.value.rows.single().id)
                var opened:com.soundq.android.data.playlists.PlaylistId?=null
                assertTrue(restored.openPlaylistTarget(current,confirmation){opened=it})
                assertEquals(com.soundq.android.data.playlists.PlaylistId(41),opened)
                assertFalse(restored.openPlaylistTarget(current,confirmation.copy()){error("copied confirmation must not navigate")})
                restored.another(current)
                assertFalse(restored.openPlaylistTarget(current,confirmation){error("retired confirmation must not navigate")})
            } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(5,TimeUnit.SECONDS);dir.deleteRecursively()}
        }
    }

    private fun playlistPage()="""{"data":[{"id":41,"name":"Captured target","isPublic":false,"trackCount":0,"durationMs":0}],"total":1,"limit":20,"offset":0}"""
    private fun jobBody()="""{"job_id":"$job","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}"""
    private fun libraryBody(limit:Int=20)="""{"tracks":[{"id":71,"title":"Exact imported Library row","is_liked":false,"has_metadata_override":false,"mb_verified":false}],"total":1,"limit":$limit,"offset":0}"""
    private fun playlistDetail(member:Boolean)="""{"id":41,"name":"Captured target","isPublic":false,"trackCount":${if(member)1 else 0},"durationMs":0,"tracks":${if(member)"[{\"id\":71,\"title\":\"Exact imported Library row\"}]" else "[]"}}"""

    @Test fun uncertainDecisionRecoversExactSourceAndTargetBeforeFirstPublicationAndAccountReplacement() {
        HttpsFixture().use {f->
            val dir=Files.createTempDirectory("uncertain-target").toFile()
            try {
                val file=dir.resolve("intake.json")
                val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
                val api=SoundQApi(session,f.client,IntakeReceipts(file))
                val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like))
                val discovery=com.soundq.android.data.discovery.DiscoveryRepository(session,api)
                val route=discovery.open()!!
                discovery.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discovery.search(route,discovery.state.value.draft)
                val choice=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
                val view=imports.open()!!
                val post=imports.claimSource(view,choice,com.soundq.android.data.playlists.PlaylistId(41))!!
                f.reply("{}",503);imports.submit(post)
                val restoredApi=SoundQApi(session,f.client,IntakeReceipts(file))
                val restored=ImportRepository(session,restoredApi,LibraryRepository(session,restoredApi::library,restoredApi::like))
                val current=restored.open()!!
                val saved=restored.state.value.durableReceipt!!
                assertEquals(41L,saved.playlistId);assertNull(saved.job);assertNull(saved.decisionId)
                assertNull(restored.claimSource(current,choice))
                f.reply("""{"items":[${DiscoveryOwnershipTest.decision()}],"limit":100,"offset":0}""")
                restored.recoverDurable(current,saved)
                assertNull(restored.state.value.selected)
                assertEquals(decision,restored.state.value.durableReceipt?.decisionId)
                assertNull(restored.state.value.durableReceipt?.job)
                assertEquals(3,f.server.requestCount)
                f.reply("""{"queue":{"items":[]},"downloadJobId":"$job","idempotent":false}""",202)
                restored.retryDurablePublication(current,restored.state.value.durableReceipt!!)
                f.reply(jobBody().replace("\"complete\"","\"queued\"").replace("\"track_id\":71","\"track_id\":null").replace("\"progress\":100","\"progress\":0"))
                restored.check(current)
                assertEquals(job,restored.state.value.selected?.id?.value)
                assertEquals(ImportPlaylistPhase.AwaitingImport,restored.state.value.playlistConfirmation?.phase)
                assertEquals(41L,IntakeReceipts(file).entries(f.endpoint.identity,"A").single().playlistId)
                val requests=(1..5).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
                assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/source-selections"})
                assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/queue/items"})
                assertEquals("/api/v1/source-selections",requests[2].url.encodedPath)
                assertEquals(41L,Json.parseToJsonElement(requests[3].body!!.utf8()).jsonObject.getValue("playlistId").jsonPrimitive.long)
                assertEquals("/api/v1/downloads/$job",requests[4].url.encodedPath)
                val old=restored.state.value.durableReceipt!!
                session.accept(session.beginIntent(),SecretTokens("b","br","B"))
                val other=restored.open()!!
                restored.recoverDurable(other,old);restored.retryDurablePublication(other,old)
                assertNull(restored.state.value.durableReceipt)
                assertEquals(5,f.server.requestCount)
            } finally {dir.deleteRecursively()}
        }
    }

    @Test fun recoveringSourceRetiresASiblingJobsPlaylistConfirmationBeforeAnyNavigation() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client)
            val sibling="123e4567-e89b-12d3-a456-426614174099"
            val saved=api.intakeReceipts.begin(f.endpoint.identity,"A","source",sessionId="123e4567-e89b-12d3-a456-426614174011",candidateId="other-candidate",decisionId="123e4567-e89b-12d3-a456-426614174098",job=sibling,playlistId=42)
            api.intakeReceipts.finish(f.endpoint.identity,"A",saved,"accepted",sibling)
            val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like))
            val discovery=com.soundq.android.data.discovery.DiscoveryRepository(session,api)
            val route=discovery.open()!!
            discovery.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discovery.search(route,discovery.state.value.draft)
            val choice=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
            val view=imports.open()!!
            imports.another(view)
            f.reply(DiscoveryOwnershipTest.decision(),201)
            f.reply("""{"queue":{"items":[]},"downloadJobId":"$job","idempotent":false}""",202)
            imports.submit(imports.claimSource(view,choice,com.soundq.android.data.playlists.PlaylistId(41))!!)
            val source=imports.state.value.sourceReceipt!!
            val siblingJob=jobBody().replace(job,sibling).replace("\"track_id\":71","\"track_id\":99")
            f.reply("""{"jobs":[$siblingJob]}""");imports.recent(view);imports.select(view,imports.state.value.recent.single())
            f.reply(siblingJob);f.reply(libraryBody(100).replace("\"id\":71","\"id\":99"));f.reply(playlistDetail(true).replace("\"id\":41","\"id\":42").replace("\"id\":71","\"id\":99"))
            imports.check(view)
            val confirmedSibling=imports.state.value.playlistConfirmation!!
            assertEquals(ImportPlaylistPhase.Confirmed,confirmedSibling.phase)
            assertEquals(com.soundq.android.data.playlists.PlaylistId(42),confirmedSibling.playlist)
            f.reply(DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"$job\""));f.reply(jobBody())
            imports.recoverSource(view,source)
            assertNull(imports.state.value.selected)
            assertEquals(job,imports.state.value.acknowledgement?.id?.value)
            assertNull("A source recovery may not keep a different job's confirmed destination",imports.state.value.playlistConfirmation)
            assertFalse(imports.openPlaylistTarget(view,confirmedSibling){error("stale sibling destination")})
        }
    }

    @Test fun savedTargetSurvivesRestartAndExplicitSameDecisionPublication() {
        HttpsFixture().use {f->
            val dir=Files.createTempDirectory("import-target").toFile()
            try {
                val file=dir.resolve("intake.json")
                // A persisted source operation, not a new source decision on restart.
                val owner=buildJsonArray {add(f.endpoint.identity);add("A")}.toString()
                file.writeText(buildJsonObject {
                    put("version",1);put("owners",buildJsonObject {put(owner,buildJsonArray {add(buildJsonObject {
                        put("operation",1);put("kind","source");put("phase","uncertain")
                        put("sessionId",selection);put("candidateId","youtube:fixture");put("decisionId",decision);put("playlistId",41)
                    })})})
                }.toString())
                val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
                val api=SoundQApi(session,f.client,IntakeReceipts(file))
                val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like))
                val view=imports.open()!!
                f.reply("""{"queue":{"items":[]},"downloadJobId":"$job","idempotent":true}""",200)
                imports.retryDurablePublication(view,imports.state.value.durableReceipt!!)
                val request=f.server.takeRequest(3,TimeUnit.SECONDS)!!
                assertEquals("POST",request.method)
                assertEquals("/api/v1/queue/items",request.url.encodedPath)
                val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                assertEquals(decision,body["sourceDecisionId"]?.jsonPrimitive?.content)
                assertEquals("Captured playlist must not be dropped when publication is retried",41L,body["playlistId"]?.jsonPrimitive?.longOrNull)
                assertEquals(job,imports.state.value.acknowledgement?.id?.value)
                assertEquals(41L,Json.parseToJsonElement(file.readText()).jsonObject["owners"]!!.jsonObject[owner]!!.jsonArray.single().jsonObject["playlistId"]?.jsonPrimitive?.longOrNull)
                assertEquals(1,f.server.requestCount)
            } finally {dir.deleteRecursively()}
        }
    }
}
