package com.soundq.android.data

import com.soundq.android.data.offline.*
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class DeviceDownloadsTest {
    private fun wav():ByteArray {
        val count=16000; val b=ByteBuffer.allocate(44+count*2).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36+count*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16).put("data".toByteArray()).putInt(count*2)
        repeat(count){b.putShort((it%200).toShort())};return b.array()
    }
    private class Fixture:AutoCloseable {
        val tls=HttpsFixture()
        val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")!!).toPath(),"device-downloads-").toFile()
        val session=AccountSession(tls.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
        val scope=session.capture()!!
        val api=SoundQApi(session,tls.client)
        val store=DeviceDownloads(dir,session,api,tls.client).also {it.load(scope)}
        val track=Track(TrackId(7),"Fixture")
        fun enqueue(data:ByteArray,size:Long=data.size.toLong(),expires:String="2030-01-01T00:00:00Z") {
            tls.reply("""{"urls":[{"trackId":7,"url":"${tls.server.url("/media/copy.wav")}","expiresAt":"$expires","contentType":"audio/wav","sizeBytes":$size}]}""")
            tls.server.enqueue(MockResponse.Builder().body(Buffer().write(data)).build())
        }
        fun complete(data:ByteArray=ByteArray(128){it.toByte()}) {enqueue(data);store.transfer(store.claim(scope,track){true}!!);assertEquals(DownloadStatus.Complete,store.state.value.rows.single().status)}
        fun index()=dir.walkTopDown().single {it.name=="index.v1.json"}
        override fun close(){tls.close();dir.deleteRecursively()}
    }
    @Test fun duplicateTapSharesTransferProgressPrecedesTerminalAndCancellationAfterBytesPreventsPromotion() {
        Fixture().use {f ->
            f.enqueue(ByteArray(128){it.toByte()})
            val ticket=f.store.claim(f.scope,f.track){true}!!
            assertSame(ticket,f.store.claim(f.scope,f.track){true})
            var sawProgress=false
            f.store.onProgress={count ->assertEquals(DownloadStatus.Downloading,f.store.state.value.rows.single().status);assertTrue(count>0);sawProgress=true}
            f.store.beforePromotion={assertTrue(sawProgress);assertTrue(f.store.cancel(f.scope,f.store.state.value.rows.single()))}
            f.store.transfer(ticket);f.store.transfer(ticket)
            assertEquals(DownloadStatus.Cancelled,f.store.state.value.rows.single().status)
            assertFalse(f.dir.walkTopDown().any {it.extension in listOf("audio","part")})
            f.store.beforePromotion=null;f.store.onProgress=null
            f.complete();assertNotNull(f.store.acquire(f.scope,f.track.id)?.also {it.close()})
            assertEquals(4,f.tls.server.requestCount)
        }
    }
    @Test fun truncatedOversizedAndExpiredNeverPublishPlayableArtifacts() {
        listOf(127L,129L).forEach {expected ->Fixture().use {f ->
            f.enqueue(ByteArray(128),expected);f.store.transfer(f.store.claim(f.scope,f.track){true}!!)
            assertEquals(DownloadStatus.Failed,f.store.state.value.rows.single().status);assertNull(f.store.acquire(f.scope,f.track.id))
            assertFalse(f.dir.walkTopDown().any {it.extension in listOf("audio","part")})
        }}
        Fixture().use {f ->
            f.enqueue(ByteArray(128),expires="2020-01-01T00:00:00Z");f.store.transfer(f.store.claim(f.scope,f.track){true}!!)
            assertEquals(DownloadStatus.Failed,f.store.state.value.rows.single().status);assertEquals(1,f.tls.server.requestCount)
        }
    }
    @Test fun heldAccountABACompletionIsRetiredAndRestartInterruptsWithoutAutoTransfer() {
        Fixture().use {f ->
            f.enqueue(ByteArray(128));val ticket=f.store.claim(f.scope,f.track){true}!!
            f.store.beforePromotion={f.session.accept(f.session.beginIntent(),SecretTokens("b","r","B"));f.session.accept(f.session.beginIntent(),SecretTokens("a2","r2","A"))}
            f.store.transfer(ticket)
            assertNull(f.store.acquire(f.scope,f.track.id))
            val next=f.session.capture()!!;val rebuilt=DeviceDownloads(f.dir,f.session,f.api,f.tls.client);rebuilt.load(next)
            assertEquals(DownloadStatus.Interrupted,rebuilt.state.value.rows.single().status)
            assertEquals(2,f.tls.server.requestCount)
            assertFalse(f.dir.walkTopDown().any {it.extension=="audio"})
        }
    }
    @Test fun rejectedAndExternallyChangedIndexesArePreservedByEveryOrdinaryWrite() {
        listOf("corrupt","future","missing","external").forEach {kind -> Fixture().use {f ->
            f.complete();val index=f.index();val artifact=f.dir.walkTopDown().single {it.extension=="audio"};val audio=artifact.readBytes()
            val sentinel=File(index.parentFile,"foreign.keep").apply {writeText("preserve")}
            when(kind){"corrupt"->index.writeText("{");"future"->index.writeText(index.readText().replace("\"version\":1","\"version\":99"));"missing"->index.delete();else->index.appendText(" ")}
            val rejected=if(index.exists())index.readBytes()else null
            val target=if(kind=="external")f.store else DeviceDownloads(f.dir,f.session,f.api,f.tls.client).also {it.load(f.scope)}
            assertNull(target.claim(f.scope,Track(TrackId(8),"New")){true})
            assertFalse(target.remove(f.scope,target.state.value.rows))
            if(rejected==null)assertFalse(index.exists())else assertArrayEquals(rejected,index.readBytes())
            assertArrayEquals(audio,artifact.readBytes());assertEquals("preserve",sentinel.readText())
        }}
    }
    @Test fun playbackLeaseSurvivesConfirmedRemovalAndForeignFilesRemain() {
        Fixture().use {f ->
            val bytes=ByteArray(128){it.toByte()};f.complete(bytes)
            val file=f.dir.walkTopDown().single {it.extension=="audio"}
            val foreign=File(file.parentFile,"foreign.keep").apply {writeText("keep")}
            val lease=f.store.acquire(f.scope,f.track.id)!!
            assertTrue(f.store.remove(f.scope,f.store.state.value.rows))
            assertTrue(file.exists());assertNull(f.store.acquire(f.scope,f.track.id));assertTrue(f.store.state.value.rows.isEmpty())
            val sample=ByteArray(17);assertEquals(17,lease.read(sample,0,17));assertArrayEquals(bytes.copyOfRange(0,17),sample)
            lease.seek(64);assertEquals(17,lease.read(sample,0,17));assertArrayEquals(bytes.copyOfRange(64,81),sample)
            lease.seek(0)
            val actual=ByteArray(128);assertEquals(128,lease.read(actual,0,128));assertArrayEquals(bytes,actual)
            lease.close();assertFalse(file.exists());assertEquals("keep",foreign.readText())
            assertEquals(2,f.tls.server.requestCount)
        }
    }
    @Test fun sameSizeCorruptionMissingArtifactTraversalAndSymlinkAreNeverPlayableOrDeleted() {
        listOf("corrupt","missing","traversal","symlink").forEach {kind ->Fixture().use {f ->
            f.complete();val index=f.index();val file=f.dir.walkTopDown().single {it.extension=="audio"}
            val foreign=File(f.dir,"foreign.audio").apply {writeBytes(ByteArray(128){it.toByte()})}
            when(kind){"corrupt"->file.writeBytes(ByteArray(128){42});"missing"->file.delete();"traversal"->index.writeText(index.readText().replace(file.name,"../foreign.audio"));else->{file.delete();Files.createSymbolicLink(file.toPath(),foreign.toPath())}}
            val saved=index.readBytes();val target=DeviceDownloads(f.dir,f.session,f.api,f.tls.client);target.load(f.scope)
            assertNull(target.acquire(f.scope,f.track.id));assertFalse(target.state.value.rows.any {it.status==DownloadStatus.Complete})
            assertArrayEquals(saved,index.readBytes());assertArrayEquals(ByteArray(128){it.toByte()},foreign.readBytes())
        }}
    }
    @Test fun endpointAccountAndRetainedRowCapabilitiesCannotCrossScopes() {
        Fixture().use {f ->
            f.complete();val row=f.store.state.value.rows.single();val oldLease=f.store.acquire(f.scope,f.track.id)!!
            f.session.accept(f.session.beginIntent(),SecretTokens("b","r","B"));val next=f.session.capture()!!;f.store.load(next)
            assertTrue(f.store.state.value.rows.isEmpty());assertNull(f.store.acquire(next,f.track.id));assertFalse(f.store.remove(f.scope,listOf(row)))
            assertTrue(runCatching {oldLease.read(ByteArray(1),0,1)}.isFailure);oldLease.close()
            val other=AccountSession(ApiEndpoint.parse("https://other.invalid/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
            val isolated=DeviceDownloads(f.dir,other,SoundQApi(other,f.tls.client),f.tls.client);isolated.load(other.capture()!!)
            assertTrue(isolated.state.value.rows.isEmpty())
            f.session.accept(f.session.beginIntent(),SecretTokens("a2","r2","A"));val restored=f.session.capture()!!;f.store.load(restored)
            assertEquals(DownloadStatus.Complete,f.store.state.value.rows.single().status)
            assertFalse(f.store.remove(f.scope,listOf(row)))
        }
    }
    @Test fun retiredLibraryAndRouteCapturesCannotClaimAndQueuedCancellationDoesNotDispatch() {
        Fixture().use {f ->
            val library=LibraryRepository(f.session,{_,_,_->LibraryPage(listOf(f.track),1,20,0)},{_,_,_->})
            library.refine(LibraryQuery());val captured=library.captureTrack(library.state.value.rows.single())!!
            library.refine(LibraryQuery(text="replacement"))
            assertNull(f.store.claim(captured.scope,captured.track){library.owns(captured)})
            assertNull(f.store.claim(f.scope,f.track){false})
            assertTrue(f.store.state.value.rows.isEmpty())
            val ticket=f.store.claim(f.scope,f.track){true}!!
            assertTrue(f.store.cancel(f.scope,f.store.state.value.rows.single()))
            f.store.transfer(ticket)
            assertEquals(0,f.tls.server.requestCount)
            val rebuilt=DeviceDownloads(f.dir,f.session,f.api,f.tls.client);rebuilt.load(f.scope)
            assertEquals(DownloadStatus.Cancelled,rebuilt.state.value.rows.single().status)
        }
    }
    @Test fun malformedOptionalMetadataAndRefusedRedirectMediaCannotBecomeOfflineCopies() {
        listOf("\"sizeBytes\":\"128\"","\"sizeBytes\":null","\"sizeBytes\":-1","\"sizeBytes\":2147483649","\"contentType\":true","\"etag\":false","\"channels\":\"2\"").forEach {replacement ->Fixture().use {f ->
            val base="""{"trackId":7,"url":"${f.tls.server.url("/media/copy.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":128}"""
            val key=replacement.substringBefore(':')
            val valid=Regex(Regex.escape(key)+":[^,}]+")
            val entry=if(valid.containsMatchIn(base))valid.replace(base,replacement)else base.dropLast(1)+","+replacement+"}"
            f.tls.reply("""{"urls":[$entry]}""")
            f.store.transfer(f.store.claim(f.scope,f.track){true}!!)
            assertEquals(replacement,DownloadStatus.Failed,f.store.state.value.rows.single().status)
            assertEquals(1,f.tls.server.requestCount)
        }}
        listOf(403,302).forEach {status->Fixture().use {f ->
            f.tls.reply("""{"urls":[{"trackId":7,"url":"${f.tls.server.url("/media/copy.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":128}]}""")
            f.tls.server.enqueue(MockResponse.Builder().code(status).addHeader("Location",f.tls.server.url("/media/must-not-follow.wav")).body("refused").build())
            f.store.transfer(f.store.claim(f.scope,f.track){true}!!)
            assertEquals(DownloadStatus.Failed,f.store.state.value.rows.single().status);assertEquals(2,f.tls.server.requestCount)
            assertNull(f.store.acquire(f.scope,f.track.id))
        }}
    }
    @Test fun swappedScopeSymlinkCannotTurnTransferCleanupIntoForeignDeletion() {
        Fixture().use {f ->
            f.enqueue(ByteArray(128));val ticket=f.store.claim(f.scope,f.track){true}!!
            val foreign=File(f.dir,"foreign-dir").apply {mkdirs()}
            var heldDirectory:File?=null;var scopeLink:File?=null;var sentinel:File?=null
            f.store.beforePromotion={
                val stage=f.dir.walkTopDown().single {it.extension=="part"}
                val scopeDir=stage.parentFile!!;val moved=File(f.dir,"retired-scope")
                assertTrue(scopeDir.renameTo(moved));heldDirectory=moved;scopeLink=scopeDir
                sentinel=File(foreign,stage.name).apply {writeText("foreign sentinel")}
                Files.createSymbolicLink(scopeDir.toPath(),foreign.toPath())
            }
            try {
                f.store.transfer(ticket)
                assertEquals("foreign sentinel",sentinel!!.readText())
                assertNotNull(heldDirectory);assertTrue(heldDirectory!!.isDirectory)
                assertFalse(f.store.state.value.rows.any {it.status==DownloadStatus.Complete})
            } finally {scopeLink?.delete()}
        }
    }
    @Test fun indexCannotGrantOwnershipOfForeignUuidNamedBytes() {
        Fixture().use {f ->
            f.complete();val index=f.index();val original=f.dir.walkTopDown().single {it.extension=="audio"}
            val foreign=File(original.parentFile,"00000000-0000-0000-0000-000000000001.audio").apply {writeBytes(original.readBytes())}
            index.writeText(index.readText().replace(original.name,foreign.name))
            val rebuilt=DeviceDownloads(f.dir,f.session,f.api,f.tls.client);rebuilt.load(f.scope)
            assertNull(rebuilt.acquire(f.scope,f.track.id))
            assertFalse(rebuilt.state.value.rows.any {it.status==DownloadStatus.Complete})
            rebuilt.remove(f.scope,rebuilt.state.value.rows)
            assertTrue(foreign.exists());assertTrue(original.exists())
        }
    }
    @Test fun retainedProgressCancelTargetsItsTransferButCannotCancelReplacementRetry() {
        Fixture().use {f ->
            f.enqueue(ByteArray(128));val ticket=f.store.claim(f.scope,f.track){true}!!
            val firstRow=f.store.state.value.rows.single()
            f.store.beforePromotion={assertTrue(f.store.cancel(f.scope,firstRow))}
            f.store.transfer(ticket)
            assertEquals(DownloadStatus.Cancelled,f.store.state.value.rows.single().status)
            val replacement=f.store.claim(f.scope,f.track){true}!!
            assertFalse(f.store.cancel(f.scope,firstRow))
            assertTrue(f.store.cancel(f.scope,f.store.state.value.rows.single()))
            f.store.transfer(replacement);assertEquals(2,f.tls.server.requestCount)
        }
    }
    @Test fun clearOnlyExactConfirmedRowsPreservesForeignBytesAndReconstructedEmptyStore() {
        Fixture().use {f ->
            f.complete();val row=f.store.state.value.rows.single()
            assertFalse(f.store.remove(f.scope,listOf(row.copy())))
            assertNotNull(f.store.acquire(f.scope,f.track.id)?.also {it.close()})
            assertTrue(f.store.remove(f.scope,listOf(row)))
            val rebuilt=DeviceDownloads(f.dir,f.session,f.api,f.tls.client);rebuilt.load(f.scope)
            assertTrue(rebuilt.state.value.ready);assertTrue(rebuilt.state.value.rows.isEmpty());assertFalse(rebuilt.state.value.rejected)
            assertEquals(2,f.tls.server.requestCount)
        }
    }
    @Test fun reopeningValidatesPreviouslyLoadedArtifactsWithoutRewritingEvidence() {
        Fixture().use {f ->
            f.complete();val index=f.index();val saved=index.readBytes();val artifact=f.dir.walkTopDown().single {it.extension=="audio"}
            artifact.writeBytes(ByteArray(128){42})
            f.store.load(f.scope)
            assertEquals(DownloadStatus.Failed,f.store.state.value.rows.single().status)
            assertNull(f.store.acquire(f.scope,f.track.id));assertArrayEquals(saved,index.readBytes())
            assertEquals(2,f.tls.server.requestCount)
        }
    }
    @Test fun malformedDescriptorScalarsRefuseBeforeMediaRequest() {
        listOf("\"7\"","true","null").forEach {id ->Fixture().use {f ->
            f.tls.reply("""{"urls":[{"trackId":$id,"url":"${f.tls.server.url("/media/copy.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":128}]}""")
            f.tls.server.enqueue(MockResponse.Builder().body(Buffer().write(ByteArray(128))).build())
            f.store.transfer(f.store.claim(f.scope,f.track){true}!!)
            assertEquals(DownloadStatus.Failed,f.store.state.value.rows.single().status)
            assertEquals(1,f.tls.server.requestCount)
        }}
    }
    @Test fun trustedHttpsExactTransferReconstructAndResolveWithoutNetwork() {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val server=MockWebServer();server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());server.start()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val dir=Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"offline-test-").toFile()
        try {
            val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("synthetic-a","synthetic-r","fixture"))
            val scope=session.capture()!!;val api=SoundQApi(session,client);val bytes=wav();val track=Track(TrackId(7),"海辺 — exact WAV","Fixture",durationMs=1000)
            server.enqueue(MockResponse.Builder().body("""{"urls":[{"trackId":7,"url":"${server.url("/media/test.wav?signature=synthetic")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":${bytes.size},"etag":"fixture-etag","storageKeyVersion":"v1"}]}""").build())
            server.enqueue(MockResponse.Builder().addHeader("Content-Type","audio/wav").body(Buffer().write(bytes)).build())
            val downloads=DeviceDownloads(dir,session,api,client)
            downloads.load(scope)
            val ticket=downloads.claim(scope,track){true}!!
            downloads.transfer(ticket)
            assertEquals(DownloadStatus.Complete,downloads.state.value.rows.single().status)
            assertEquals(bytes.size.toLong(),downloads.state.value.rows.single().bytes)
            assertEquals("/api/v1/playback/urls",server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath)
            val media=server.takeRequest(2,TimeUnit.SECONDS)!!;assertNull(media.headers["Authorization"])
            assertEquals(2,server.requestCount)
            server.close()
            val reconstructed=DeviceDownloads(dir,session,api,client);reconstructed.load(scope)
            assertEquals(track,reconstructed.state.value.rows.single().track)
            reconstructed.acquire(scope,track.id)!!.use {lease ->
                val actual=ByteArray(bytes.size);assertEquals(bytes.size,lease.read(actual,0,actual.size));assertArrayEquals(bytes,actual)
            }
            assertEquals(2,server.requestCount)
            dir.walkTopDown().filter {it.isFile&&it.extension=="json"}.forEach {file ->
                val text=file.readText();assertFalse(text.contains("signature"));assertFalse(text.contains("synthetic-a"));assertFalse(text.contains("https:"))
            }
        } finally {server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown();dir.deleteRecursively()}
    }
}
