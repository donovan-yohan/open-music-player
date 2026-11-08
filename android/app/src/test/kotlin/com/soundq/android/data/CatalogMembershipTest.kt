package com.soundq.android.data

import com.soundq.android.data.catalog.*
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.*

class CatalogMembershipTest {
    private val account=CatalogContractTest.A
    private val recording=RecordingMbid(CatalogContractTest.T)
    private fun obj(s:String)=Json.parseToJsonElement(s).jsonObject
    private fun resolution(owned:Boolean=false,id:Long=7,verified:Boolean=true)="""{"recordingMbid":"${recording.value}","userId":"$account","status":"${if(!verified)"needs_review" else if(owned)"owned" else "stored_unowned"}","candidates":[{"trackId":$id,"mbVerified":$verified,"inLibrary":$owned}],"limit":20,"truncated":false}"""
    private fun library(id:Long=7,mbid:String=recording.value,verified:Boolean=true)="""{"tracks":[{"id":$id,"title":"Stored","artist":"Artist","album":"Album","duration_ms":0,"is_liked":false,"has_metadata_override":false,"mb_verified":$verified,"mb_recording_id":"$mbid"}],"total":1,"limit":100,"offset":0}"""
    private fun ack()="""{"recordingMbid":"${recording.value}","userId":"$account","trackId":7,"status":"member","addedAt":"2026-11-06T02:56:02.57134Z"}"""
    private fun signed(f:HttpsFixture,who:String=account)=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r",who))}
    private fun ready(f:HttpsFixture,journal:CatalogMembershipJournal=CatalogMembershipJournal(),album:String=CatalogContractTest.album()):Pair<CatalogRepository,CatalogActions> {
        val repo=CatalogRepository(SoundQApi(signed(f),f.client),journal);val actions=CatalogActions(repo){it()}
        f.reply(CatalogContractTest.releases());actions.submit("Concrete",true)
        var s=repo.state.value;f.reply(album);actions.album(s,s.albums!!.rows.first())
        s=repo.state.value;f.reply(resolution());actions.recording(s,s.album!!.tracks.single(),0)
        return repo to actions
    }
    @Test fun allSevenActualProducerBodiesUseProductionDecoder() {
        val names=listOf("200-member","400-VALIDATION_ERROR","401-UNAUTHORIZED","404-TARGET_UNAVAILABLE","409-TARGET_MISMATCH","409-NEEDS_REVIEW","503-SERVICE_DISABLED")
        for(name in names) {
            val body=obj(javaClass.getResource("/catalog-membership/$name.json")!!.readText());val status=name.substringBefore('-').toInt()
            if(status==200)CatalogMembershipJson.ack(body,RecordingMbid(body.getValue("recordingMbid").jsonPrimitive.content),body.getValue("userId").jsonPrimitive.content,body.getValue("trackId").jsonPrimitive.long)
            else assertNotNull(CatalogMembershipJson.refusal(status,body))
        }
        for((key,value) in listOf("trackId" to JsonPrimitive("7"),"trackId" to JsonPrimitive(8),"userId" to JsonPrimitive(CatalogContractTest.G),"recordingMbid" to JsonPrimitive(CatalogContractTest.R),"status" to JsonPrimitive("owned"),"addedAt" to JsonPrimitive("yesterday"))) {
            assertTrue(runCatching {CatalogMembershipJson.ack(JsonObject(obj(ack())+(key to value)),recording,account,7)}.isFailure)
        }
    }
    @Test fun addRequiresExactResolverAndCanonicalLibraryReadback() {HttpsFixture().use {f->
        val (repo,actions)=ready(f);f.reply(ack());f.reply(resolution(true));f.reply(library())
        actions.addRecording(repo.state.value.inspection!!)
        assertEquals("Added",repo.state.value.inspection!!.membership)
        assertTrue(repo.state.value.recoveries.isEmpty())
        val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
        val post=requests.single {it.method=="POST"};assertEquals("/api/v1/catalog/recordings/${recording.value}/membership",post.url.encodedPath);assertEquals("{\"trackId\":7}",post.body!!.utf8())
        actions.addRecording(repo.state.value.inspection!!);assertEquals(6,f.server.requestCount)
        actions.back();assertNotNull(repo.state.value.album);actions.back();assertNotNull(repo.state.value.albums)
    }}
    @Test fun actualPostCommitDisconnectSurvivesFreshRepositoryAndNeverReposts() {HttpsFixture().use {f->
        val dir=Files.createTempDirectory("catalog-journal").toFile();val file=File(dir,"journal.json")
        try {
            val (repo,actions)=ready(f,CatalogMembershipJournal(file))
            val committed=java.util.concurrent.atomic.AtomicBoolean(false);val mutations=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                return when {
                    request.method=="POST"->{assertEquals("{\"trackId\":7}",request.body!!.utf8());mutations.incrementAndGet();committed.set(true);MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()}
                    request.url.encodedPath.endsWith("/resolution")->MockResponse.Builder().body(resolution(committed.get())).build()
                    request.url.encodedPath.endsWith("/library")->MockResponse.Builder().body(if(committed.get())library() else "{\"tracks\":[],\"total\":0,\"limit\":100,\"offset\":0}").build()
                    else->error("Unexpected request")
                }
            }}
            actions.addRecording(repo.state.value.inspection!!)
            assertTrue(committed.get());assertEquals("Unconfirmed",repo.state.value.inspection!!.membership);actions.close()
            val fresh=CatalogRepository(SoundQApi(signed(f),f.client),CatalogMembershipJournal(file));val next=CatalogActions(fresh){it()}
            assertEquals(1,fresh.state.value.recoveries.size)
            next.checkMembership(fresh.state.value.recoveries.single())
            assertTrue(fresh.state.value.recoveries.isEmpty());assertEquals("In your Library",fresh.state.value.membershipNotice)
            val requests=(1..f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!};assertEquals(1,requests.count {it.method=="POST"});assertEquals(1,mutations.get())
        } finally {dir.deleteRecursively()}
    }}
    @Test fun responseFollowupsCannotEnterTheSamePostTwice() {
        for(code in listOf(408,503,307,401))HttpsFixture().use {f->
            val api=SoundQApi(signed(f),f.client)
            f.server.enqueue(MockResponse.Builder().code(code).addHeader("Retry-After","0").addHeader("Location",f.server.url("/api/v1/catalog/recordings/${recording.value}/membership")).body("{}").build())
            f.reply(ack())
            val result=runCatching {api.catalogMembership(api.session.capture()!!,recording,7,{true},{true})}
            assertEquals("actual network exchanges for status $code",1,f.server.requestCount);assertTrue(result.isFailure)
        }
    }
    @Test fun freshRecoveryRequiresReadThenExplicitExactRetry() {HttpsFixture().use {f->
        val (repo,actions)=ready(f);f.reply("{}",500);actions.addRecording(repo.state.value.inspection!!)
        val pending=repo.state.value.recoveries.single();actions.retryMembership(pending);assertEquals(4,f.server.requestCount)
        f.reply(resolution());f.reply("{\"tracks\":[],\"total\":0,\"limit\":100,\"offset\":0}");actions.checkMembership(pending)
        val eligible=repo.state.value.recoveries.single();assertTrue(eligible.retryEligible)
        f.reply(ack());f.reply(resolution(true));f.reply(library());actions.retryMembership(eligible)
        assertTrue(repo.state.value.recoveries.isEmpty());assertEquals("Added",repo.state.value.inspection!!.membership)
    }}
    @Test fun wrongReadbackOrMalformedAckNeverCompletes() {
        for(mode in listOf("ack","numeric","mbid","verification","resolver"))HttpsFixture().use {f->
            val (repo,actions)=ready(f);f.reply(if(mode=="ack")"{}" else ack())
            if(mode!="ack") {f.reply(if(mode=="resolver")resolution(true,8) else resolution(true));if(mode!="resolver")f.reply(when(mode){"numeric"->library(8);"mbid"->library(mbid=CatalogContractTest.R);"verification"->library(verified=false);else->library()})}
            actions.addRecording(repo.state.value.inspection!!)
            assertNotEquals(mode,"Added",repo.state.value.inspection!!.membership);assertEquals(1,repo.state.value.recoveries.size)
        }
    }
    @Test fun queuedActionsCannotDispatchAfterCloseBackAbaOrLock() {
        for(mode in listOf("close","back","aba","lock"))HttpsFixture().use {f->
            val (repo,initial)=ready(f);val jobs=mutableListOf<()->Unit>()
            val actions=CatalogActions(repo){jobs.add(it)}
            // Reload through the actual queued owner, then capture the rendered action.
            f.reply(CatalogContractTest.releases());actions.submit("Concrete",true);jobs.removeAt(0)()
            var s=repo.state.value;f.reply(CatalogContractTest.album());actions.album(s,s.albums!!.rows.first());jobs.removeAt(0)()
            s=repo.state.value;f.reply(resolution());actions.recording(s,s.album!!.tracks.single(),0);jobs.removeAt(0)()
            val old=repo.state.value.inspection!!;actions.addRecording(old)
            when(mode){"close"->actions.close();"back"->actions.back();"aba"->{actions.back();actions.recording(repo.state.value,repo.state.value.album!!.tracks.single(),0)};"lock"->actions.view!!.scope.owner.lockLocal()}
            val count=f.server.requestCount;jobs.removeAt(0)();assertEquals(mode,count,f.server.requestCount)
            initial.close()
        }
    }
    @Test fun unavailableStoragePreventsEveryPossibleWrite() {HttpsFixture().use {f->
        val dir=Files.createTempDirectory("catalog-storage").toFile();val parent=File(dir,"not-directory").apply {writeText("preserve")}
        try {
            val (repo,actions)=ready(f,CatalogMembershipJournal(File(parent,"journal")));val count=f.server.requestCount
            actions.addRecording(repo.state.value.inspection!!);assertEquals(count,f.server.requestCount);assertEquals("Recovery unavailable",repo.state.value.membershipNotice);assertEquals("preserve",parent.readText())
        } finally {dir.deleteRecursively()}
    }}
    @Test fun ownedMissingAmbiguousAndUnverifiedInspectionsCannotPost() {HttpsFixture().use {f->
        val (repo,actions)=ready(f)
        val choices=listOf(resolution(true),resolution(verified=false),"""{"recordingMbid":"${recording.value}","userId":"$account","status":"missing","candidates":[],"limit":20,"truncated":false}""", """{"recordingMbid":"${recording.value}","userId":"$account","status":"ambiguous","candidates":[{"trackId":7,"mbVerified":true,"inLibrary":false},{"trackId":8,"mbVerified":true,"inLibrary":true}],"limit":20,"truncated":false}""")
        for(body in choices) {actions.back();val s=repo.state.value;f.reply(body);actions.recording(s,s.album!!.tracks.single(),0);val count=f.server.requestCount;actions.addRecording(repo.state.value.inspection!!);assertEquals(count,f.server.requestCount)}
    }}
    @Test fun actualNetworkAdmissionRefusesRetiredOrLockedOwnerBeforePost() {
        for(mode in listOf("lock","account","target"))HttpsFixture().use {f->
            val session=signed(f);var target=true
            val client=f.client.newBuilder().addInterceptor {chain->when(mode){"lock"->session.lockLocal();"account"->session.accept(session.beginIntent(),SecretTokens("b","r",CatalogContractTest.G));else->target=false};chain.proceed(chain.request())}.build()
            try {
                val api=SoundQApi(session,client);val scope=session.capture()!!
                assertTrue(runCatching {api.catalogMembership(scope,recording,7,{target},{target})}.isFailure);assertEquals(0,f.server.requestCount)
            } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
        }
    }
    @Test fun queuedRecoveryCannotDispatchAfterReleaseGroupNavigation() {HttpsFixture().use {f->
        val (repo,actions)=ready(f);f.reply("{}",500);actions.addRecording(repo.state.value.inspection!!)
        f.reply(CatalogContractTest.search());actions.submit("artist",false)
        var s=repo.state.value;f.reply(CatalogContractTest.artist());actions.artist(s,s.search!!.rows.single())
        s=repo.state.value;val request=repo.checkMembership(actions.view!!,s.recoveries.single())!!
        actions.group(repo.state.value,repo.state.value.artist!!.releases.single())
        val count=f.server.requestCount;f.reply(resolution(true));f.reply(library());repo.executeMembership(request);assertEquals(count,f.server.requestCount)
    }}
    @Test fun queuedRecoveryReadRetiresOnNavigationAndReleasesItsBusyRow() {HttpsFixture().use {f->
        val (repo,actions)=ready(f);f.reply("{}",500);actions.addRecording(repo.state.value.inspection!!)
        val view=actions.view!!;val recovery=repo.state.value.recoveries.single()
        val request=repo.checkMembership(view,recovery)!!;repo.back(view)
        val count=f.server.requestCount;f.reply(resolution(true));f.reply(library());repo.executeMembership(request)
        assertEquals(count,f.server.requestCount);assertFalse(repo.state.value.recoveries.single().busy)
        assertNotNull(repo.checkMembership(view,repo.state.value.recoveries.single()))
    }}
    @Test fun navigationDuringEnteredPostLeavesTruthfulUnconfirmedRecovery() {HttpsFixture().use {f->
        val (repo,actions)=ready(f);val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
        val request=repo.addRecording(actions.view!!,repo.state.value.inspection!!)!!
        f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(ack()).build()}}
        try {val job=pool.submit {repo.executeMembership(request)};assertTrue(entered.await(3,TimeUnit.SECONDS));actions.back();release.countDown();job.get(5,TimeUnit.SECONDS)
            assertEquals("Unconfirmed",repo.state.value.recoveries.single().status);assertFalse(repo.state.value.recoveries.single().busy);assertNull(repo.state.value.inspection);assertEquals(4,f.server.requestCount)
        } finally {release.countDown();pool.shutdownNow()}
    }}
    @Test fun heldEnteredMutationCannotPublishIntoReopenedOwnerAndJournalRemains() {HttpsFixture().use {f->
        val dir=Files.createTempDirectory("catalog-held").toFile();val file=File(dir,"journal")
        val pool=Executors.newSingleThreadExecutor();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        try {
            val (repo,actions)=ready(f,CatalogMembershipJournal(file));val request=repo.addRecording(actions.view!!,repo.state.value.inspection!!)!!
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(ack()).build()}}
            val work=pool.submit {repo.executeMembership(request)};assertTrue(entered.await(3,TimeUnit.SECONDS))
            assertEquals(1,CatalogMembershipJournal(file).entries(f.endpoint.identity,account).size)
            actions.close();val replacement=CatalogActions(repo){it()};assertEquals(1,repo.state.value.recoveries.size)
            release.countDown();work.get(5,TimeUnit.SECONDS)
            assertNull(repo.state.value.membershipNotice);assertEquals(1,repo.state.value.recoveries.size);assertFalse(repo.state.value.recoveries.single().busy)
            assertEquals(4,f.server.requestCount);replacement.close()
        } finally {release.countDown();pool.shutdownNow();dir.deleteRecursively()}
    }}
    @Test fun journalCapacityAndMalformedRestorationNeverDropUnresolvedEntries() {
        val dir=Files.createTempDirectory("catalog-bounds").toFile();val file=File(dir,"journal")
        try {
            val endpoint="https://fixture.invalid/api/v1";val journal=CatalogMembershipJournal(file)
            fun intent(n:Int)=CatalogMembershipIntent(java.util.UUID.randomUUID().toString(),endpoint,account,"123e4567-e89b-12d3-a456-${n.toString().padStart(12,'0')}",n.toLong(),CatalogContractTest.R,n,"Recording $n")
            repeat(32){journal.prepare(intent(it+1))};val bytes=file.readBytes()
            assertTrue(runCatching {journal.prepare(intent(33))}.isFailure);assertArrayEquals(bytes,file.readBytes());assertEquals(32,CatalogMembershipJournal(file).entries(endpoint,account).size)
            val good=obj(file.readText());val entries=good.getValue("entries").jsonArray
            for((key,value) in listOf("account" to JsonPrimitive("00000000-0000-0000-0000-000000000000"),"track" to JsonPrimitive("1"),"track" to Json.parseToJsonElement("9223372036854775808"),"occurrence" to JsonPrimitive(-1),"endpoint" to JsonPrimitive("https://other.invalid/api/v1/"))) {
                val bad=JsonObject(good+("entries" to JsonArray(listOf(JsonObject(entries.first().jsonObject+(key to value)))))).toString();file.writeText(bad)
                val rejected=CatalogMembershipJournal(file);assertTrue(runCatching {rejected.entries(endpoint,account)}.isFailure);assertTrue(runCatching {rejected.prepare(intent(40))}.isFailure);assertEquals(bad,file.readText())
            }
        } finally {dir.deleteRecursively()}
    }
    @Test fun journalByteBudgetRoundTripsMaximumMultibyteAndEscapedTitles() {
        val titles=listOf("曲".repeat(16384),"\"\\\n\t".repeat(4096),"🎵".repeat(8192))
        for(title in titles) {
            val dir=Files.createTempDirectory("catalog-encoded-bounds").toFile();val file=File(dir,"journal")
            try {
                val endpoint="https://fixture.invalid/api/v1";val journal=CatalogMembershipJournal(file)
                val accepted=mutableListOf<CatalogMembershipIntent>();var refused=false
                for(n in 1..32) {
                    val intent=CatalogMembershipIntent(java.util.UUID.randomUUID().toString(),endpoint,account,"123e4567-e89b-12d3-a456-${n.toString().padStart(12,'0')}",n.toLong(),CatalogContractTest.R,n,title)
                    val before=if(file.exists())file.readBytes() else byteArrayOf()
                    if(runCatching {journal.prepare(intent)}.isSuccess)accepted.add(intent)
                    else {refused=true;assertArrayEquals(before,file.readBytes())}
                    assertEquals(accepted,journal.entries(endpoint,account))
                    assertEquals(accepted,CatalogMembershipJournal(file).entries(endpoint,account))
                    assertTrue(file.length()<=1_000_000)
                    if(refused)break
                }
                assertTrue("Serialized capacity must refuse without dropping prior entries",refused)
                assertTrue(accepted.isNotEmpty())
                journal.confirm(accepted.first());accepted.removeAt(0)
                assertEquals(accepted,CatalogMembershipJournal(file).entries(endpoint,account))
            } finally {dir.deleteRecursively()}
        }
    }
    @Test fun journalBudgetRefusesPreparationBeforePostAndPreservesExistingRecovery() {HttpsFixture().use {f->
        val dir=Files.createTempDirectory("catalog-admission-bounds").toFile();val file=File(dir,"journal")
        try {
            val journal=CatalogMembershipJournal(file);val title="曲".repeat(16384)
            repeat(20) {index->val n=index+100;journal.prepare(CatalogMembershipIntent(java.util.UUID.randomUUID().toString(),f.endpoint.identity,account,"123e4567-e89b-12d3-a456-${n.toString().padStart(12,'0')}",n.toLong(),CatalogContractTest.R,index,title))}
            val before=file.readBytes();assertTrue(before.size<1_000_000)
            val album=obj(CatalogContractTest.album());val row=album.getValue("tracks").jsonArray.single().jsonObject
            val largeAlbum=JsonObject(album+("tracks" to JsonArray(listOf(JsonObject(row+("title" to JsonPrimitive(title))))))).toString()
            val (repo,actions)=ready(f,journal,largeAlbum);val calls=f.server.requestCount
            val posts=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {if(request.method=="POST")posts.incrementAndGet();return MockResponse.Builder().code(500).body("{}").build()}}
            actions.addRecording(repo.state.value.inspection!!)
            assertEquals(0,posts.get());assertEquals(calls,f.server.requestCount)
            assertEquals("Unavailable",repo.state.value.inspection!!.membership)
            assertArrayEquals(before,file.readBytes())
            assertEquals(20,CatalogMembershipJournal(file).entries(f.endpoint.identity,account).size)
            assertEquals(20,repo.state.value.recoveries.size)
            actions.close()
        } finally {dir.deleteRecursively()}
    }}
    @Test fun freshJvmReconcilesCommittedLostAckWithoutAnotherPost() {HttpsFixture().use {f->
        val dir=Files.createTempDirectory("catalog-process").toFile();val file=File(dir,"journal")
        try {
            val (repo,actions)=ready(f,CatalogMembershipJournal(file))
            f.reply("{}");val certificate=f.client.newCall(okhttp3.Request.Builder().url(f.server.url("/fixture-public-cert")).build()).execute().use {it.handshake!!.peerCertificates.first()}
            val cert=File(dir,"public.der");cert.writeBytes(certificate.encoded)
            val mutations=java.util.concurrent.atomic.AtomicInteger();val committed=java.util.concurrent.atomic.AtomicBoolean(false)
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse = when {
                request.method=="POST"->{mutations.incrementAndGet();committed.set(true);MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()}
                request.url.encodedPath.endsWith("/resolution")->MockResponse.Builder().body(resolution(committed.get())).build()
                request.url.encodedPath.endsWith("/library")->MockResponse.Builder().body(library()).build()
                else->error("Unexpected path")
            }}
            actions.addRecording(repo.state.value.inspection!!);actions.close();assertTrue(committed.get())
            val process=ProcessBuilder(System.getProperty("java.home")+"/bin/java","-Djava.io.tmpdir="+System.getProperty("java.io.tmpdir"),"-cp",System.getProperty("java.class.path"),"com.soundq.android.data.CatalogMembershipTest",f.endpoint.identity,file.absolutePath,cert.absolutePath).redirectErrorStream(true).start()
            try {assertTrue(process.waitFor(10,TimeUnit.SECONDS));val result=process.inputStream.bufferedReader().readText();assertEquals(result,0,process.exitValue());assertTrue(result.contains("FRESH_JVM_CONFIRMED_NO_POST"));println(result.trim())}
            finally {if(process.isAlive)process.destroyForcibly().waitFor()}
            assertEquals(1,mutations.get());assertTrue(CatalogMembershipJournal(file).entries(f.endpoint.identity,account).isEmpty())
        } finally {dir.deleteRecursively()}
    }}
    companion object {
        @JvmStatic fun main(args:Array<String>) {
            val endpoint=ApiEndpoint.parse(args[0]);require(endpoint.base.host=="localhost")
            val certificate=File(args[2]).inputStream().use {java.security.cert.CertificateFactory.getInstance("X.509").generateCertificate(it) as java.security.cert.X509Certificate}
            val trust=okhttp3.tls.HandshakeCertificates.Builder().addTrustedCertificate(certificate).build()
            val client=okhttp3.OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
            try {
                val session=AccountSession(endpoint,MemoryStore());check(session.accept(session.beginIntent(),SecretTokens("a","r",CatalogContractTest.A)))
                val repo=CatalogRepository(SoundQApi(session,client),CatalogMembershipJournal(File(args[1])));val actions=CatalogActions(repo){it()}
                check(repo.state.value.recoveries.size==1);actions.checkMembership(repo.state.value.recoveries.single());check(repo.state.value.recoveries.isEmpty());check(repo.state.value.membershipNotice=="In your Library")
                println("FRESH_JVM_CONFIRMED_NO_POST");actions.close()
            } finally {client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
        }
    }
    @Test fun journalRejectsCorruptionAndQualifiesDurableOwnerNotEpoch() {HttpsFixture().use {f->
        val dir=Files.createTempDirectory("catalog-owner").toFile();val file=File(dir,"journal.json")
        try {
            val (repo,actions)=ready(f,CatalogMembershipJournal(file));f.reply("{}",500);actions.addRecording(repo.state.value.inspection!!)
            val bytes=file.readBytes()
            val b=CatalogRepository(SoundQApi(signed(f,CatalogContractTest.G),f.client),CatalogMembershipJournal(file));CatalogActions(b){it()};assertTrue(b.state.value.recoveries.isEmpty())
            val other=AccountSession(ApiEndpoint.parse("https://other.invalid/api/v1"),MemoryStore());other.accept(other.beginIntent(),SecretTokens("b","r",account))
            val c=CatalogRepository(SoundQApi(other,f.client),CatalogMembershipJournal(file));CatalogActions(c){it()};assertTrue(c.state.value.recoveries.isEmpty());assertArrayEquals(bytes,file.readBytes())
            val returning=CatalogRepository(SoundQApi(signed(f),f.client),CatalogMembershipJournal(file));CatalogActions(returning){it()};assertEquals(1,returning.state.value.recoveries.size)
            file.writeText("{\"version\":999}");val corrupt=CatalogRepository(SoundQApi(signed(f),f.client),CatalogMembershipJournal(file));val ca=CatalogActions(corrupt){it()}
            assertEquals("Recovery unavailable",corrupt.state.value.membershipNotice)
            f.reply(CatalogContractTest.releases());ca.submit("Concrete",true);assertNotNull(corrupt.state.value.albums);assertEquals("{\"version\":999}",file.readText())
        } finally {dir.deleteRecursively()}
    }}
}
