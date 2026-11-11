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
        val queueFile=File(directory,"canonical-queue.json")
        val calls=CopyOnWriteArrayList<RecordedRequest>()
        val approvalBodies=CopyOnWriteArrayList<String>()
        var device="";var jamDevice="";val lease=UUID.randomUUID().toString();var jam="";var version=1L
        var earlier=false
        var jamState="open"
        var status="pending";var visibleRequest=false;var approvedSession:String?=null;var receipt:JsonObject?=null
        var jobPublications=0;var loseApproval=false;var failInsertion=false;var failBeforeInsertion=false;var loseDecision=false
        var holdPath:String?=null;val entered=CountDownLatch(1);val release=CountDownLatch(1)
        var host=newHost()
        fun newHost()=JamHostRepository(api,presence,playback,port,{ticket ->port.consumeWithProvenance(ticket){track,provenance,lookupOnly ->
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
            saveCanonical()
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
                jam=body!!.getValue("jamId").jsonPrimitive.content;jamDevice=device;assertEquals(JsonPrimitive(true),body["allowOutsideDiscovery"]);return reply(snapshot(false),201)
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
                put("approvalOrder",if(approvedSession==null)0 else if(earlier)2 else 1);put("canAdmit",status=="ready"&&!earlier)
                if(approvedSession!=null){put("hostSessionId",approvedSession);put("admissionKey",readyTemplate.getValue("admissionKey"));put("downloadJobId",readyTemplate.getValue("downloadJobId"))}
                receipt?.let {put("receipt",it)}
            })
            val predecessor=JsonObject(q+buildJsonObject {put("requestId","123e4567-e89b-42d3-a456-426614174000");put("approvalOrder",1);put("status","importing");put("canAdmit",false);put("admissionKey","a".repeat(64))})
            val publicPredecessor=JsonObject(predecessor.filterKeys {it in setOf("requestId","catalogItemId","displayName","source","status")})
            return JsonObject(template.filterKeys {private||it !in setOf("ownerUserId","ownerAuthGeneration","hostDeviceId","leaseId","members","hostRequests","memberCount")}+buildJsonObject {
                put("jamId",jam);put("version",version);put("state",jamState);put("serverTime",now.toString());put("hostSeenAt",now.toString());put("expiresAt",now.plusSeconds(3600).toString());put("allowOutsideDiscovery",true)
                put("requests",JsonArray(if(visibleRequest)listOf(public)+(if(earlier)listOf(publicPredecessor)else emptyList()) else emptyList()))
                if(private) {
                    put("hostDeviceId",jamDevice);put("leaseId",lease)
                    put("members",JsonArray(template.getValue("members").jsonArray.map {JsonObject(it.jsonObject+mapOf("expiresAt" to JsonPrimitive(memberExpiry.toString())))}))
                    put("hostRequests",JsonArray(if(visibleRequest)listOf(q)+(if(earlier)listOf(predecessor)else emptyList()) else emptyList()))
                }
            })
        }
        fun create():JamConsent {presence.step();val c=host.open();host.create(c,listOf(Track(TrackId(1),"UI offer")),true);visibleRequest=true;version++;host.refresh(c);assertNotNull(host.state.value.snapshot!!.authority);return c}
        fun request()=host.state.value.snapshot!!.requests.single {it.id==requestId}
        fun ready(){status="ready";version++}
        fun saveCanonical() {
            val rows=canonical.values.map {com.soundq.android.playback.SavedOccurrence(it.occurrence,it.track.id.value,it.track.title,"",true,jam=it.provenance)}
            val saved=com.soundq.android.playback.QueueSnapshot(session.endpoint.identity,session.capture()!!.accountId,rows,0,0)
            java.io.FileOutputStream(queueFile).use {it.write(saved.encode().toByteArray());it.fd.sync()}
        }
        fun reconstruct(replaceService:Boolean=true):JamConsent {
            host.close();canonical.clear()
            if(replaceService){port.attachOwner(UUID.randomUUID().toString());port.bindAccount(session.capture())}
            if(queueFile.exists())com.soundq.android.playback.QueueSnapshotStore(queueFile).read(session.endpoint.identity,session.capture()!!.accountId)?.items?.forEach {row ->
                row.jam?.let {canonical[it.admissionKey]=Canonical(Track(TrackId(row.track),row.title),it,row.occurrence)}
            }
            host=newHost();val c=host.open();host.refresh(c);return c
        }
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
    @Test fun reconstructedRepositoryCheckRecoversPersistedExactOccurrenceWithoutApprovalReplay()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.failInsertion=true;f.host.tick()
        assertEquals(1,f.inserts.size)
        val existing=f.canonical.values.single()
        val queue=File(f.directory,"canonical-queue.json")
        val snapshot=com.soundq.android.playback.QueueSnapshot(f.session.endpoint.identity,f.session.capture()!!.accountId,listOf(com.soundq.android.playback.SavedOccurrence(existing.occurrence,existing.track.id.value,existing.track.title,"",true,jam=existing.provenance)),0,0)
        java.io.FileOutputStream(queue).use {it.write(snapshot.encode().toByteArray());it.fd.sync()}
        f.host.close();f.canonical.clear();f.port.attachOwner(UUID.randomUUID().toString());f.port.bindAccount(f.session.capture())
        val restored=com.soundq.android.playback.QueueSnapshot.decode(queue.readText(),f.session.endpoint.identity,f.session.capture()!!.accountId)!!.items.single()
        f.canonical[restored.jam!!.admissionKey]=Fixture.Canonical(existing.track,restored.jam,restored.occurrence)
        f.host=f.newHost();val renewed=f.host.open();f.host.refresh(renewed)
        assertNotNull("Check same Jam must recover the exact durable target",f.host.state.value.snapshot)
        val posts=f.approvalBodies.size
        f.host.decide(renewed,f.request(),true,true)
        assertEquals("queued",f.request().status);assertEquals(existing.occurrence,f.request().receipt!!.occurrenceId)
        assertEquals(existing.provenance.sessionId,f.request().receipt!!.sessionId)
        assertNotEquals(existing.provenance.sessionId,f.port.hostSession(f.session.capture()!!))
        assertEquals(posts,f.approvalBodies.size);assertEquals(1,f.inserts.size)
    }
    @Test fun receiptJournalBeforeLostServerAckMustBeReobservedByReplacementOwner()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.loseDecision=true;f.host.tick()
        val receipt=f.journal().getValue("attempts").jsonArray.single().jsonObject.getValue("receipt").jsonObject
        val renewed=f.reconstruct();f.host.decide(renewed,f.request(),true,true)
        assertEquals("queued",f.request().status)
        assertEquals(receipt["occurrenceId"],f.request().receipt!!.json()["occurrenceId"])
        assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size)
    }
    @Test fun restartWithoutExactOccurrenceNeverUsesStoredReceiptOrMatchingTrackAsPermission() {
        for(retainReceipt in listOf(false,true))Fixture().use {f ->
            val c=f.create();f.host.decide(c,f.request(),true);f.ready()
            if(retainReceipt)f.loseDecision=true else f.failInsertion=true
            f.host.tick();val known=f.canonical.values.single()
            // Same track and occurrence alias, but exact provenance is absent after restoration.
            val saved=com.soundq.android.playback.QueueSnapshot(f.session.endpoint.identity,f.session.capture()!!.accountId,listOf(com.soundq.android.playback.SavedOccurrence(known.occurrence,known.track.id.value,known.track.title,"",true)),0,0)
            f.queueFile.writeText(saved.encode());val renewed=f.reconstruct()
            val puts=f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")}
            f.host.decide(renewed,f.request(),true,true);f.host.tick()
            assertNotEquals("queued",f.request().status);assertEquals("Queue entry not confirmed.",f.host.state.value.message)
            assertEquals(puts,f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")})
            assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size)
        }
    }
    @Test fun reconstructedConsentWithoutAttemptNeverAdmitsOrRepublishesApproval()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();val renewed=f.reconstruct()
        val calls=f.calls.size;f.host.tick();assertEquals(calls,f.calls.size)
        f.host.decide(renewed,f.request(),true,true);f.host.decide(renewed,f.request(),true)
        assertTrue(f.inserts.isEmpty());assertEquals(1,f.approvalBodies.size)
    }
    @Test fun explicitRecoveryFencesQueueAbaDuringLibraryRead()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.failInsertion=true;f.host.tick()
        val renewed=f.reconstruct();f.holdPath="/api/v1/library";val pool=Executors.newSingleThreadExecutor()
        try {val task=pool.submit {f.host.decide(renewed,f.request(),true,true)};assertTrue(f.entered.await(2,TimeUnit.SECONDS))
            f.port.replaceOwner();f.port.replaceOwner();f.release.countDown();task.get(4,TimeUnit.SECONDS)
            assertNotEquals("queued",f.request().status);assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size)
        }finally {f.release.countDown();pool.shutdownNow()}
    }
    @Test fun earlierApprovalStillHoldsReceiptRecoveryAndNeverRenewsSiblingConsent()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.failInsertion=true;f.host.tick()
        f.earlier=true;val renewed=f.reconstruct()
        val before=f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")}
        f.host.decide(renewed,f.request(),true,true)
        assertNotEquals("queued",f.request().status)
        assertEquals(before,f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")})
        assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size)
    }
    @Test fun replacementLeaseMayObserveExactEvidenceButCannotSendOldHostReceipt()=Fixture().use {f ->
        val c=f.create();f.host.decide(c,f.request(),true);f.ready();f.failInsertion=true;f.host.tick()
        f.presence.retire();f.presence.step();f.jamState="hostOffline";val renewed=f.reconstruct()
        val before=f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")}
        f.host.decide(renewed,f.request(),true,true)
        assertEquals("Saved on this device. Server confirmation unavailable.",f.host.state.value.message)
        assertNotEquals("queued",f.request().status)
        assertEquals(before,f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")})
        assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size)
    }
    @Test fun pagedRestartChecksExactJamBeyondFirstMetadataPageWithoutAnotherInsertOrApproval() {
        for(retainReceipt in listOf(false,true))Fixture().use {f ->
            val c=f.create();f.host.decide(c,f.request(),true);f.ready()
            if(retainReceipt)f.loseDecision=true else f.failInsertion=true
            f.host.tick();val known=f.canonical.values.single();val playback=f.playback.value
            val ordinary=List(600){com.soundq.android.playback.SavedOccurrence("ordinary-$it",known.track.id.value,"Ordinary $it","",false,durationMs=12000)}
            val exact=com.soundq.android.playback.SavedOccurrence(known.occurrence,known.track.id.value,known.track.title,"",true,durationMs=12000,jam=known.provenance)
            val saved=com.soundq.android.playback.QueueSnapshot(f.session.endpoint.identity,f.session.capture()!!.accountId,ordinary+exact,600,1300)
            com.soundq.android.playback.QueueSnapshotStore(f.queueFile).write(saved)
            val bytes=f.queueFile.readBytes();val renewed=f.reconstruct()
            f.host.decide(renewed,f.request(),true,true);f.host.tick();f.host.decide(renewed,f.request(),true,true)
            assertEquals("queued",f.request().status);assertEquals(known.occurrence,f.request().receipt!!.occurrenceId)
            assertEquals(known.provenance.sessionId,f.request().receipt!!.sessionId)
            assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size);assertSame(playback,f.playback.value)
            assertArrayEquals(bytes,f.queueFile.readBytes())
            assertEquals(saved,com.soundq.android.playback.QueueSnapshotStore(f.queueFile).read(saved.endpoint,saved.account))
        }
    }
    @Test fun pagedRestartWithoutExactProvenanceNeverUsesSameTrackOrStoredReceipt() {
        for(retainReceipt in listOf(false,true))Fixture().use {f ->
            val c=f.create();f.host.decide(c,f.request(),true);f.ready()
            if(retainReceipt)f.loseDecision=true else f.failInsertion=true
            f.host.tick();val known=f.canonical.values.single();val playback=f.playback.value
            val rows=List(601){com.soundq.android.playback.SavedOccurrence(if(it==600)known.occurrence else "ordinary-$it",known.track.id.value,"Same track","",true,durationMs=12000)}
            val saved=com.soundq.android.playback.QueueSnapshot(f.session.endpoint.identity,f.session.capture()!!.accountId,rows,600,1300)
            com.soundq.android.playback.QueueSnapshotStore(f.queueFile).write(saved);val renewed=f.reconstruct()
            val puts=f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")}
            f.host.decide(renewed,f.request(),true,true);f.host.tick()
            assertNotEquals("queued",f.request().status);assertEquals("Queue entry not confirmed.",f.host.state.value.message)
            assertEquals(puts,f.calls.count {it.method=="PUT"&&it.url.encodedPath.endsWith("/requests/${f.requestId}")})
            assertEquals(1,f.inserts.size);assertEquals(1,f.approvalBodies.size);assertSame(playback,f.playback.value)
            assertEquals(saved,com.soundq.android.playback.QueueSnapshotStore(f.queueFile).read(saved.endpoint,saved.account))
        }
    }
    @Test fun differentAccountCannotDiscoverPreviousJamTarget()=Fixture().use {f ->
        f.create();f.host.close();f.session.retire()
        f.session.accept(f.session.beginIntent(),SecretTokens("synthetic-new-access","synthetic-new-refresh",UUID.randomUUID().toString()))
        f.presence.retire();f.presence.step();f.port.bindAccount(f.session.capture());f.host=f.newHost()
        val calls=f.calls.size;val c=f.host.open();f.host.refresh(c);f.host.tick()
        assertNull(f.host.state.value.snapshot);assertEquals(calls,f.calls.size)
    }
    @Test fun heldApprovalReadRetiresWithPanelBeforeAnyApprovalPost()=Fixture().use {f ->
        val c=f.create();f.holdPath="/api/v1/jams/${f.jam}";val pool=Executors.newSingleThreadExecutor()
        try {val work=pool.submit {f.host.decide(c,f.request(),true)};assertTrue(f.entered.await(2,TimeUnit.SECONDS));f.host.hide(c);f.release.countDown();work.get(4,TimeUnit.SECONDS)
            assertTrue(f.approvalBodies.isEmpty());assertTrue(f.inserts.isEmpty())
        }finally {f.release.countDown();pool.shutdownNow()}
    }
}
