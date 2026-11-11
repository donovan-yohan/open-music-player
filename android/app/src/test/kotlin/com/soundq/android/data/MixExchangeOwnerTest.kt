package com.soundq.android.data

import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import mockwebserver3.*

class MixExchangeOwnerTest {
    private fun fixture(name:String)=javaClass.getResource("/mix-exchange/$name")!!.readText(Charsets.UTF_8)
    private val input get()=fixture("import-input.json")
    private val ack get()=fixture("import-ack.json")
    private val id get()=Json.parseToJsonElement(ack).jsonObject.getValue("id").jsonPrimitive.content
    private fun setup(f:HttpsFixture):Pair<AccountSession,SoundQApi> {
        val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        return session to SoundQApi(session,f.client)
    }
    @Test fun realGoProducerBytesImportReadBackThenExportWithoutAudioAuthority() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val route=owner.bind(null)
            assertTrue(route.edit(input));f.reply(ack,201);f.reply(fixture("import-readback.json"))
            val saved=route.importMix()!!
            assertEquals(listOf("instance","repeat"),saved.clips.map {it.id});assertEquals(listOf(77L,77L),saved.clips.map {it.track})
            assertEquals(listOf(200L,0L),saved.clips.map {it.fadeIn});assertEquals(listOf(300L,0L),saved.clips.map {it.fadeOut})
            assertNotEquals(saved.clips[0].stems,saved.clips[1].stems)
            assertEquals(Json.parseToJsonElement(ack).jsonObject.getValue("clips").jsonArray[0].jsonObject["stemEdits"],saved.clips[0].stems)
            val post=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",post.method);assertEquals("/api/v1/mix-plans/import",post.url.encodedPath)
            assertEquals(input,post.body!!.utf8());assertEquals("application/json; charset=utf-8",post.headers["Content-Type"])
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
            assertNull(route.importMix());assertEquals(2,f.server.requestCount)
            val export=owner.bind(saved);val portable=" \n"+fixture("export.json")+"\n "
            f.reply(portable);assertTrue(export.loadExport());var copied:String?=null
            assertTrue(export.copyExport {copied=it});assertEquals(portable,copied)
            assertFalse(copied!!.contains("trackId"));assertFalse(copied.contains("https://"))
            val get=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/api/v1/mix-plans/$id/export",get.url.encodedPath);assertEquals("GET",get.method)
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun originalDuplicateKeysWhitespaceAndUnicodeReachServerUnchanged() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val route=MixExchangeOwner(api,session.capture()!!).bind(null)
            val raw=" \n{\"name\":\"été 🎵\",\"name\":\"duplicate\"}\t"
            assertTrue(route.edit(raw));f.reply("{}",400);assertNull(route.importMix())
            assertEquals(raw,f.server.takeRequest(2,TimeUnit.SECONDS)!!.body!!.utf8())
            assertEquals(ExchangePhase.Refused,route.snapshot().phase);assertEquals(raw,route.snapshot().input)
        }
    }
    @Test fun invalidUnicodeBlankAndUtf8ByteLimitRefuseBeforeDispatch() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val route=MixExchangeOwner(api,session.capture()!!).bind(null)
            for(raw in listOf(" \n","é".repeat(131073),"\uD800")) {
                route.edit(raw);assertNull(route.importMix());assertEquals(ExchangePhase.Refused,route.snapshot().phase);assertEquals(raw,route.snapshot().input)
            }
            assertEquals(0,f.server.requestCount)
            val exact="x".repeat(262144);route.edit(exact);f.reply("{}",400);route.importMix()
            assertEquals(exact,f.server.takeRequest(2,TimeUnit.SECONDS)!!.body!!.utf8());assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun noMutationReplayOn401ServerFailureMalformedAckOrDisconnect() {
        for(code in listOf(401,503,201,302,0)) HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val route=owner.bind(null);route.edit(input)
            if(code==0)f.server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            else f.reply(if(code==201)"{bad" else "{}",code)
            assertNull(route.importMix());assertNull(route.importMix());assertEquals(1,f.server.requestCount)
            assertEquals(ExchangePhase.UnknownCreate,route.snapshot().phase);assertEquals(input,route.snapshot().input)
            val rebound=owner.bind(null);assertNull(rebound.importMix());assertEquals(1,f.server.requestCount)
            assertFalse(route.startAnotherImport(true));assertFalse(rebound.startAnotherImport(false))
            assertTrue(rebound.startAnotherImport(true));assertTrue(rebound.snapshot().priorUnconfirmed)
            f.reply("{}",400);assertNull(rebound.importMix());assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun knownIdentityReadbackRecoveryUsesGetOnlyAndAcceptsOnce() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val route=owner.bind(null);route.edit(input)
            f.reply(ack,201);f.reply("{}",503);assertNull(route.importMix())
            assertEquals(ExchangePhase.ReadbackFailed,route.snapshot().phase);assertEquals(id,route.snapshot().knownId)
            assertNull(route.importMix());val rebound=owner.bind(null);assertNull(route.recoverSaved())
            f.reply(ack);assertEquals(id,rebound.recoverSaved()!!.id);assertNull(rebound.recoverSaved())
            assertEquals(listOf("POST","GET","GET"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun rawReadbackChangesNeverBecomeAcceptedOrReplayable() {
        for(kind in listOf("gain","ramp","fractional","unknown","order","metadata","stem-source")) HttpsFixture().use {f ->
            val (session,api)=setup(f);val route=MixExchangeOwner(api,session.capture()!!).bind(null);route.edit(input)
            val original=Json.parseToJsonElement(ack).jsonObject
            val changed=when(kind) {
                "gain"->ack.replace("-3.5","-4")
                "ramp"->ack.replace("\"rampMs\":250","\"rampMs\":251")
                "fractional"->ack.replace("\"sourceStartMs\":2000","\"sourceStartMs\":2000.1")
                "unknown"->ack.replace("\"gainDb\":-3.5","\"futureAutomation\":{},\"gainDb\":-3.5")
                "metadata"->ack.replace("Evening source performance","Changed")
                "stem-source"->ack.replace("sha256:"+"a".repeat(64),"sha256:"+"b".repeat(64))
                else->JsonObject(original+("clips" to JsonArray(original.getValue("clips").jsonArray.reversed()))).toString()
            }
            f.reply(ack,201);f.reply(changed);assertNull(route.importMix())
            assertEquals(ExchangePhase.ReadbackFailed,route.snapshot().phase);assertNull(route.importMix());assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun objectKeyOrderIsIrrelevantButStrictSavedParserStillRuns() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val route=owner.bind(null);route.edit(input)
            f.reply(ack,201);f.reply(JsonObject(Json.parseToJsonElement(ack).jsonObject.entries.reversed().associate {it.toPair()}).toString())
            assertNotNull(route.importMix())
            val invalid=ack.replace("-3.5","\"-3.5\"");val next=owner.bind(null);next.edit(input)
            f.reply(invalid,201);f.reply(invalid);assertNull(next.importMix());assertEquals(ExchangePhase.ReadbackFailed,next.snapshot().phase)
        }
    }
    @Test fun safeSourceRefusalsRetainInputAndPermitOnlyFreshExplicitIntent() {
        for(code in ExchangeRefusal.Code.entries) HttpsFixture().use {f ->
            val (session,api)=setup(f);val route=MixExchangeOwner(api,session.capture()!!).bind(null);route.edit(input)
            f.reply("""{"code":"${code.name}","message":"secret https://private.invalid","missingSourceHashes":["secret-hash"]}""",422)
            assertNull(route.importMix());assertEquals(code,route.snapshot().refusal);assertEquals(input,route.snapshot().input)
            assertFalse(route.snapshot().toString().contains("secret"));f.reply("{}",400);route.importMix();assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun heldPostSelectionAccountAndRouteAbaRetirePublicationAndGetContinuation() {
        for(transition in listOf("selection","account","route")) HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val route=owner.bind(null);route.edit(input)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(201).body(ack).build()}}
            try {
                val pending=pool.submit<SavedMix?> {route.importMix()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                assertTrue(route.snapshot().blocksOtherWrites);assertNull(route.importMix())
                when(transition) {
                    "account"->{session.accept(session.beginIntent(),SecretTokens("b","rb","B"));session.accept(session.beginIntent(),SecretTokens("a2","ra2","A"))}
                    "selection"->{owner.bind(MixJson.saved(Json.parseToJsonElement(ack).jsonObject));owner.bind(null)}
                    else->{route.close();owner.bind(null)}
                }
                release.countDown();assertNull(pending.get(4,TimeUnit.SECONDS));assertEquals(1,f.server.requestCount)
                val s=owner.snapshot();assertFalse(s.pending);assertNull(s.exportText)
                if(transition!="account"){assertEquals(ExchangePhase.UnknownCreate,s.phase);assertEquals(input,s.input)}else assertEquals("",s.input)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun oldBindingCannotExposeReplacementInputOrAcceptedExport() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val old=owner.bind(null);old.edit(input)
            old.close();val replacement=owner.bind(null);replacement.edit("replacement private metadata")
            assertEquals(ExchangePhase.Retired,old.snapshot().phase)
            assertEquals("",old.snapshot().input);assertNull(old.snapshot().exportText)
            assertEquals("replacement private metadata",replacement.snapshot().input)
            assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun malformedIdentityNeverBuildsAPathOrAllowsAnotherPost() {
        for(identity in listOf("{}","{\"id\":\"../queue\"}","{\"id\":7}")) HttpsFixture().use {f ->
            val (session,api)=setup(f);val route=MixExchangeOwner(api,session.capture()!!).bind(null);route.edit(input)
            f.reply(identity,201);assertNull(route.importMix());assertNull(route.importMix())
            assertEquals(ExchangePhase.UnknownCreate,route.snapshot().phase);assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun invalidExportIsNeverCopiedAndOrdinaryErrorBodiesRemainHidden() {
        for(invalid in listOf(fixture("export.json").replace("\"sourceFileHash\"","\"trackId\""),fixture("export.json").replace("\"format\":","\"url\":\"https://private.invalid\",\"format\":"))) HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!)
            val route=owner.bind(MixJson.saved(Json.parseToJsonElement(ack).jsonObject));f.reply(invalid)
            assertFalse(route.loadExport());var copied=false;assertFalse(route.copyExport {copied=true});assertFalse(copied)
            f.reply("""{"code":"MISSING_SOURCES","message":"private-secret"}""",422)
            val error=runCatching {api.mixPlan(session.capture()!!,id){true}}.exceptionOrNull()!!
            assertTrue(error is SafeFailure);assertFalse(error.toString().contains("MISSING_SOURCES"));assertFalse(error.toString().contains("private-secret"))
        }
    }
    @Test fun readOnlyExportMayRefreshThroughCanonicalSessionWithoutReplayingMutation() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val route=MixExchangeOwner(api,session.capture()!!).bind(MixJson.saved(Json.parseToJsonElement(ack).jsonObject))
            f.reply("{}",401);f.reply(f.auth("A","a2"));f.reply(fixture("export.json"))
            assertTrue(route.loadExport());assertEquals(listOf("GET","POST","GET"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }
    @Test fun retiredBindingsCannotDispatchAndExplicitOwnerRetirementCannotRevive() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val old=owner.bind(null);old.edit(input)
            old.close();assertNull(old.importMix());assertFalse(old.edit("changed"));assertFalse(old.loadExport())
            val fresh=owner.bind(null);assertEquals(input,fresh.snapshot().input);owner.retire()
            assertNull(fresh.importMix());assertFalse(owner.bind(null).edit(input));assertEquals("",owner.snapshot().input)
            assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun heldExportNeverRetargetsOrCopiesAfterSelectionVersionAba() {
        HttpsFixture().use {f ->
            val (session,api)=setup(f);val owner=MixExchangeOwner(api,session.capture()!!);val saved=MixJson.saved(Json.parseToJsonElement(ack).jsonObject)
            val old=owner.bind(saved);val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(fixture("export.json")).build()}}
            try {
                val pending=pool.submit<Boolean>{old.loadExport()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                owner.bind(saved.copy(version=2));val fresh=owner.bind(saved);release.countDown();assertFalse(pending.get(4,TimeUnit.SECONDS))
                var copied=false;assertFalse(old.copyExport {copied=true});assertFalse(fresh.copyExport {copied=true});assertFalse(copied)
                assertFalse(owner.snapshot().pending);assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
}
