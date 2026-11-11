package com.soundq.android.data

import com.soundq.android.data.catalog.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import mockwebserver3.*
import java.util.concurrent.*

/** Actual authenticated producer captures are synthetic database evidence, not invented DTOs. */
class CatalogResolutionTest {
    private fun wire(name:String)=javaClass.getResource("/catalog-resolution/$name.json")!!.readText()
    private fun obj(s:String)=Json.parseToJsonElement(s).jsonObject
    @Test fun allNineProducerCapturesDecodeWithoutSelectingACandidate() {
        for(name in listOf("owned","stored_unowned","missing","different_account","unverified_owned","unverified_other_account","verified_ambiguity","mixed_evidence","bounded")) {
            val body=obj(wire(name));val result=CatalogJson.resolution(body,RecordingMbid(body.getValue("recordingMbid").jsonPrimitive.content),body.getValue("userId").jsonPrimitive.content)
            assertEquals(body.getValue("status").jsonPrimitive.content,result.status)
            assertEquals(body.getValue("candidates").jsonArray.size,result.candidates.size)
        }
    }
    @Test fun generatedNegativesRejectOwnerRecordingStatusAndShapeWithoutRepair() {
        val body=obj(wire("owned"));val id=RecordingMbid(body.getValue("recordingMbid").jsonPrimitive.content);val account=body.getValue("userId").jsonPrimitive.content
        fun reject(b:JsonObject,expected:RecordingMbid=id,user:String=account) {assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {CatalogJson.resolution(b,expected,user)}.exceptionOrNull() as? SafeFailure)?.reason)}
        reject(body,user=CatalogContractTest.A);reject(body,RecordingMbid(CatalogContractTest.T))
        for((key,value) in listOf("recordingMbid" to JsonPrimitive("00000000-0000-0000-0000-000000000000"),"recordingMbid" to JsonPrimitive(id.value.uppercase()),"recordingMbid" to JsonPrimitive(" "+id.value),"userId" to JsonPrimitive("00000000-0000-0000-0000-000000000000"),"userId" to JsonPrimitive(account.uppercase()),"status" to JsonPrimitive("ready"),"status" to JsonPrimitive("missing"),"limit" to JsonPrimitive(21),"limit" to JsonPrimitive("20"),"truncated" to JsonPrimitive(true),"candidates" to JsonNull)) reject(JsonObject(body+ (key to value)))
        val candidate=body.getValue("candidates").jsonArray.single().jsonObject
        for((key,value) in listOf("trackId" to JsonPrimitive("1"),"trackId" to JsonPrimitive(0),"trackId" to Json.parseToJsonElement("9223372036854775808"),"mbVerified" to JsonPrimitive("true"),"inLibrary" to JsonNull)) reject(JsonObject(body+("candidates" to JsonArray(listOf(JsonObject(candidate+(key to value)))))))
        reject(JsonObject(body+("candidates" to JsonArray(listOf(candidate,candidate)))))
    }
    @Test fun queuedActionCallbacksAndRepeatedPositionsKeepExactOwner() {HttpsFixture().use {f->
        val (session,repo,view)=setup(f)
        val jobs=mutableListOf<()->Unit>();val actions=CatalogActions(repo){jobs.add(it)}
        // Actions opens a fresh mounted owner, so reload the actual accepted album under it.
        actions.edit("album");f.reply(CatalogContractTest.releases());actions.search(true);jobs.removeAt(0)()
        var s=repo.state.value;f.reply(CatalogContractTest.album());actions.album(s,s.albums!!.rows.first());jobs.removeAt(0)()
        s=repo.state.value;val row=s.album!!.tracks.single();actions.recording(s,row,0)
        val old=repo.state.value.inspection!!;actions.dismissRecording(old);jobs.removeAt(0)();assertNull(repo.state.value.inspection)
        val count=f.server.requestCount
        s=repo.state.value;actions.recording(s,row,0);val first=repo.state.value.inspection!!;actions.back();actions.recording(repo.state.value,row,0)
        assertNotSame(first.selection,repo.state.value.inspection!!.selection);jobs.removeAt(0)();assertEquals(count,f.server.requestCount)
        actions.close();jobs.removeAt(0)();assertEquals(count,f.server.requestCount)
        assertNull(repo.recording(view,s,row,0))
        val foreign=AccountSession(ApiEndpoint.parse("https://different.invalid/api/v1"),MemoryStore());foreign.accept(foreign.beginIntent(),SecretTokens("b","r",session.capture()!!.accountId))
        assertEquals(SafeFailure.Reason.Retired,(runCatching {SoundQApi(foreign,f.client).catalogResolution(session.capture()!!,row.id){true}}.exceptionOrNull() as? SafeFailure)?.reason)
    }}
    @Test fun ambiguousAndUnverifiedEvidenceNeverBecomeOwnedInRepository() {HttpsFixture().use {f->
        val (_,repo,view)=setup(f)
        for(name in listOf("unverified_owned","mixed_evidence","verified_ambiguity","bounded")) {
            val body=obj(wire(name))
            val state=repo.state.value;val selected=state.album!!.tracks.single()
            // Generated owner/recording binding adaptation; candidate/status bytes are actual producer evidence.
            val adapted=JsonObject(body+("recordingMbid" to JsonPrimitive(selected.id.value))+("userId" to JsonPrimitive(obj(wire("owned")).getValue("userId").jsonPrimitive.content)))
            f.reply(adapted.toString());repo.loadResolution(repo.recording(view,state,selected,0)!!)
            assertEquals(body.getValue("status").jsonPrimitive.content,repo.state.value.inspection!!.result!!.status)
            assertNotEquals("owned",repo.state.value.inspection!!.result!!.status);repo.back(view)
        }
    }}
    @Test fun repeatedRecordingOccurrencesStayDistinctAndWrongIndexIsRefused() {HttpsFixture().use {f->
        val (_,repo,view)=setup(f);repo.back(view)
        val list=repo.state.value;val dto=obj(CatalogContractTest.album());val track=dto.getValue("tracks").jsonArray.single()
        f.reply(JsonObject(dto+("tracks" to JsonArray(listOf(track,track)))+("trackCount" to JsonPrimitive(2))).toString())
        repo.load(repo.album(view,list,list.albums!!.rows.first())!!)
        var s=repo.state.value;val rows=s.album!!.tracks
        assertNull(repo.recording(view,s,rows[0],1));val first=repo.recording(view,s,rows[0],0)!!
        s=repo.state.value;val second=repo.recording(view,s,rows[1],1)!!
        assertEquals(1,repo.state.value.inspection!!.selection.index);repo.loadResolution(first)
        val count=f.server.requestCount;repo.back(view);repo.loadResolution(second);assertEquals(count,f.server.requestCount)
    }}
    private fun setup(f:HttpsFixture):Triple<AccountSession,CatalogRepository,CatalogView> {
        val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r",obj(wire("owned")).getValue("userId").jsonPrimitive.content))
        val repo=CatalogRepository(SoundQApi(session,f.client));val view=repo.open()!!;repo.edit(view,"album");f.reply(CatalogContractTest.releases());repo.load(repo.releases(view)!!)
        val list=repo.state.value;f.reply(CatalogContractTest.album().replace(CatalogContractTest.T,obj(wire("owned")).getValue("recordingMbid").jsonPrimitive.content));repo.load(repo.album(view,list,list.albums!!.rows.first())!!)
        return Triple(session,repo,view)
    }
    @Test fun exactActionsCloseBeforeDispatchAndSheetBackPreserveAlbumAndHistory() {HttpsFixture().use {f->
        val (_,repo,view)=setup(f);val accepted=repo.state.value;val album=accepted.album!!;val row=album.tracks.single()
        val queued=repo.recording(view,accepted,row,0)!!;assertTrue(repo.back(view));repo.loadResolution(queued)
        assertEquals(2,f.server.requestCount);assertSame(album,repo.state.value.album);assertNull(repo.state.value.inspection)
        val request=repo.recording(view,repo.state.value,row,0)!!;f.reply(wire("owned"));repo.loadResolution(request)
        assertEquals("owned",repo.state.value.inspection!!.result!!.status);repo.back(view);assertSame(album,repo.state.value.album);repo.back(view);assertNotNull(repo.state.value.albums)
    }}
    @Test fun heldCallbacksRetireAcrossDismissAbaEditAccountLockAndViewReplacement() {
        for(mode in listOf("close","aba","edit","account","lock","replace")) HttpsFixture().use {f->
            val (session,repo,view)=setup(f);val state=repo.state.value;val row=state.album!!.tracks.single();val request=repo.recording(view,state,row,0)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(wire("owned")).build()}}
            try {val work=pool.submit {repo.loadResolution(request)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                when(mode){"close"->repo.dismissRecording(view,repo.state.value.inspection!!);"aba"->{repo.back(view);repo.recording(view,repo.state.value,row,0)};"edit"->repo.edit(view,"new");"account"->session.accept(session.beginIntent(),SecretTokens("b","r2",CatalogContractTest.A));"lock"->session.lockLocal();"replace"->{repo.close(view);repo.open()}}
                release.countDown();work.get(5,TimeUnit.SECONDS)
                assertNull(mode,repo.state.value.inspection?.result)
                if(mode=="aba")assertTrue(repo.state.value.inspection!!.loading) else assertNull(mode,repo.state.value.inspection)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun explicitSubmitCapturesVisibleTextAndRetiredQueuedWorkCannotDispatch() {HttpsFixture().use {f->
        val (_,repo,_)=setup(f);val jobs=mutableListOf<()->Unit>();val actions=CatalogActions(repo){jobs.add(it)}
        actions.edit("stale focus callback");actions.submit("Concrete",true)
        assertEquals(CatalogRead.Releases("Concrete"),repo.state.value.operation)
        val stale=jobs.removeAt(0);actions.edit("newer edit");val before=f.server.requestCount;stale();assertEquals(before,f.server.requestCount)
        actions.submit("Concrete",true);f.reply(CatalogContractTest.releases());jobs.removeAt(0)()
        assertNotNull(repo.state.value.albums);assertEquals("Concrete",repo.state.value.draft)
        var last:RecordedRequest?=null;repeat(f.server.requestCount){last=f.server.takeRequest(2,TimeUnit.SECONDS)}
        assertEquals("Concrete",last!!.url.queryParameter("q"));assertEquals("GET",last!!.method)
        val count=f.server.requestCount;actions.close();actions.submit("retired",true);assertTrue(jobs.isEmpty());assertEquals(count,f.server.requestCount)
    }}
    @Test fun capabilityFailuresAreNotMissingAndRetryUsesFreshCapture() {HttpsFixture().use {f->
        val (_,repo,view)=setup(f)
        for(code in listOf(404,503)) {
            val s=repo.state.value;val request=repo.recording(view,s,s.album!!.tracks.single(),0)!!;f.reply("{}",code);repo.loadResolution(request)
            val failed=repo.state.value.inspection!!;assertTrue(failed.unavailable);assertFalse(repo.state.value.missing);assertNull(failed.result)
            f.reply(wire("owned"));repo.loadResolution(repo.retryRecording(view,failed)!!);assertEquals("owned",repo.state.value.inspection!!.result!!.status);assertNull(repo.retryRecording(view,failed));repo.back(view)
        }
        repeat(f.server.requestCount) {assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)}
    }}
}
