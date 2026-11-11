package com.soundq.android.product.artwork

import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.*
import okhttp3.tls.*
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

/** Real session and HTTPS; the standalone runner supplies only bitmap/playback boundary facades. */
class SelectedPlayerArtworkTest {
    private class Store:SessionStore {
        var saved:SecretTokens?=null
        override fun load(endpoint:ApiEndpoint)=saved
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved=tokens}
        override fun clear(){saved=null}
    }
    private class Fixture:AutoCloseable {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory());start()}
        private val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store())
        val playback=MutableStateFlow(PlaybackProjection())
        var track=Track(TrackId(7),"Selected",artwork=server.url("/cover.png?signature=fixture-private").toString())
        init {account("A");select()}
        fun account(id:String){check(session.accept(session.beginIntent(),SecretTokens("fixture-access","fixture-refresh",id)))}
        fun select(occurrence:String="a",generation:Long=1,source:PlaybackSource=PlaybackSource.Queue,localOnly:Boolean=false) {
            playback.value=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="Selected",queue=listOf(QueueOccurrence(occurrence,7,"Selected","Artist",false)),selectedOccurrence=occurrence,sessionIdentity="service-A",accountEpoch=session.version(),sourceQueueIncarnation="queue-A",selectionIncarnation=generation,source=source,localOnly=localOnly)
        }
        fun loader(client:OkHttpClient=this.client)=SelectedPlayerArtwork(session,client,playback){id->track.takeIf {it.id==id}}
        override fun close(){server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
    }
    private fun png(width:Int=8,height:Int=6):ByteArray {
        val out=java.io.ByteArrayOutputStream()
        javax.imageio.ImageIO.write(java.awt.image.BufferedImage(width,height,java.awt.image.BufferedImage.TYPE_INT_ARGB),"png",out)
        return out.toByteArray()
    }
    private fun reply(bytes:ByteArray=png())=MockResponse.Builder().code(200).body(Buffer().write(bytes)).build()
    private fun await(condition:()->Boolean) {
        val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
        while(!condition()){if(System.nanoTime()>deadline)fail("Artwork did not settle");Thread.sleep(2)}
    }
    private fun fresh(f:Fixture,loader:SelectedPlayerArtwork):SelectedPlayerArtwork.Lease {
        f.server.enqueue(reply());return loader.open(f.playback.value){true}.also {it.start();await {it.bitmap()!=null}}
    }
    @Test fun acceptedArrangementHalfOpenSourceLoadsAndInstallReplacementRetiresPixels() {
        Fixture().use {f->f.loader().use {loader->
            val identity=ArrangementIdentity("arrangement-service",f.session.version(),"queue-A",1,"installed-A")
            val clips=listOf(
                com.soundq.android.data.timeline.TimelineClip("out",8,"Same title",10000,0,10000,0,com.soundq.android.data.timeline.QueueSegment.Context),
                com.soundq.android.data.timeline.TimelineClip("in",7,"Same title",10000,0,10000,5000,com.soundq.android.data.timeline.QueueSegment.Context))
            val accepted=AcceptedArrangement(identity,com.soundq.android.data.timeline.TimelineDocument(clips=clips),listOf(
                QueueOccurrence("out",8,"Same title","",false),QueueOccurrence("in",7,"Same title","",false)))
            f.playback.value=f.playback.value.copy(source=PlaybackSource.Arrangement,selectedOccurrence=identity.install,
                arrangement=accepted,arrangementService=identity.service,queue=accepted.sources,positionMs=5000)
            f.server.enqueue(reply());val lease=loader.open(f.playback.value){true};lease.start()
            await {lease.bitmap()!=null}
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/cover.png",request.url.encodedPath)
            assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
            f.playback.value=f.playback.value.copy(arrangement=accepted.copy(identity=identity.copy(install="installed-B")),selectedOccurrence="installed-B")
            assertNull(lease.bitmap());assertFalse(lease.current())
            f.playback.value=f.playback.value.copy(arrangement=accepted,selectedOccurrence=identity.install)
            assertFalse(lease.current());assertNotNull(fresh(f,loader).bitmap())
        }}
    }
    @Test fun arrangementSourcePolicyUsesAcceptedHalfOpenSpansAndNativePerformanceNotTitleOrDraft() {
        Fixture().use {f->
            val id=ArrangementIdentity("arrangement-service",f.session.version(),"queue-A",1,"installed-A")
            val a=com.soundq.android.data.timeline.TimelineClip("a",7,"Duplicate",10000,0,10000,0,com.soundq.android.data.timeline.QueueSegment.Context)
            val b=a.copy(occurrence="b",track=8,globalStartMs=5000)
            val accepted=AcceptedArrangement(id,com.soundq.android.data.timeline.TimelineDocument(clips=listOf(a,b)),listOf(
                QueueOccurrence("a",7,"Duplicate","",false),QueueOccurrence("b",8,"Duplicate","",false)))
            val p=f.playback.value.copy(source=PlaybackSource.Arrangement,arrangement=accepted,arrangementService=id.service,selectedOccurrence=id.install)
            fun chosen(at:Long)=selectedArtworkSource(p.copy(positionMs=at))?.occurrenceId
            assertEquals("a",chosen(0));assertEquals("a",chosen(4999));assertEquals("b",chosen(5000))
            assertEquals("b",chosen(10000));assertNull(chosen(15000));assertNull(chosen(-1))
            val tied=accepted.copy(document=accepted.document.copy(clips=listOf(a,b.copy(globalStartMs=0))))
            assertNull(selectedArtworkSource(p.copy(arrangement=tied,positionMs=100)))
            assertNull(selectedArtworkSource(p.copy(arrangementService="replaced")))
            assertNull(selectedArtworkSource(p.copy(sourceQueueIncarnation="replaced")))
            assertNull(selectedArtworkSource(p.copy(selectedOccurrence="old-install")))
            assertNull(selectedArtworkSource(p.copy(accountEpoch=p.accountEpoch+1)))
            val deck=PerformanceDeck(PerformanceTarget(id,"a"),9000.0,1.0,9000.0,true,true,false,0,false,null,0,LiveSyncState.Off,0.0,0,0,0)
            // Accepted actual sounding source wins even when the schedule cursor is inside B.
            assertEquals("a",selectedArtworkSource(p.copy(positionMs=12000,performanceDecks=mapOf("a" to deck)))?.occurrenceId)
            val foreign=deck.copy(target=deck.target.copy(identity=id.copy(install="foreign")))
            assertEquals("b",selectedArtworkSource(p.copy(positionMs=12000,performanceDecks=mapOf("a" to foreign)))?.occurrenceId)
            // Equal title and a real track ID do not admit an occurrence absent from accepted sources.
            assertNull(selectedArtworkSource(p.copy(arrangement=accepted.copy(sources=accepted.sources.filter {it.occurrenceId!="b"}),positionMs=6000)))
        }
    }
    @Test fun extractedDrawClosureRefusesHeldPixelsWithoutRecomposition() {
        Fixture().use {f->f.loader().use {loader->
            val lease=fresh(f,loader);val accepted=lease.bitmap()!!
            val draw=DrawBoundary();draw.paint(accepted,java.util.concurrent.atomic.AtomicBoolean(true),lease)
            assertEquals(1,draw.images)
            f.select("b",2)
            draw.paint(accepted,java.util.concurrent.atomic.AtomicBoolean(true),lease)
            assertEquals(1,draw.images) // Held old pixels still exist, but actual production draw closure refused them.
            f.select("a",3);draw.paint(accepted,java.util.concurrent.atomic.AtomicBoolean(true),lease);assertEquals(1,draw.images)
        }}
    }
    @Test fun queueServiceSelectionIncarnationsAndLockSynchronouslyFenceOldPixels() {
        Fixture().use {f->f.loader().use {loader->
            val queue=fresh(f,loader);f.playback.value=f.playback.value.copy(sourceQueueIncarnation="queue-B");assertNull(queue.bitmap())
            f.playback.value=f.playback.value.copy(sourceQueueIncarnation="queue-A",selectionIncarnation=2);assertFalse(queue.current())
            val service=fresh(f,loader);f.playback.value=f.playback.value.copy(sessionIdentity="service-B");assertNull(service.bitmap())
            f.playback.value=f.playback.value.copy(sessionIdentity="service-A",selectionIncarnation=3);assertFalse(service.current())
            val selection=fresh(f,loader);f.playback.value=f.playback.value.copy(selectionIncarnation=4);assertNull(selection.bitmap())
            val locked=fresh(f,loader);assertTrue(f.session.lockLocal());assertNull(locked.bitmap())
            assertTrue(f.session.completeLocalUnlock(f.session.localUnlockTicket()!!));assertFalse(locked.current())
            f.select(generation=5);assertNotNull(fresh(f,loader).bitmap())
        }}
    }
    @Test fun observedOldProjectionCannotBorrowCurrentMetadataAndLoaderCloseCancelsEverything() {
        Fixture().use {f->
            val loader=f.loader();val observed=f.playback.value
            f.select("b",2)
            val old=loader.open(observed){true};old.start();assertFalse(old.current());assertEquals(0,f.server.requestCount)
            val fresh=fresh(f,loader);loader.close();assertNull(fresh.bitmap());assertFalse(fresh.current())
            val closed=loader.open(f.playback.value){true};closed.start();assertFalse(closed.current());loader.close()
        }
    }
    @Test fun localOnlySyntheticUnknownAndUnsafeSelectionsNeverDispatch() {
        Fixture().use {f->f.loader().use {loader->
            fun refused() {val lease=loader.open(f.playback.value){true};lease.start();assertFalse(lease.current());assertNull(lease.bitmap())}
            f.select(localOnly=true);refused()
            f.select(source=PlaybackSource.Arrangement);refused()
            f.select(source=PlaybackSource.SavedMix);refused()
            f.select();f.playback.value=f.playback.value.copy(queue=emptyList());refused()
            f.select();f.playback.value=f.playback.value.copy(queue=f.playback.value.queue+f.playback.value.queue);refused()
            f.select();f.playback.value=f.playback.value.copy(accountEpoch=f.session.version()-1);refused()
            f.select();f.track=f.track.copy(artwork="http://localhost/unsafe");refused()
            f.track=f.track.copy(artwork=null);refused()
            f.session.failure(f.session.version(),SafeFailure.Reason.Network);assertTrue(f.session.useDeviceDownloads());f.select();refused()
            assertEquals(0,f.server.requestCount)
        }}
    }
    @Test fun acceptedPaintIsCheckedSynchronouslyThenNeverRevivesAcrossSelectionSourceAccountAba() {
        Fixture().use {f->f.loader().use {loader->
            val selection=fresh(f,loader)
            f.select("b",2);assertNull(selection.bitmap());f.select("a",3);assertFalse(selection.current())
            val source=fresh(f,loader)
            f.select(source=PlaybackSource.Arrangement,generation=4);assertNull(source.bitmap());f.select(generation=5);assertFalse(source.current())
            val account=fresh(f,loader)
            f.account("B");f.account("A");f.select(generation=6);assertNull(account.bitmap());assertFalse(account.current())
            val healthy=fresh(f,loader);assertNotNull(healthy.bitmap())
            f.playback.value=f.playback.value.copy(localOnly=true);assertNull(healthy.bitmap());assertFalse(healthy.current())
        }}
    }
    @Test fun heldSelectionResponseCancelsAndFreshSelectionRecovers() {
        Fixture().use {f->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/cover.png"){entered.countDown();release.await(5,TimeUnit.SECONDS)}
                return reply()
            }}
            f.loader().use {loader->try {
                val old=loader.open(f.playback.value){true};old.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
                f.select("b",2)
                // Fresh publication must precede release of the old server response, without a checked-read trigger.
                f.track=f.track.copy(artwork=f.server.url("/fresh.png").toString())
                val next=loader.open(f.playback.value){true};next.start();await {next.bitmap()!=null}
                release.countDown();assertNull(old.bitmap());assertNotNull(next.bitmap())
            } finally {release.countDown()}}
        }
    }
    @Test fun heldAccountRetirementCancelsThenNewAccountPublishesBeforeOldResponseRelease() {
        Fixture().use {f->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/cover.png"){entered.countDown();release.await(5,TimeUnit.SECONDS)}
                return reply()
            }}
            f.loader().use {loader->try {
                val old=loader.open(f.playback.value){true};old.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
                f.account("B");f.account("A");f.select(generation=2)
                f.track=f.track.copy(artwork=f.server.url("/new-account.png").toString())
                val next=loader.open(f.playback.value){true};next.start();await {next.bitmap()!=null}
                assertEquals(1L,release.count);assertNull(old.bitmap());assertFalse(old.current())
            } finally {release.countDown()}}
        }
    }
    @Test fun queuedLeaseRetirementCannotBorrowSuccessorSelectionOrDispatchLocally() {
        Fixture().use {f->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/cover.png"){entered.countDown();release.await(5,TimeUnit.SECONDS)}
                return reply()
            }}
            f.loader().use {loader->try {
                val old=loader.open(f.playback.value){true};old.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
                val queued=loader.open(f.playback.value){true};queued.start()
                f.select(localOnly=true,generation=2)
                assertNull(old.bitmap());assertNull(queued.bitmap());assertFalse(queued.current())
                release.countDown();f.select(generation=3);f.track=f.track.copy(artwork=f.server.url("/successor.png").toString())
                val fresh=loader.open(f.playback.value){true};fresh.start();await {fresh.bitmap()!=null}
                assertEquals(2,f.server.requestCount)
            } finally {release.countDown()}}
        }
    }
    @Test fun metadataReplacementAndUnmountRefusePreviouslyAcceptedPixels() {
        Fixture().use {f->f.loader().use {loader->
            val old=fresh(f,loader);f.track=f.track.copy(artwork=f.server.url("/changed.png").toString());assertNull(old.bitmap())
            f.server.enqueue(reply());var mounted=true
            val held=loader.open(f.playback.value){mounted};held.start();await {held.bitmap()!=null}
            mounted=false;assertNull(held.bitmap());mounted=true;assertFalse(held.current())
            assertNotNull(fresh(f,loader).bitmap())
        }}
    }
    @Test fun redirectsOversizeCorruptAndCapacityRefuseWithoutRetry() {
        Fixture().use {f->LibraryArtwork(f.session,f.client).use {shared->
          SelectedPlayerArtwork(f.session,f.client,f.playback,{id->f.track.takeIf {it.id==id}},shared,false).use {loader->
            val refused=listOf(
                MockResponse.Builder().code(302).addHeader("Location",f.server.url("/must-not-follow")).build(),
                reply(ByteArray(4_000_001)),
                MockResponse.Builder().code(200).chunkedBody(Buffer().write(ByteArray(4_000_001)),8192).build(),
                reply("corrupt".toByteArray()),MockResponse.Builder().code(503).build())
            refused.forEachIndexed {index,response->
                f.track=f.track.copy(artwork=f.server.url("/refused-$index").toString())
                f.server.enqueue(response);val old=loader.open(f.playback.value){true};old.start()
                assertEquals("/refused-$index",f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath);await {shared.pendingWorkCount()==0}
                assertNull(old.bitmap());old.close()
                f.track=f.track.copy(artwork=f.server.url("/healthy-$index").toString())
                val barrier=fresh(f,loader)
                assertEquals("/healthy-$index",f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath)
                assertNull(old.bitmap());old.close();barrier.close();assertEquals((index+1)*2,f.server.requestCount)
            }
            val leases=(1..SelectedPlayerArtwork.MAX_LEASES).map {loader.open(f.playback.value){true}}
            assertEquals(4,leases.count {it.current()})
            val excess=loader.open(f.playback.value){true};excess.start();assertFalse(excess.current())
            leases.first().close();assertFalse(excess.current());assertNotNull(fresh(f,loader).bitmap());leases.forEach {it.close()}
        }}}
    }
    @Test fun decodeBoundsRejectCorruptAndEncodedExcessAndCeilOddDimensions() {
        assertNull(decodePlayerArtwork(ByteArray(4_000_001)))
        assertNull(decodePlayerArtwork("not an image".toByteArray()))
        val image=decodePlayerArtwork(png(1025,513))!!
        assertTrue(image.width<=1024);assertTrue(image.height<=1024);assertTrue(image.allocationByteCount<=4_194_304)
    }
    @Test fun actualSelectedQueueArtworkLoadsAboveRowResolutionWithoutCredentials() {
        Fixture().use {f->
            val inherited=f.client.newBuilder().addInterceptor {chain->chain.proceed(chain.request().newBuilder().header("Authorization","Bearer forbidden").header("Cookie","forbidden").build())}.build()
            f.server.enqueue(reply(png(2049,1025)))
            f.loader(inherited).use {loader->
                val lease=loader.open(f.playback.value){true};assertNull(lease.bitmap());lease.start();await {lease.bitmap()!=null}
                val image=lease.bitmap()!!
                assertTrue(image.width in 193..1024);assertTrue(image.height in 1..1024);assertTrue(image.allocationByteCount<=4_194_304)
                val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
                assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"]);assertEquals("/cover.png",request.url.encodedPath)
                lease.close();assertNull(lease.bitmap());assertFalse(lease.current())
            }
        }
    }
}
