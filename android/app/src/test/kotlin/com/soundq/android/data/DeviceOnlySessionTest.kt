package com.soundq.android.data

import com.soundq.android.data.offline.*
import mockwebserver3.MockResponse
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import javax.crypto.KeyGenerator

class DeviceOnlySessionTest {
    // Compatibility adapter lets the identical behavioral oracle run on the pre-feature source.
    private fun enter(session:AccountSession):Boolean {
        val action=session.javaClass.methods.singleOrNull {it.name=="useDeviceDownloads"&&it.parameterCount==0}
        return if(action!=null)action.invoke(session) as Boolean else session.restore {false}
    }
    @Test fun heldEncryptedDecodeAndQueuedDeviceClaimCannotPublishAfterRevocationOrAccountReplacement() {
        for(replace in listOf(false,true)) HttpsFixture().use {f ->
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            val backing=MemoryStore().apply {tokens=SecretTokens("a","r","A")}
            val store=object:SessionStore {
                override fun load(endpoint:ApiEndpoint):SecretTokens? {entered.countDown();check(release.await(3,TimeUnit.SECONDS));return backing.load(endpoint)}
                override fun save(endpoint:ApiEndpoint,tokens:SecretTokens)=backing.save(endpoint,tokens)
                override fun clear()=backing.clear()
            }
            val session=AccountSession(f.endpoint,store);val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val load=pool.submit<Boolean>{enter(session)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                val replacement=if(replace)session.beginIntent() else {session.revoke();null}
                release.countDown();assertFalse(load.get(3,TimeUnit.SECONDS));assertNull(session.capture())
                if(replacement!=null){assertTrue(session.accept(replacement,SecretTokens("b","br","B")));assertEquals("B",session.capture()!!.accountId)}
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
            assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun consumedRotationSaveFailureCannotFallBackToOldDeviceIdentity() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("old","old-r","A");fail=true}
            val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            f.reply(f.auth("A","rotated"));assertFalse(api.restore())
            assertTrue(session.state.value is AuthState.SaveRequired);assertFalse(enter(session));assertNull(session.capture())
            assertEquals("old",store.tokens!!.access);assertEquals(1,f.server.requestCount)
            store.fail=false;assertTrue(session.retrySave());assertEquals("rotated",session.access(session.capture()!!))
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun explicitDeviceChoiceDoesNotWaitForHeldOnlineReplyAndLateRotationCannotResurrectServerScope() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("old-a","old-r","A")}
            val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1);val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(f.auth("A","rotated")).build()
            }}
            try {
                val restore=pool.submit<Boolean>{api.restore()};assertTrue(entered.await(2,TimeUnit.SECONDS))
                val online=session.capture()!!
                assertTrue(enter(session));val local=session.capture()!!
                assertFalse(session.current(online));assertTrue(session.current(local));assertFalse(session.state.value is AuthState.SignedIn)
                release.countDown();assertFalse(restore.get(3,TimeUnit.SECONDS))
                assertEquals("DeviceOnly",session.state.value.javaClass.simpleName)
                assertTrue(session.current(local));assertEquals("old-a",store.tokens!!.access);assertEquals(0,store.writes)
                assertFalse(session.refresh(local){error("device scope must never refresh")})
                assertFalse(api.restore());assertEquals(1,f.server.requestCount)
                val retired=api.revokeLogout();assertFalse(session.current(local));assertNull(session.capture())
                assertFalse(enter(session));assertFalse(api.restore());api.finishLogout(retired)
                assertNull(store.tokens);assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun deviceChoiceCannotReadRetiredOrReplacementAccountBytesAndRejectedEncryptedBytesSurvive() {
        HttpsFixture().use {f ->
            val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")!!).toPath(),"device-fences-").toFile()
            try {
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey();val file=File(dir,"session")
                val encrypted=EncryptedSessionStore(file){key};encrypted.save(f.endpoint,SecretTokens("not-a-jwt","opaque-r","A"))
                val first=AccountSession(f.endpoint,encrypted);assertTrue(enter(first));val a=first.capture()!!
                assertEquals("A",a.accountId)
                first.accept(first.beginIntent(),SecretTokens("b","br","B"));val b=first.capture()!!
                assertFalse(first.current(a));assertFalse(enter(first));assertEquals("B",first.capture()!!.accountId)
                first.accept(first.beginIntent(),SecretTokens("a2","ar2","A"));assertFalse(first.current(a));assertFalse(first.current(b))
                first.revoke();assertFalse(enter(first));assertNull(first.capture())
                val saved=file.readBytes()
                val foreign=AccountSession(ApiEndpoint.parse("https://other.invalid/api/v1"),EncryptedSessionStore(file){key})
                assertFalse(enter(foreign));assertNull(foreign.capture());assertArrayEquals(saved,file.readBytes())
                for(bytes in listOf(byteArrayOf(0,0,0,99)+saved.copyOfRange(4,saved.size),byteArrayOf(1,2,3))) {
                    file.writeBytes(bytes);val rejected=AccountSession(f.endpoint,EncryptedSessionStore(file){key})
                    assertFalse(enter(rejected));assertNull(rejected.capture());assertTrue(rejected.state.value is AuthState.SignedOut)
                    assertFalse(enter(rejected));assertArrayEquals(bytes,file.readBytes())
                }
                val empty=AccountSession(f.endpoint,MemoryStore());assertFalse(enter(empty));assertNull(empty.capture())
                assertEquals(0,f.server.requestCount)
            } finally {dir.deleteRecursively()}
        }
    }
    @Test fun allServerReadsMutationsAndRefreshRefuseDeviceScopeBeforeActualTlsDispatch() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("a","r","A")};val session=AccountSession(f.endpoint,store)
            assertTrue(enter(session));val scope=session.capture()!!;val api=SoundQApi(session,f.client)
            val calls=listOf<()->Unit>(
                {api.library(scope,LibraryQuery(),0)}, {api.like(scope,TrackId(7),true)}, {api.descriptor(scope,TrackId(7))},
                {api.recent(scope)}, {api.top(scope)}, {api.history(scope,0)}, {api.playlists(scope,0)},
                {api.createPlaylist(scope,com.soundq.android.data.playlists.PlaylistDraft("Local cannot create"))},
                {api.recentImports(scope)}, {api.discoverySearch(scope,"fixture")})
            calls.forEach {call ->assertEquals(SafeFailure.Reason.Retired,(runCatching(call).exceptionOrNull() as SafeFailure).reason)}
            assertFalse(session.refresh(scope){error("no refresh exchange")});assertFalse(api.restore())
            assertEquals(0,f.server.requestCount);assertEquals(0,store.writes)
        }
    }
    @Test fun encryptedReconstructionBrowsesAndReadsExactOwnedBytesWithNoServerAuthentication() {
        HttpsFixture().use {f ->
            val root=Files.createTempDirectory(File(System.getenv("TMPDIR")!!).toPath(),"device-startup-").toFile()
            try {
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
                val file=File(root,"session.v1")
                val encrypted=EncryptedSessionStore(file){key}
                val online=AccountSession(f.endpoint,encrypted)
                assertTrue(online.accept(online.beginIntent(),SecretTokens("synthetic-a","synthetic-r","accepted-account")))
                val api=SoundQApi(online,f.client);val scope=online.capture()!!
                val track=Track(TrackId(7),"海辺 — device copy","Fixture",artwork="https://art.invalid/private")
                val bytes=ByteArray(512){it.toByte()}
                f.reply("""{"urls":[{"trackId":7,"url":"${f.server.url("/media/test.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":512}]}""")
                f.server.enqueue(MockResponse.Builder().body(Buffer().write(bytes)).build())
                val downloads=DeviceDownloads(File(root,"downloads"),online,api,f.client);downloads.load(scope)
                downloads.transfer(downloads.claim(scope,track){true}!!)
                assertEquals(DownloadStatus.Complete,downloads.state.value.rows.single().status)
                assertEquals("/api/v1/playback/urls",f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath)
                assertNull(f.server.takeRequest(2,TimeUnit.SECONDS)!!.headers["Authorization"])
                val saved=file.readBytes()
                f.server.close()
                val rebuilt=AccountSession(f.endpoint,EncryptedSessionStore(file){key})
                assertTrue("accepted encrypted identity must admit explicit device-only listening",enter(rebuilt))
                assertFalse(rebuilt.state.value is AuthState.SignedIn)
                assertEquals("DeviceOnly",rebuilt.state.value.javaClass.simpleName)
                val local=rebuilt.capture()!!;assertEquals("accepted-account",local.accountId)
                val rebuiltApi=SoundQApi(rebuilt,f.client)
                val localStore=DeviceDownloads(File(root,"downloads"),rebuilt,rebuiltApi,f.client);localStore.load(local)
                val row=localStore.state.value.rows.single();assertEquals(track.id,row.track.id);assertEquals(track.title,row.track.title)
                localStore.acquire(local,track.id)!!.use {lease ->val actual=ByteArray(bytes.size);assertEquals(bytes.size,lease.read(actual,0,actual.size));assertArrayEquals(bytes,actual)}
                assertTrue(runCatching {rebuilt.access(local)}.isFailure)
                assertTrue(runCatching {rebuiltApi.library(local,LibraryQuery(),0)}.isFailure)
                assertTrue(runCatching {rebuiltApi.like(local,track.id,true)}.isFailure)
                assertTrue(runCatching {rebuiltApi.descriptor(local,track.id)}.isFailure)
                assertNull(localStore.claim(local,Track(TrackId(8),"No remote download")){true})
                assertArrayEquals(saved,file.readBytes());assertEquals(2,f.server.requestCount)
            } finally {root.deleteRecursively()}
        }
    }
}
