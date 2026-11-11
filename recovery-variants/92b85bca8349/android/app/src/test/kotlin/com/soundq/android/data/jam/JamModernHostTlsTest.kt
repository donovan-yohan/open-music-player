package com.soundq.android.data.jam

import com.soundq.android.data.*
import com.soundq.android.data.connect.*
import com.soundq.android.playback.PlaybackProjection
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.UUID
import java.util.concurrent.*

/** Real scoped TLS/port/journal orchestration. Authority, acquisition and the
 * insertion closure are SYNTHETIC. This is not Android canonical queue proof. */
class JamModernHostTlsTest {
    private class Fixture:AutoCloseable {
        val template=Json.parseToJsonElement(checkNotNull(javaClass.getResource("/jam-producer/host-pending.json")).readText()).jsonObject
        val original=template.getValue("hostRequests").jsonArray.single().jsonObject
        val readyTemplate=Json.parseToJsonElement(checkNotNull(javaClass.getResource("/jam-producer/host-ready.json")).readText()).jsonObject.getValue("hostRequests").jsonArray.single {it.jsonObject["requestId"]==original["requestId"]}.jsonObject
        val tls=HttpsFixture()
        var now=Instant.parse(template.getValue("serverTime").jsonPrimitive.content)
        val memberExpiry=now.plusSeconds(60)
        val session=AccountSession(tls.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh",template.getValue("ownerUserId").jsonPrimitive.content))}
        val api=SoundQApi(session,tls.client)
        val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
        val playback=MutableStateFlow(PlaybackProjection())
        val presence=DevicePresence(api,playback,jobs){now}
        val port=JamAdmissionPort(session).also {it.attachOwner(UUID.randomUUID().toString());it.bindAccount(session.capture())}
        val directory=Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"modern-jam-").toFile()
        val inserts=CopyOnWriteArrayList<Track>()
        data class Canonical(val track:Track,val provenance:JamOccurrence,val occurrence:String)
        val canonical=ConcurrentHashMap<String,Canonical>()
        val calls=CopyOnWriteArrayList<RecordedRequest>()
        val approvalBodies=CopyOnWriteArrayList<String>()
        var device="";val lease=UUID.randomUUID().toString();var jam="";var version=1L
        var status="pending";var visibleRequest=false;var approvedSession:String?=null;var receipt:JsonObject?=null
        var jobPublications=0;var loseApproval=false;var failInsertion=false;var failBeforeInsertion=false;var loseDecision=false
        var holdPath:String?=null;val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val host=JamHostRepository(api,presence,playback,port,{ticket ->port.consumeWithProvenance(ticket){track,provenance,lookupOnly ->
            val identity=checkNotNull(provenance)
            canonical[identity.admissionKey]?.let {known ->
                check(known.track.id==track.id&&known.provenance==identity)
                return@consumeWithProvenance known.occurrence
            }
            check(!lookupOnly)
            val journal=journal();val attempt=journal.getValue("attempts").jsonArray.single().jsonObject
            assertEquals(JsonNull,attempt["receipt"]);assertEquals(requestId,attempt.getValue("requestId").jsonPrimitive.content)
            if(failBeforeInsertion)throw IllegalStateException("synthetic unknown before insertion")
            inserts.add(track);port.replaceOwner()
            val occurrence="synthetic-occurrence-${inserts.size}";canonical[identity.admissionKey]=Canonical(track,identity,occurrence)
            if(failInsertion)throw IllegalStateException("synthetic unknown after insertion")
            occurrence
        }},jobs,directory){now}
        val requestId get()=original.getValue("requestId").jsonPrimitive.content
        val resolved get()=readyTemplate.getValue("trackId").jsonPrimitive.long
        fun journal()=Json.parseToJsonElement(directory.listFiles()!!.single {it.name.startsWith("jam-admission-")}.readText()).jsonObject
        init {tls.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
            calls.add(r);val path=r.url.encodedPath
            if(path==holdPath){entered.countDown();check(release.await(4,TimeUnit.SECONDS))}
            fun reply(body:JsonObject=buildJsonObject{},code:Int=200)=MockResponse.Builder().code(code).apply {if(code!=204)body(body.toString())}.build()
            val body=r.body?.utf8()?.takeIf {it.isNotEmpty()}?.let {Json.parseToJsonElement(it).jsonObject}
            if(path=="/api/v1/me/devices"&&r.method=="POST") {
                device=body!!.getValue("deviceId").jsonPrimitive.content;return reply(buildJsonObject {put("device",device(0))},201)
            }
            if(path=="/api/v1/me/devices/$device"&&r.method=="PUT")return reply(buildJsonObject {put("device",device(body!!.getValue("sequence").jsonPrimitive.long))})
            if(path=="/api/v1/library")return reply(buildJsonObject {
                put("tracks",buildJsonArray {add(buildJsonObject {put("id",1);put("title","Owned offer");put("artist","Private");put("is_liked",false)})
                    if(status in setOf("ready","queued","uncertain"))add(buildJsonObject {put("id",resolved);put("title","Resolved owned source");put("artist","Private");put("is_liked",false)})})
                put("total",if(status in setOf("ready","queued","uncertain"))2 else 1);put("limit",20);put("offset",0)
            })
            if(path=="/api/v1/jams"&&r.method=="POST") {
                jam=body!!.getValue("jamId").jsonPrimitive.content;assertEquals(JsonPrimitive(true),body["allowOutsideDiscovery"]);return reply(snapshot(false),201)
            }
            if(path.endsWith("/approval")&&r.method=="POST") {
                val consent=journal().getValue("approvals").jsonArray.single().jsonObject
                assertEquals(body!!["expectedVersion"],consent["expectedVersion"]);assertEquals(body["hostSessionId"],consent["hostSession"])
                assertTrue(journal().getValue("attempts").jsonArray.isEmpty())
                val serialized=body.toString();approvalBodies.add(serialized)
                if(approvedSession==null){assertEquals(version,body.getValue("expectedVersion").jsonPrimitive.long);approvedSession=body.getValue("hostSessionId").jsonPrimitive.content;status="importing";version++;jobPublications++}
                else assertEquals(approvalBodies.first(),serialized)
                if(loseApproval){loseApproval=false;return reply(code=503)}
                return reply(snapshot(true))
            }
            if(path.endsWith("/requests/$requestId")&&r.method=="PUT") {
                if(loseDecision){loseDecision=false;return reply(code=503)}
                status=body!!.getValue("status").jsonPrimitive.content;receipt=body["receipt"]?.jsonObject
                if(status=="queued")assertEquals(receipt,journal().getValue("attempts").jsonArray.single().jsonObject.getValue("receipt").jsonObject.let {JsonObject(it-"ownerAfter")})
                version++;return reply(publicRequest())
            }
            if(path.endsWith("/host"))return reply(snapshot(false))
            if(path=="/api/v1/jams/$jam"&&r.method=="GET")return reply(snapshot(true))
            return reply(code=404)
        }}}
        fun device(sequence:Long)=buildJsonObject {
            put("deviceId",device);put("leaseId",lease);put("label","Synthetic Android");put("platform","android");put("sequence",sequence)
            put("lastSeenAt",now.toString());put("leaseExpiresAt",now.plusSeconds(90).toString());put("playback",JsonNull)
        }
        fun publicRequest()=JsonObject(original.filterKeys {it in setOf("requestId","catalogItemId","displayName","source")}+mapOf("status" to JsonPrimitive(status)))
        fun snapshot(private:Boolean):JsonObject {
            val public=publicRequest()
            val q=JsonObject(original+public+buildJsonObject {
                put("trackId",if(status in setOf("ready","queued","uncertain"))resolved else 0)
                put("approvalOrder",if(approvedSession==null)0 else 1);put("canAdmit",status=="ready")
                if(approvedSession!=null){put("hostSessionId",approvedSession);put("admissionKey",readyTemplate.getValue("admissionKey"));put("downloadJobId",readyTemplate.getValue("downloadJobId"))}
                receipt?.let {put("receipt",it)}
            })
            return JsonObject(template.filterKeys {private||it !in setOf("ownerUserId","ownerAuthGeneration","hostDeviceId","leaseId","members","hostRequests","memberCount")}+buildJsonObject {
                put("jamId",jam);put("version",version);put("state","open");put("serverTime",now.toString());put("hostSeenAt",now.toString());put("expiresAt",now.plusSeconds(3600).toString());put("allowOutsideDiscovery",true)
                put("requests",JsonArray(if(visibleRequest)listOf(public)else emptyList()))
                if(private) {
                    put("hostDeviceId",device);put("leaseId",lease)
                    put("members",JsonArray(template.getValue("members").jsonArray.map {JsonObject(it.jsonObject+mapOf("expiresAt" to JsonPrimitive(memberExpiry.toString())))}))
                    put("hostRequests",JsonArray(if(visibleRequest)listOf(q)else emptyList()))
                }
            })
        }
        fun create():JamConsent {presence.step();val c=host.open();host.create(c,listOf(Track(TrackId(1),"UI offer")),true);visibleRequest=true;version++;host.refresh(c);assertNotNull(host.state.value.snapshot!!.authority);return c}
        fun request()=host.state.value.snapshot!!.requests.single()
        fun ready(){status="ready";version++}
        override fun close(){release.countDown();host.close();presence.close();jobs.cancel();tls.close();directory.deleteRecursively()}
    }
    @Test fun explicitApprovalPersistsBeforeWriteAndReadyContinuesHiddenThroughActualTicketOnly()=Fixture().use {f ->
        val c=f.create();val hostSession=f.port.hostSession(f.session.capture()!!)!!
        f.host.decide(c,f.request(),true);assertEquals(1,f.jobPublications);assertTrue(f.inserts.isEmpty());assertEquals("importing",f.request().status)
        f.host.hide(c);f.ready();f.now=f.now.plusSeconds(5);f.host.tick()
        assertEquals(1,f.inserts.size);assertEquals(TrackId(f.resolved),f.inserts.single().id);assertEquals("queued",f.request().status)
        assertEquals(hostSession,f.request().receipt!!.sessionId);assertNotNull(f.host.state.value.snapshot!!.authority)
        f.host.tick();assertEquals(1,f.inserts.size);assertEquals(1,f.jobPublications)
    }
    @Test fun lostApprovalAckNeverAutoConfirmsAndExplicitCheckReusesExactPayload()=Fixture().use {f ->
        val c=f.create();f.loseApproval=true;f.host.decide(c,f.request(),true)
        assertEquals(1,f.jobPublications);assertTrue(f.inserts.isEmpty());assertFalse(f.journal().getValue("approvals").jsonArray.single().jsonObject.getValue("confirmed").jsonPrimitive.boolean)
        f.ready();f.host.tick();assertTrue(f.inserts.isEmpty())
        f.host.decide(c,f.request(),true,true)
        assertEquals(2,f.approvalBodies.size);assertEquals(f.approvalBodies[0],f.approvalBodies[1]);assertEquals(1,f.jobPublications)
        assertEquals(1,f.inserts.size);assertEquals("queued",f.request().status)
    }
    @Test fun lostReceiptAckReconcilesWithoutAnotherNativeInsertion()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.loseDecision=true;f.host.tick()
        assertEquals(1,f.inserts.size);assertEquals("ready",f.status)
        f.host.tick();assertEquals(1,f.inserts.size);assertEquals("queued",f.request().status)
    }
    @Test fun unknownNativeOutcomeCannotBlindlyInsertAgain()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.failInsertion=true;f.host.tick()
        assertEquals(1,f.inserts.size);f.failInsertion=false;f.host.tick();f.host.decide(c,f.request(),true,true)
        assertEquals(1,f.inserts.size);assertEquals("queued",f.request().status)
        assertEquals(f.canonical.values.single().occurrence,f.request().receipt!!.occurrenceId)
    }
    @Test fun absentCanonicalEvidenceAfterUnknownAttemptNeverReplaysInsertion()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.failBeforeInsertion=true;f.host.tick()
        assertTrue(f.inserts.isEmpty());f.failBeforeInsertion=false;f.host.tick();f.host.decide(c,f.request(),true,true)
        assertTrue(f.inserts.isEmpty());assertTrue(f.canonical.isEmpty());assertNotEquals("queued",f.request().status)
    }
    @Test fun accountLockOrUnrelatedQueueReplacementCannotReviveConfirmedContinuation() {
        for(lock in listOf(false,true))Fixture().use {f ->
            val c=f.create();f.host.decide(c,f.request(),true);f.ready()
            if(lock)f.session.lockLocal()else {f.port.replaceOwner();f.port.replaceOwner()}
            f.host.tick();assertTrue(f.inserts.isEmpty())
        }
    }
    @Test fun heldApprovalReadRetiresWithPanelBeforeAnyApprovalPost()=Fixture().use {f ->
        val c=f.create();f.holdPath="/api/v1/jams/${f.jam}";val pool=Executors.newSingleThreadExecutor()
        try {val work=pool.submit {f.host.decide(c,f.request(),true)};assertTrue(f.entered.await(2,TimeUnit.SECONDS));f.host.hide(c);f.release.countDown();work.get(4,TimeUnit.SECONDS)
            assertTrue(f.approvalBodies.isEmpty());assertTrue(f.inserts.isEmpty())
        }finally {f.release.countDown();pool.shutdownNow()}
    }
}
