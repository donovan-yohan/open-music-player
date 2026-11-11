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
import java.time.Instant
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Real trusted TLS exchanges, synthetic credentials only. No real backend/account. */
class ConnectJamTlsTest {
    private class Fixture(private val sendGate:((okhttp3.Request)->Unit)?=null):AutoCloseable {
        val tls=HttpsFixture()
        val session=AccountSession(tls.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-account-access","synthetic-refresh","owner"))}
        val api=SoundQApi(session,tls.client.newBuilder().addInterceptor {chain->sendGate?.invoke(chain.request());chain.proceed(chain.request())}.build())
        var now=Instant.parse("2026-10-29T12:00:00Z")
        val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
        val playback=MutableStateFlow(PlaybackProjection())
        val presence=DevicePresence(api,playback,jobs){now}
        val admission=JamAdmissionPort(session).also {it.replaceOwner()}
        val inserts=mutableListOf<Track>()
        val id="123e4567-e89b-42d3-a456-426614174000"
        val request="123e4567-e89b-42d3-a456-426614174001"
        val catalog="123e4567-e89b-42d3-a456-426614174002"
        val lease="123e4567-e89b-42d3-a456-426614174003"
        var device=""
        var status="pending"
        var version=1
        var receipt:JsonObject?=null
        val decisions=AtomicInteger()
        var failDecision=false
        var failDisconnect=false
        var disabled=false
        var admissionFails=false
        var beforeInsert:(()->Unit)?=null

        var holdPath:String?=null
        val entered=CountDownLatch(1)
        val release=CountDownLatch(1)
        val calls=CopyOnWriteArrayList<RecordedRequest>()
        val receiptDirectory=java.nio.file.Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"connect-jam-receipts-").toFile()
        val host=JamHostRepository(api,presence,playback,admission,{ticket->admission.consume(ticket){track->beforeInsert?.invoke();if(admissionFails)throw IllegalStateException("synthetic unknown");inserts.add(track);admission.replaceOwner();"occurrence-${inserts.size}"}},jobs,receiptDirectory){now}
        init {tls.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
            calls.add(r)
            val path=r.url.encodedPath
            if(path==holdPath&&r.method=="GET"){entered.countDown();release.await(3,TimeUnit.SECONDS)}
            fun reply(s:String,code:Int=200)=MockResponse.Builder().code(code).apply {if(code!=204)body(s)}.build()
            val b=r.body?.utf8()?.takeIf {it.isNotBlank()}?.let {Json.parseToJsonElement(it).jsonObject}
            if(path=="/api/v1/me/devices"&&r.method=="POST") {
                if(disabled)return reply("{}",503)
                device=b!!.getValue("deviceId").jsonPrimitive.content
                return reply("""{"device":${deviceJson(0)}}""",201)
            }
            if(path=="/api/v1/me/devices/$device"&&r.method=="PUT")return reply("""{"device":${deviceJson(b!!.getValue("sequence").jsonPrimitive.long)}}""")
            if(path=="/api/v1/me/devices/$device"&&r.method=="DELETE")return reply("",if(failDisconnect)503 else 204)
            if(path=="/api/v1/me/devices"&&r.method=="GET")return reply("""{"devices":[],"serverTime":"$now"}""")
            if(path=="/api/v1/library")return reply("""{"tracks":[{"id":7,"title":"Owned song","artist":"Fixture","is_liked":false}],"total":1,"limit":20,"offset":0}""")
            if(path=="/api/v1/jams"&&r.method=="POST")return reply(snapshot(false,b!!.getValue("jamId").jsonPrimitive.content),201)
            if(path.endsWith("/invites"))return reply("""{"joinToken":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","inviteExpiresAt":"2030-01-01T00:00:00Z"}""",201)
            if(path.endsWith("/requests/$request")&&r.method=="PUT") {
                decisions.incrementAndGet()
                if(failDecision)return reply("{}",503)
                status=b!!.getValue("status").jsonPrimitive.content;receipt=b["receipt"]?.jsonObject;version++
                return reply("""{"requestId":"$request","catalogItemId":"$catalog","displayName":"Guest","status":"$status"}""")
            }
            if(path.endsWith("/host"))return reply(snapshot(false,path.split('/')[4]))
            if(path.startsWith("/api/v1/jams/")&&r.method=="GET")return reply(snapshot(true,path.split('/')[4]))
            if(path.startsWith("/api/v1/jams/")&&r.method=="DELETE")return reply("",204)
            return reply("{}",404)
        }}}
        fun deviceJson(sequence:Long)="""{"deviceId":"$device","leaseId":"$lease","label":"Android","platform":"android","sequence":$sequence,"lastSeenAt":"$now","leaseExpiresAt":"${now.plusSeconds(90)}","playback":null}"""
        fun snapshot(host:Boolean,jamId:String=hostId())="""{"jamId":"$jamId","version":$version,"state":"open","serverTime":"$now","expiresAt":"2030-01-01T00:00:00Z","hostSeenAt":"$now","nowPlaying":null,"catalog":[{"catalogItemId":"$catalog","title":"Guest display only","artist":"Fixture","durationMs":1000}],"requests":[{"requestId":"$request","catalogItemId":"$catalog","displayName":"Guest","status":"$status"}]${if(host)",\"hostRequests\":[{\"requestId\":\"$request\",\"catalogItemId\":\"$catalog\",\"displayName\":\"Guest\",\"status\":\"$status\",\"trackId\":7${receipt?.let {",\"receipt\":$it"} ?: ""}}],\"memberCount\":1" else ""}}"""
        fun hostId()=host.state.value.snapshot?.id ?: id
        fun create():JamConsent {presence.step();val c=host.open();host.create(c,listOf(Track(TrackId(7),"Stale UI title")));host.refresh(c);assertNotNull(host.state.value.snapshot);return c}
        override fun close(){try {release.countDown();host.close();presence.close();jobs.cancel();tls.close()}finally {receiptDirectory.deleteRecursively()}}
    }
    @Test fun restoredLegacyTargetCannotGrantNewInsertionAuthority()=Fixture().use {f ->
        f.create();f.host.close()
        val restored=JamHostRepository(f.api,f.presence,f.playback,f.admission,{ticket ->f.admission.consume(ticket){track ->f.inserts.add(track);"forbidden"}},f.jobs,f.receiptDirectory){f.now}
        try {val c=restored.open();restored.refresh(c);assertNotNull(restored.state.value.snapshot)
            restored.decide(c,restored.state.value.snapshot!!.requests.single(),true)
            assertTrue(f.inserts.isEmpty());assertEquals(0,f.decisions.get())
        }finally {restored.close()}
    }
    @Test fun leasedWriterUsesExactProofSequencesAndHiddenPanelIsSilent()=Fixture().use {f->
        f.presence.step();val proof=f.presence.capture()!!;assertTrue(proof.current())
        assertEquals(2,f.calls.size)
        val register=Json.parseToJsonElement(f.calls[0].body!!.utf8()).jsonObject
        val report=Json.parseToJsonElement(f.calls[1].body!!.utf8()).jsonObject
        assertEquals(register["writerSecret"],report["writerSecret"]);assertEquals(1L,report["sequence"]!!.jsonPrimitive.long)
        assertFalse(proof.toString().contains(register["writerSecret"]!!.jsonPrimitive.content))
        f.now=f.now.plusSeconds(5);f.presence.step();assertEquals(3,f.calls.size)
        assertEquals(2L,Json.parseToJsonElement(f.calls.last().body!!.utf8()).jsonObject["sequence"]!!.jsonPrimitive.long)
        f.presence.visible(true);f.presence.step();assertEquals("GET",f.calls.last().method)
        f.presence.visible(false);val before=f.calls.count {it.method=="GET"};f.now=f.now.plusSeconds(5);f.presence.step();assertEquals(before,f.calls.count {it.method=="GET"})
        f.presence.disconnect();assertEquals("DELETE",f.calls.last().method);assertFalse(proof.current())
        val disconnected=f.calls.size;f.now=f.now.plusSeconds(10);f.presence.step();assertEquals(disconnected,f.calls.size)
        f.presence.reconnect();f.presence.step();assertEquals(disconnected+2,f.calls.size)
    }
    @Test fun failedRemoteDisconnectCannotRestoreLocalAuthority()=Fixture().use {f->
        val c=f.create();val proof=f.presence.capture()!!;f.failDisconnect=true
        f.presence.disconnect();val before=f.calls.size
        assertEquals("DELETE",f.calls.last().method);assertEquals(PresenceStatus.Detached,f.presence.state.value.status)
        assertFalse(proof.current());assertNull(f.presence.capture())
        f.now=f.now.plusSeconds(5);f.presence.step();f.host.tick();f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true)
        assertEquals(before,f.calls.size);assertTrue(f.inserts.isEmpty());assertEquals(0,f.decisions.get())
    }
    @Test fun expiredProofDisconnectStillRetiresPresentationAndLatches()=Fixture().use {f->
        f.create();val proof=f.presence.capture()!!;f.now=f.now.plusSeconds(91);val before=f.calls.size
        assertFalse(proof.current());f.presence.disconnect()
        assertEquals(PresenceStatus.Detached,f.presence.state.value.status);assertNull(f.presence.capture())
        f.presence.step();f.host.tick();assertEquals(before,f.calls.size)
        f.presence.reconnect();f.presence.step();assertEquals(before+2,f.calls.size);assertFalse(proof.current())
    }
    @Test fun disconnectBeforeFirstRegistrationLatchesUntilExplicitReconnect()=Fixture().use {f->
        f.presence.disconnect();f.presence.step();assertTrue(f.calls.isEmpty())
        f.presence.reconnect();f.presence.step();assertEquals(2,f.calls.size);assertNotNull(f.presence.capture())
    }
    @Test fun repeatedDisconnectAfterGenerationDrainKeepsDisconnectedAccountLatched()=Fixture().use {f->
        f.presence.step();val proof=f.presence.capture()!!;f.presence.disconnect()
        val before=f.calls.size;f.presence.step();f.presence.disconnect();f.presence.step()
        assertEquals(before,f.calls.size);assertNull(f.presence.capture());assertFalse(proof.current())
        f.presence.reconnect();f.presence.step();assertEquals(before+2,f.calls.size)
    }
    @Test fun disconnectDuringLocalOnlyImmediatelyRetiresPresentationAndProof()=Fixture().use {f->
        f.create();val proof=f.presence.capture()!!;val before=f.calls.size
        f.playback.value=PlaybackProjection(localOnly=true)
        f.presence.disconnect()
        assertEquals(before,f.calls.size)
        assertEquals(PresenceStatus.Detached,f.presence.state.value.status)
        assertNull(f.presence.capture())
        f.playback.value=PlaybackProjection()
        assertFalse(proof.current())
    }
    @Test fun disconnectDuringLocalOnlyCannotReviveHostOrAdmissionAndReconnectIsExplicit()=Fixture().use {f->
        val c=f.create();val proof=f.presence.capture()!!;val request=f.host.state.value.snapshot!!.requests.single()
        f.playback.value=PlaybackProjection(localOnly=true);f.presence.disconnect()
        f.playback.value=PlaybackProjection();val before=f.calls.size
        f.now=f.now.plusSeconds(5);f.presence.step();f.host.tick();f.host.decide(c,request,true);f.host.invite(c)
        assertEquals(before,f.calls.size)
        assertFalse(proof.current());assertNull(f.presence.capture());assertTrue(f.inserts.isEmpty());assertEquals(0,f.decisions.get())
        f.presence.reconnect();f.presence.step()
        assertEquals(before+2,f.calls.size);assertNotNull(f.presence.capture());assertFalse(proof.current())
        val reconnected=f.calls.size;f.host.tick();f.host.decide(c,request,true)
        assertEquals(reconnected,f.calls.size);assertTrue(f.inserts.isEmpty())
        f.host.end(c);assertNull(f.host.state.value.snapshot)
        val next=f.host.open();f.host.create(next,listOf(Track(TrackId(7),"Owned song")));f.host.refresh(next)
        f.host.decide(next,f.host.state.value.snapshot!!.requests.single(),true)
        assertEquals(1,f.inserts.size);assertEquals(1,f.decisions.get())
    }
    private fun heldDisconnect(transition:String) {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        Fixture {request->if(request.method=="DELETE"&&request.url.encodedPath.startsWith("/api/v1/me/devices/")){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}.use {f->
            f.create();val proof=f.presence.capture()!!;val before=f.calls.size
            val original=f.calls[1].body!!.utf8().let {Json.parseToJsonElement(it).jsonObject}
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {f.presence.disconnect()}
                assertTrue(entered.await(2,TimeUnit.SECONDS))
                assertFalse(proof.current());assertNull(f.presence.capture());assertEquals(PresenceStatus.Detached,f.presence.state.value.status)
                when(transition) {
                    "local"->f.playback.value=PlaybackProjection(localOnly=true)
                    "account"->f.session.accept(f.session.beginIntent(),SecretTokens("replacement","replacement-r","owner"))
                    "reconnect"->f.presence.reconnect()
                }
                release.countDown();work.get(3,TimeUnit.SECONDS)
                if(transition=="none") {
                    assertEquals(before+1,f.calls.size)
                    val deleted=Json.parseToJsonElement(f.calls.last().body!!.utf8()).jsonObject
                    assertEquals(original["leaseId"],deleted["leaseId"]);assertEquals(original["writerSecret"],deleted["writerSecret"])
                }else assertEquals(before,f.calls.size)
                f.playback.value=PlaybackProjection();assertFalse(proof.current())
                f.host.tick();assertEquals(if(transition=="none")before+1 else before,f.calls.size)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldDisconnectDeletesOriginalLeaseAfterSynchronousLocalRetirement()=heldDisconnect("none")
    @Test fun heldDisconnectEnteringLocalOnlySendsNothing()=heldDisconnect("local")
    @Test fun heldDisconnectAccountAbaSendsNothing()=heldDisconnect("account")
    @Test fun heldDisconnectExplicitReconnectCannotDeleteWithOldCleanup()=heldDisconnect("reconnect")
    @Test fun localOnlyHostRefreshAndEndAreSilentAtOperationBoundary()=Fixture().use {f->
        val c=f.create();val before=f.calls.size;val snapshot=f.host.state.value.snapshot
        f.playback.value=PlaybackProjection(localOnly=true)
        f.host.refresh(c);assertEquals(before,f.calls.size)
        f.host.end(c);assertEquals(before,f.calls.size);assertSame(snapshot,f.host.state.value.snapshot)
        f.playback.value=PlaybackProjection();f.host.refresh(c)
        assertEquals(before+1,f.calls.size);f.host.end(c)
        assertEquals(before+2,f.calls.size);assertNull(f.host.state.value.snapshot)
    }
    @Test fun localOnlyHostEndIsSilentAtOperationBoundary()=Fixture().use {f->
        val c=f.create();val before=f.calls.size;val snapshot=f.host.state.value.snapshot
        f.playback.value=PlaybackProjection(localOnly=true);f.host.end(c)
        assertEquals(before,f.calls.size);assertSame(snapshot,f.host.state.value.snapshot)
    }
    @Test fun localOnlyHostActionsExplainNetworkSilenceWithoutDiscardingSnapshot()=Fixture().use {f->
        val c=f.create();val snapshot=f.host.state.value.snapshot;val before=f.calls.size
        f.playback.value=PlaybackProjection(localOnly=true);f.host.refresh(c)
        assertEquals("Jam actions are unavailable during device-only playback.",f.host.state.value.message)
        assertSame(snapshot,f.host.state.value.snapshot);assertEquals(before,f.calls.size)
        f.playback.value=PlaybackProjection();f.host.refresh(c);assertNull(f.host.state.value.message)
        val refreshed=f.host.state.value.snapshot
        f.playback.value=PlaybackProjection(localOnly=true);f.host.end(c)
        assertEquals("Jam actions are unavailable during device-only playback.",f.host.state.value.message)
        assertSame(refreshed,f.host.state.value.snapshot);assertEquals(before+1,f.calls.size)
    }
    private fun heldHostAction(end:Boolean) {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);var armed=false
        Fixture {request->if(armed&&request.url.encodedPath.startsWith("/api/v1/jams/")&&request.method==(if(end)"DELETE" else "GET")){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}}.use {f->
            val c=f.create();val snapshot=f.host.state.value.snapshot;val before=f.calls.size;armed=true
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {if(end)f.host.end(c) else f.host.refresh(c)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));assertEquals(before,f.calls.size)
                f.playback.value=PlaybackProjection(localOnly=true)
                release.countDown();work.get(3,TimeUnit.SECONDS)
                assertEquals(before,f.calls.size);assertSame(snapshot,f.host.state.value.snapshot)
                armed=false;f.playback.value=PlaybackProjection()
                if(end){f.host.end(c);assertNull(f.host.state.value.snapshot)}else f.host.refresh(c)
                assertEquals(before+1,f.calls.size)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldRefreshEnteringLocalOnlySendsNothing()=heldHostAction(false)
    @Test fun heldEndEnteringLocalOnlySendsNothing()=heldHostAction(true)
    @Test fun expiredWriterStillAllowsExplicitExactHostRefreshAndEndWithoutRevival()=Fixture().use {f->
        val c=f.create();val proof=f.presence.capture()!!;val request=f.host.state.value.snapshot!!.requests.single()
        f.now=f.now.plusSeconds(91);assertFalse(proof.current());val before=f.calls.size
        f.host.tick();f.host.decide(c,request,true);f.host.invite(c)
        assertEquals(before,f.calls.size);assertTrue(f.inserts.isEmpty())
        f.host.refresh(c);assertEquals(before+1,f.calls.size);assertEquals("GET",f.calls.last().method)
        f.host.end(c);assertEquals(before+2,f.calls.size);assertEquals("DELETE",f.calls.last().method);assertNull(f.host.state.value.snapshot)
        f.host.tick();assertEquals(before+2,f.calls.size);assertFalse(proof.current())
    }
    @Test fun temporaryDisabledReprobesAtThirtySecondsWithoutLogin()=Fixture().use {f->
        f.disabled=true;f.presence.step();assertEquals(PresenceStatus.Disabled,f.presence.state.value.status)
        f.now=f.now.plusSeconds(29);f.presence.step();assertEquals(1,f.calls.size)
        f.disabled=false;f.now=f.now.plusSeconds(1);f.presence.step();assertEquals(PresenceStatus.Online,f.presence.state.value.status);assertEquals(3,f.calls.size)
    }
    @Test fun localOnlyNeverReportsTrackAndSameAccountAbaRetiresProof()=Fixture().use {f->
        f.playback.value=PlaybackProjection(title="PRIVATE LOCAL",localOnly=true)
        f.presence.step();assertTrue(f.calls.isEmpty())
        f.playback.value=PlaybackProjection();f.presence.step()
        val proof=f.presence.capture()!!
        f.session.accept(f.session.beginIntent(),SecretTokens("new","new-r","owner"));assertFalse(proof.current())
        val before=f.calls.size
        assertTrue(runCatching {f.api.privateExchange(proof.scope,"/me/devices",valid={true})}.isFailure)
        assertEquals(before,f.calls.size)
    }
    @Test fun newAccountCannotReportOldProjectionBeforeCanonicalRetirementCompletes()=Fixture().use {f->
        val oldEpoch=f.session.capture()!!.epoch
        f.playback.value=PlaybackProjection(title="Old owner song",queue=listOf(com.soundq.android.playback.QueueOccurrence("occurrence",7,"Old owner song","private",false)),selectedOccurrence="occurrence",sessionIdentity="old",accountEpoch=oldEpoch)
        f.session.accept(f.session.beginIntent(),SecretTokens("replacement","replacement-r","next-owner"))
        f.presence.step()
        val report=Json.parseToJsonElement(f.calls.last().body!!.utf8()).jsonObject
        assertEquals(JsonNull,report["playback"])
    }
    @Test fun currentOwnedTrackApprovalInsertsOnceAndReceiptReconciliationNeverReinserts()=Fixture().use {f->
        val c=f.create();val request=f.host.state.value.snapshot!!.requests.single()
        f.failDecision=true;f.host.decide(c,request,true)
        assertEquals(1,f.inserts.size);assertEquals("Owned song",f.inserts.single().title);assertEquals(1,f.decisions.get())
        f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true)
        assertEquals(1,f.inserts.size);assertEquals(1,f.decisions.get())
        f.failDecision=false;f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true,true)
        assertEquals(1,f.inserts.size);assertEquals(2,f.decisions.get());assertEquals("queued",f.host.state.value.snapshot!!.requests.single().status)
        assertEquals("occurrence-1",f.receipt!!.getValue("occurrenceId").jsonPrimitive.content)
    }
    @Test fun durableAttemptPrecedesActualTicketAndKnownReceiptPrecedesAcknowledgement()=Fixture().use {f->
        val c=f.create();var observed=false
        f.beforeInsert={
            val file=f.receiptDirectory.listFiles()!!.single {it.name.startsWith("jam-admission-")}
            val attempt=Json.parseToJsonElement(file.readText()).jsonObject.getValue("attempts").jsonArray.single().jsonObject
            assertEquals(f.request,attempt.getValue("requestId").jsonPrimitive.content)
            assertEquals(JsonNull,attempt.getValue("receipt"));observed=true
        }
        f.failDecision=true;f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true)
        assertTrue(observed);assertEquals(1,f.inserts.size)
        val file=f.receiptDirectory.listFiles()!!.single {it.name.startsWith("jam-admission-")}
        val stored=Json.parseToJsonElement(file.readText()).jsonObject.getValue("attempts").jsonArray.single().jsonObject.getValue("receipt").jsonObject
        assertEquals("occurrence-1",stored.getValue("occurrenceId").jsonPrimitive.content)
        assertEquals(f.admission.incarnation,stored.getValue("ownerAfter").jsonPrimitive.content)
        f.beforeInsert={fail("Known receipt reconciliation must not call the owner again")};f.failDecision=false
        f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true,true)
        assertEquals(1,f.inserts.size);assertEquals("queued",f.status)
    }
    @Test fun unreadableDurableHistoryCannotBeOverwrittenOrCauseAnotherAdmission()=Fixture().use {f->
        val c=f.create();f.failDecision=true;f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true)
        val file=f.receiptDirectory.listFiles()!!.single {it.name.startsWith("jam-admission-")};file.writeText("{corrupt retained evidence")
        val bytes=file.readBytes();val decisions=f.decisions.get();f.failDecision=false
        f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true,true)
        assertEquals(1,f.inserts.size);assertEquals(decisions,f.decisions.get());assertArrayEquals(bytes,file.readBytes())
    }
    private fun heldBoundary(path:String,replaceOwner:Boolean,decline:Boolean=false)=Fixture().use {f->
        val c=f.create();val request=f.host.state.value.snapshot!!.requests.single()
        f.holdPath=if(path=="host")"/api/v1/jams/${f.hostId()}" else "/api/v1/library"
        val pool=Executors.newSingleThreadExecutor()
        try {
            val work=pool.submit {f.host.decide(c,request,!decline)}
            assertTrue(f.entered.await(2,TimeUnit.SECONDS))
            if(replaceOwner)f.admission.replaceOwner() else {f.host.hide(c);f.host.open()}
            f.release.countDown();work.get(3,TimeUnit.SECONDS)
            assertTrue(f.inserts.isEmpty());assertEquals(0,f.decisions.get())
        }finally {f.release.countDown();pool.shutdownNow()}
    }
    @Test fun hostReadHeldAcrossOwnerReplacementCannotAdmit()=heldBoundary("host",true)
    @Test fun libraryHeldAcrossOwnerReplacementCannotAdmit()=heldBoundary("library",true)
    @Test fun hiddenThenReopenedConsentCannotAdmit()=heldBoundary("host",false)
    @Test fun declineAlsoRechecksConsentAfterHostRead()=heldBoundary("host",false,true)
    @Test fun heartbeatContinuesHiddenWithoutRequestPollingAndInviteSecretIsFragmentOnly()=Fixture().use {f->
        val c=f.create();f.host.invite(c)
        val invite=f.host.state.value.invite!!
        val link=invite.link("https://guest.example.test",f.hostId())
        assertNull(java.net.URI(link).rawQuery);assertTrue(java.net.URI(link).rawFragment!!.contains("invite="));assertFalse(invite.toString().contains("AAAA"))
        assertTrue(runCatching {invite.link("https://guest.example.test/path",f.hostId())}.isFailure)
        f.host.hide(c);val reads=f.calls.count {it.method=="GET"&&it.url.encodedPath.startsWith("/api/v1/jams/")}
        f.host.tick();assertTrue(f.calls.last().url.encodedPath.endsWith("/host"))
        assertEquals(reads,f.calls.count {it.method=="GET"&&it.url.encodedPath.startsWith("/api/v1/jams/")})
        assertTrue(f.host.state.value.snapshot!!.host);assertEquals(TrackId(7),f.host.state.value.snapshot!!.requests.single().trackId)
    }
    @Test fun unknownAdmissionIsTombstonedAndReconciliationCannotCallOwnerAgain()=Fixture().use {f->
        val c=f.create();f.admissionFails=true
        f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true)
        assertTrue(f.inserts.isEmpty());assertEquals("uncertain",f.status)
        f.admissionFails=false
        f.host.decide(c,f.host.state.value.snapshot!!.requests.single(),true,true)
        assertTrue(f.inserts.isEmpty());assertEquals("uncertain",f.status)
    }
    @Test fun retiredScopeWhileLibraryHeldCannotAdmitOrPublishDecision()=Fixture().use {f->
        val c=f.create();val request=f.host.state.value.snapshot!!.requests.single();f.holdPath="/api/v1/library"
        val pool=Executors.newSingleThreadExecutor()
        try {
            val work=pool.submit {f.host.decide(c,request,true)}
            assertTrue(f.entered.await(2,TimeUnit.SECONDS))
            f.session.accept(f.session.beginIntent(),SecretTokens("replacement","replacement-r","owner"))
            f.release.countDown();work.get(3,TimeUnit.SECONDS)
            assertTrue(f.inserts.isEmpty());assertEquals(0,f.decisions.get())
        }finally {f.release.countDown();pool.shutdownNow()}
    }
    @Test fun consentRetiredAfterDecisionLatchedButBeforeActualNetworkDispatchSendsNothing() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        Fixture {request->if(request.method=="PUT"&&request.url.encodedPath.contains("/requests/")){entered.countDown();release.await(3,TimeUnit.SECONDS)}}.use {f->
            val c=f.create();val request=f.host.state.value.snapshot!!.requests.single();val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {f.host.decide(c,request,true)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));assertEquals(1,f.inserts.size)
                f.host.hide(c);f.host.open();release.countDown();work.get(3,TimeUnit.SECONDS)
                assertEquals(0,f.decisions.get());assertEquals(1,f.inserts.size)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun changedSnapshotVersionRequiresFreshExplicitApproval()=Fixture().use {f->
        val c=f.create();val captured=f.host.state.value.snapshot!!.requests.single();f.version++
        f.host.decide(c,captured,true)
        assertTrue(f.inserts.isEmpty());assertEquals(0,f.decisions.get())
    }
}
