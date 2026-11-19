package com.soundq.android.playback

import android.content.ComponentName
import android.os.SystemClock
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.util.concurrent.ListenableFuture
import com.soundq.android.*
import com.soundq.android.data.imports.ImportSource
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.nativeengine.NativeCallbackPlayer
import kotlinx.coroutines.*
import mockwebserver3.*
import org.json.JSONObject
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.Track
import com.soundq.android.data.TrackId
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** The native counter measures mixed output, not an individual deck. */
private class ExclusivePreviewSamples {
    private data class Baseline(val itemId: String, val generation: Long, val callbacks: Long)
    private var baseline: Baseline? = null

    fun observe(itemId: String, snapshot: JSONObject): Boolean {
        val decks = snapshot.getJSONArray("decks")
        val preview = decks.getJSONObject(2)
        val generation = preview.getLong("generation")
        if (!snapshot.getBoolean("coherent") || snapshot.getInt("error") != 0 ||
            generation <= 0 || preview.getLong("identity") != generation || !preview.getBoolean("playing") ||
            preview.getInt("error") != 0 || preview.getLong("sourceFrames") != 0L ||
            snapshot.getLong("scheduleRevision") != 0L || listOf(0, 1, 3).any { slot ->
                val other = decks.getJSONObject(slot)
                other.getLong("identity") != 0L || other.getInt("openDecoders") != 0 || other.getBoolean("playing") ||
                    other.getBoolean("ready") || other.getBoolean("preparing")
            }) return false

        val callbacks = snapshot.getLong("nonSilentCallbacks")
        val first = baseline ?: run {
            baseline = Baseline(itemId, generation, callbacks)
            return false
        }
        // The callback can publish a deck snapshot before it counts its mixed
        // samples. Discard a possible single in-flight callback at the baseline.
        return first.itemId == itemId && first.generation == generation && callbacks - first.callbacks > 1 &&
            preview.getDouble("sourceFrame") >= 800
    }
}

/** CallbackFrontendFixtureRunner: actual TLS, native worker and sole renderer. */
class DiscoveryPreviewServiceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as CallbackFrontendFixtureApplication
    private fun <T> main(action: () -> T): T {
        val result = FutureTask(action)
        instrumentation.runOnMainSync(result)
        return result.get()
    }
    private fun await(label: String, onMain: Boolean = true, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 12_000
        while (SystemClock.elapsedRealtime() < deadline) {
            if (if (onMain) main(predicate) else predicate()) return
            SystemClock.sleep(20)
        }
        fail(label)
    }

    @Test fun heldHttpsRendersNonsilentBeforeTailThenRestoresQueueWithoutWrites() = runBlocking { exercise(false) }

    @Test fun malformedTailAfterFirstRenderRestoresQueueWithError() = runBlocking { exercise(true) }

    @Test fun movingOrdinaryCursorIsParkedFromNativePauseAndUsedForExplicitReplay() = runBlocking { exercise(false, moving = true) }

    @Test fun exactZeroParkBeatsSeededNonzeroLongFormBookmarkOnFirstExplicitPrepare() = runBlocking { exercise(false, seededZero = true) }

    @Test fun removedQueueOccurrenceStaysRemovedAcrossSecondPreviewAndExplicitReplay() = runBlocking { exercise(false, removeBeforeSecondPreview = true) }

    private suspend fun exercise(corrupt: Boolean, moving: Boolean = false, seededZero: Boolean = false,
        removeBeforeSecondPreview: Boolean = false) = coroutineScope {
        ActivityScenario.launch(MainActivity::class.java).use {
            val graph = app.graph
            val server = ProductTransportFixture.server
            val original = server.dispatcher
            val tail = HeldPreviewTail()
            val secondTail = HeldPreviewTail()
            val bytes = previewFixtureBytes()
            val trackId=90301L;val longMs=620_000L;val bookmark=73_000L
            val wav=if(seededZero) longWav(longMs) else null
            val revision=wav?.let {ContentRevision(java.security.MessageDigest.getInstance("SHA-256").digest(it).joinToString(""){b->"%02x".format(b)},it.size.toLong())}
            val history=HistoryKey.Server(ServerAccount(graph.endpoint.identity,"fixture-account"),ServerAudioId(trackId))
            if (corrupt) {
                var at = 0
                val kbps = intArrayOf(0,32,40,48,56,64,80,96,112,128,160,192,224,256,320)
                while(at < 24_000) {
                    val field=bytes[at+2].toInt() and 255
                    at += 144000*kbps[field shr 4]/44100 + ((field shr 1) and 1)
                }
                bytes[at]=0 // corrupt a real packet after the held prefix
            }
            val writes=java.util.concurrent.atomic.AtomicInteger()
            val dispatcher=object:Dispatcher() {
                override fun dispatch(request:RecordedRequest):MockResponse {
                    val path=request.url.encodedPath
                    if(wav!=null&&path=="/api/v1/playback/urls"&&JSONObject(request.body!!.utf8()).getJSONArray("trackIds").optLong(0)==trackId) {
                        check(request.headers["Authorization"]=="Bearer synthetic-fixture-access")
                        return MockResponse.Builder().body("""{"urls":[{"trackId":$trackId,"url":"${ProductTransportFixture.origin.resolve("/media/$trackId.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":${wav.size}}]}""").build()
                    }
                    if(wav!=null&&path=="/media/$trackId.wav") {
                        check(request.headers["Authorization"]==null)
                        return MockResponse.Builder().addHeader("Content-Type","audio/wav").body(okio.Buffer().write(wav)).build()
                    }
                    if (path=="/api/v1/discovery/preview") {
                        check(request.method=="POST" && request.headers["Authorization"]=="Bearer synthetic-fixture-access")
                        return when(JSONObject(request.body!!.utf8()).getString("url")) {
                            "https://www.youtube.com/watch?v=SQPreview01" -> previewFixtureResponse(bytes,tail)
                            "https://www.youtube.com/watch?v=SQPreview02" -> {
                                check(removeBeforeSecondPreview)
                                previewFixtureResponse(bytes,secondTail)
                            }
                            else -> error("Unexpected fixture preview source")
                        }
                    }
                    if (request.method=="POST" && path in setOf("/api/v1/downloads","/api/v1/source-selections","/api/v1/queue/items","/api/v1/me/plays")) writes.incrementAndGet()
                    return original.dispatch(request)
                }
            }
            var other: ListenableFuture<MediaController>? = null
            AutoCloseable {
                AutoCloseable { server.dispatcher=original }.use {
                    AutoCloseable { main {graph.session.retire()} }.use {
                        tail.release.countDown()
                        secondTail.release.countDown()
                        other?.let { main {MediaController.releaseFuture(it)} }
                    }
                }
            }.use {
                server.dispatcher=dispatcher
                val c=main {
                    graph.session.accept(graph.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","fixture-account"))
                    MediaController.Builder(app,SessionToken(app,ComponentName(app,SoundQLibraryService::class.java)))
                        .buildAsync().also { other=it }
                }.get(8,TimeUnit.SECONDS)
                val projection=main {graph.controller}
                val scope=checkNotNull(graph.session.capture())
                await("authenticated controller") {projection.state.value.accountEpoch>=0}
                val rows=if(seededZero) listOf(Track(TrackId(trackId),"Long-form zero fixture",durationMs=longMs))
                    else listOf(Track(TrackId(1),"Preview fixture ordinary","Artist"),Track(TrackId(2),"Following","Artist"))
                suspend fun readBookmark(): Long? = graph.phoneAudio.journal {store,access->
                    val owner=checkNotNull(store.bindServerContent(access,history,checkNotNull(revision),longMs))
                    store.bookmark(owner)?.positionMs
                }
                suspend fun seedBookmark() {
                    assertEquals(bookmark,graph.phoneAudio.journal {store,access->
                        val owner=checkNotNull(store.bindServerContent(access,history,checkNotNull(revision),longMs))
                        val traversal=checkNotNull(store.beginTraversal(owner,java.util.UUID.randomUUID(),1,0,0,longMs))
                        check(store.played(SuccessfulPlaybackReceipt(traversal,1,System.currentTimeMillis()))==Mutation.APPLIED)
                        check(store.checkpoint(SourcePositionCheckpoint(traversal,2,bookmark))==Mutation.APPLIED)
                        check(store.retireTraversal(traversal)==Mutation.APPLIED)
                        store.bookmark(owner)?.positionMs
                    })
                }
                if(seededZero) seedBookmark()
                main {graph.rememberTracks(rows);projection.playContext(rows,if(removeBeforeSecondPreview)1 else 0)}
                await("ordinary playback") { projection.state.value.let {it.isPlaying&&it.queue.size==rows.size&&it.positionMs>=(if(seededZero)bookmark else 100)} }
                if (!moving) main {c.pause()}
                val native=main {app.callbackPlayer as NativeCallbackPlayer}
                fun state()=JSONObject(native.nativeDiagnostics())
                if (!moving) await("ordinary renderer paused") {!native.playWhenReady && !state().getJSONArray("decks").getJSONObject(0).getBoolean("playing")}
                val replay= moving || seededZero || removeBeforeSecondPreview
                val ordinaryDeck=if(replay)state().getJSONArray("decks").getJSONObject(0) else null
                val ordinaryGeneration=ordinaryDeck?.getLong("generation") ?: 0L
                fun exactZero()=native.currentPosition==0L && c.currentPosition==0L && projection.state.value.positionMs==0L &&
                    state().getJSONArray("decks").getJSONObject(0).getLong("positionMs")==0L
                if(seededZero) {
                    assertTrue(main {native.duration}>600_000)
                    val restored=state().getJSONArray("decks").getJSONObject(0).getLong("positionMs")
                    assertTrue("ordinary fresh restore must reach the seeded bookmark, got $restored",restored>=bookmark)
                    main {c.seekTo(0)}
                    await("ordinary seek and its durable zero checkpoint",onMain=false) {
                        main {exactZero()} && runBlocking {readBookmark()}==0L
                    }
                    // A real acknowledged seek may checkpoint zero. Write conflicting
                    // evidence with a newer traversal only after that writer has settled.
                    // Its accepted play supersedes any outstanding older journal receipts.
                    seedBookmark()
                }
                val before=projection.state.value
                val cursor=main {native.currentPosition}
                val beforeWrites=writes.get()
                val beforeSamples=if (!moving) state().getLong("nonSilentCallbacks") else 0L
                val source=checkNotNull(ImportSource.parse("https://www.youtube.com/watch?v=SQPreview01"))
                if (!moving) {
                    val stale=main {projection.captureContextRead()}
                    main {c.pause()}
                    await("other controller Pause retired intent") {!stale()}
                    assertFalse(withContext(Dispatchers.Main) {projection.startDiscoveryPreview(scope,source,"Stale","Synthetic",valid=stale)})
                }
                if(seededZero) {
                    assertTrue(main {exactZero()})
                    assertEquals(bookmark,readBookmark())
                    android.util.Log.i("MountDiag","zero before preview: fresh ordinary restore >= $bookmark; acknowledged seek wrote 0; native/controller/projection=0, bookmark=$bookmark")
                }
                val exclusiveSamples=if (moving) ExclusivePreviewSamples() else null
                val previewStarted=SystemClock.elapsedRealtime()
                val accepted=async(Dispatchers.Main) {
                    val guard=projection.captureContextRead(preview=true)
                    projection.startDiscoveryPreview(scope,source,"Ephemeral preview","Synthetic",valid=guard)
                }
                assertTrue(tail.prefixSent.await(5,TimeUnit.SECONDS))
                val previewTransportBound=minOf(app.fixtureClient.readTimeoutMillis.toLong(),20_000L,15_000L)
                await("preview did not render non-silence while tail was held") {
                    val snapshot=state()
                    if (exclusiveSamples != null) {
                        val item=native.currentMediaItem
                        return@await item!=null && item.mediaId.startsWith(DISCOVERY_PREVIEW_PREFIX) &&
                            item.mediaMetadata.title=="Ephemeral preview" && native.playWhenReady && native.playerError==null &&
                            tail.release.count==1L && tail.tailSent.count==1L &&
                            SystemClock.elapsedRealtime()-previewStarted<previewTransportBound && exclusiveSamples.observe(item.mediaId,snapshot)
                    }
                    val deck=snapshot.getJSONArray("decks").getJSONObject(2)
                    native.currentMediaItem?.mediaId?.startsWith(DISCOVERY_PREVIEW_PREFIX)==true &&
                        deck.getDouble("sourceFrame")>=800 && deck.getLong("sourceFrames")==0L &&
                        !snapshot.getJSONArray("decks").getJSONObject(0).getBoolean("playing") &&
                        snapshot.getLong("nonSilentCallbacks")>beforeSamples
                }
                assertTrue(accepted.await())
                val firstPreview=if(removeBeforeSecondPreview)main {
                    checkNotNull(native.currentMediaItem).mediaId to state().getJSONArray("decks").getJSONObject(2).getLong("generation")
                } else null
                val parkedCursor=main {requireNotNull(native.parkedQueue).position}
                if (moving) assertTrue("ordinary native Pause must follow moving entry: $cursor -> $parkedCursor", parkedCursor > cursor)
                else assertEquals(cursor, parkedCursor)
                assertEquals(1L,tail.release.count)
                assertEquals(1L,tail.tailSent.count)
                assertEquals(beforeWrites,writes.get())
                if(seededZero||removeBeforeSecondPreview)main {c.stop()}
                tail.release.countDown()
                if(corrupt)await("malformed tail should surface an error") {native.playerError!=null}
                await("preview drained and ordinary queue restored") {
                    val deck=state().getJSONArray("decks").getJSONObject(2)
                    deck.getLong("identity")==0L && deck.getInt("openDecoders")==0 &&
                        projection.state.value.source==PlaybackSource.Queue && projection.state.value.queue==before.queue
                }
                assertEquals(before.selectedOccurrence,projection.state.value.selectedOccurrence)
                assertEquals(parkedCursor,main {native.currentPosition})
                if (moving||seededZero) await("controller receives exact parked cursor") {c.currentPosition==parkedCursor && projection.state.value.positionMs==parkedCursor}
                assertFalse(main {native.playWhenReady})
                assertEquals(Player.STATE_IDLE,main {native.playbackState})
                assertEquals(beforeWrites,writes.get())
                assertNull(graph.imports.state.value.acknowledgement)
                assertFalse(app.cacheDir.listFiles().orEmpty().any {it.name.startsWith("soundq-preview-")})
                fun editedQueue() = projection.state.value.let { it.source==PlaybackSource.Queue &&
                    it.queue==before.queue.drop(1) && it.selectedOccurrence==before.selectedOccurrence } &&
                    listOf(native,c).all { it.mediaItemCount==1 && it.currentMediaItemIndex==0 && it.currentMediaItem?.mediaId==before.selectedOccurrence }
                if (removeBeforeSecondPreview) {
                    val keep=checkNotNull(before.selectedOccurrence)
                    val remove=before.queue.first().occurrenceId
                    assertNotEquals(remove,keep)

                    main {projection.remove(remove)}
                    await("service and controller acknowledged removal before subsequent preview") {editedQueue()}
                    val endpoint=graph.endpoint.identity
                    val digest=java.security.MessageDigest.getInstance("SHA-256").digest((endpoint+"\u0000"+scope.accountId).toByteArray())
                        .joinToString(""){"%02x".format(it)}
                    val file=java.io.File(graph.directory,"queue-$digest.json")
                    val store=QueueSnapshotStore(file)
                    fun readQueue()=store.read(endpoint,scope.accountId){graph.session.current(scope)}
                    await("scoped queue store acknowledged removal",onMain=false) {
                        readQueue()?.let {it.items.map {row->row.occurrence}==listOf(keep) && it.selected==0 && it.position==parkedCursor}==true
                    }
                    val durableEdit=checkNotNull(readQueue())
                    val rootBytes=file.readBytes()
                    val (firstId,firstGeneration)=checkNotNull(firstPreview)
                    val secondSamples=state().getLong("nonSilentCallbacks")
                    val secondSource=checkNotNull(ImportSource.parse("https://www.youtube.com/watch?v=SQPreview02"))
                    // Start before the call: prove Stop before the existing socket read,
                    // whole-call or fixture-tail deadlines can terminate the stream.
                    val secondStarted=SystemClock.elapsedRealtime()
                    val transportBound=minOf(app.fixtureClient.readTimeoutMillis.toLong(),20_000L,15_000L)
                    fun secondTailHeld() = secondTail.release.count==1L && secondTail.tailSent.count==1L &&
                        SystemClock.elapsedRealtime()-secondStarted<transportBound
                    val second=async(Dispatchers.Main) {
                        val guard=projection.captureContextRead(preview=true)
                        projection.startDiscoveryPreview(scope,secondSource,"Second preview","Synthetic",valid=guard)
                    }
                    assertTrue(secondTail.prefixSent.await(5,TimeUnit.SECONDS))
                    assertTrue(second.await())
                    var secondDeck = -1
                    var observed = "no sample"
                    try {
                        await("second accepted identity renders non-silence while its tail is held") {
                            val item=native.currentMediaItem
                            val snap=state()
                            val decks=snap.getJSONArray("decks")
                            secondDeck=(2..3).singleOrNull {decks.getJSONObject(it).getLong("identity")>0} ?: -1
                            val d=if(secondDeck>=0)decks.getJSONObject(secondDeck) else null
                            observed="slot=$secondDeck; deck=$d; intent=${native.playWhenReady}; playerState=${native.playbackState}; error=${native.playerError?.errorCode}; outputError=${snap.optInt("error")}"
                            item!=null && item.mediaId.startsWith(DISCOVERY_PREVIEW_PREFIX) && item.mediaId!=firstId &&
                                item.mediaMetadata.title=="Second preview" && native.mediaMetadata.title=="Second preview" &&
                                native.playWhenReady && native.playerError==null && d!=null && d.getLong("identity")==d.getLong("generation") &&
                                d.getLong("generation")!=firstGeneration && d.getBoolean("playing") && d.getInt("error")==0 &&
                                d.getDouble("sourceFrame")>=800 && d.getLong("sourceFrames")==0L &&
                                snap.getLong("nonSilentCallbacks")>secondSamples && secondTailHeld()
                        }
                    } catch(failure:AssertionError) {
                        throw AssertionError(observed,failure)
                    }
                    android.util.Log.i("MountDiag","second preview held-tail render: $observed")
                    fun stoppedWhileHeld(): Boolean {
                        val snap=state()
                        val d=snap.getJSONArray("decks").getJSONObject(secondDeck)
                        val projected=projection.state.value
                        return secondTailHeld() && editedQueue() && !native.playWhenReady && !c.playWhenReady &&
                            !projected.isPlaying && native.playbackState==Player.STATE_IDLE && c.playbackState==Player.STATE_IDLE &&
                            native.currentPosition==parkedCursor && c.currentPosition==parkedCursor && projected.positionMs==parkedCursor &&
                            native.playerError==null && c.playerError==null && snap.getInt("error")==0 &&
                            d.getLong("identity")==0L && d.getInt("openDecoders")==0 && !d.getBoolean("playing") &&
                            !d.getBoolean("ready") && !d.getBoolean("preparing") && d.getInt("error")==0
                    }
                    val returns=mutableListOf<Triple<String,Int,Long>>()
                    var stopError=false
                    val observer=object:Player.Listener {
                        override fun onPlayerError(error:androidx.media3.common.PlaybackException) {stopError=true}
                        override fun onEvents(player:Player,events:Player.Events) {
                            val id=player.currentMediaItem?.mediaId ?: ""
                            if(!id.startsWith(DISCOVERY_PREVIEW_PREFIX))returns.add(Triple(id,player.currentMediaItemIndex,player.currentPosition))
                        }
                    }
                    AutoCloseable {main {native.removeListener(observer)}}.use {
                        main {
                            // Rejection control on the real live preview before sending Stop.
                            assertTrue(secondTailHeld())
                            assertFalse("held preview must not satisfy the Stop oracle without Stop",stoppedWhileHeld())
                            assertTrue(c.isCommandAvailable(Player.COMMAND_STOP))
                            native.addListener(observer)
                            c.stop()
                        }
                        await("second Stop drains preview and restores edited queue while TLS tail is held") {stoppedWhileHeld()}
                        assertEquals(durableEdit,readQueue())
                        assertArrayEquals(rootBytes,file.readBytes())
                        main {
                            assertTrue("Stop and durable readback must precede tail release or transport expiry",stoppedWhileHeld())
                            assertFalse("preview errored during Stop",stopError)
                            assertTrue("wrong ordinary publication at second Stop: $returns",returns.isNotEmpty() && returns.all {it==Triple(keep,0,parkedCursor)})
                        }
                    }
                    android.util.Log.i("MountDiag","second Stop: deck $secondDeck drained, no error, tail held ${secondTail.release.count}/${secondTail.tailSent.count}, elapsed=${SystemClock.elapsedRealtime()-secondStarted}ms/$transportBound ms, durable queue/index 0/cursor $parkedCursor unchanged")
                    assertEquals(beforeWrites,writes.get())
                }
                if (replay) {
                    if(seededZero) {
                        assertEquals(0L,parkedCursor)
                        assertTrue(main {native.currentPosition==0L && c.currentPosition==0L && projection.state.value.positionMs==0L})
                        assertEquals(bookmark,readBookmark())
                    }
                    // Stop must restore the exact logical millisecond cursor. A
                    // subsequent load can address only whole source frames; use
                    // its exact frame, not a millisecond tolerance or a re-seek.
                    val rate=checkNotNull(ordinaryDeck).getLong("sourceRate").also {check(it>0)}
                    val loadFrame=parkedCursor*rate/1_000
                    val loadedPosition=loadFrame*1_000/rate
                    main { c.prepare() }
                    await("first explicit prepare restores native deck cursor without Play") {
                        val deck=state().getJSONArray("decks").getJSONObject(0)
                        deck.getBoolean("ready") && !deck.getBoolean("playing") && deck.getLong("positionMs")==loadedPosition &&
                            deck.getLong("sourceRate")==rate && deck.getDouble("sourceFrame")==loadFrame.toDouble() &&
                            (deck.getLong("identity")>0 && deck.getLong("identity")==deck.getLong("generation") &&
                                deck.getLong("generation")!=ordinaryGeneration && !native.playWhenReady && !c.playWhenReady &&
                                native.currentMediaItem?.mediaId==before.selectedOccurrence && native.currentPosition==loadedPosition &&
                                c.currentPosition==loadedPosition && projection.state.value.positionMs==loadedPosition) &&
                            (!removeBeforeSecondPreview || editedQueue())
                    }
                    android.util.Log.i("MountDiag","first explicit Prepare: parked=$parkedCursor loaded=$loadedPosition frame=$loadFrame rate=$rate")
                    if(seededZero) {
                        assertEquals(bookmark,readBookmark())
                        android.util.Log.i("MountDiag","first explicit Prepare: new ready paused generation at 0, bookmark=$bookmark")
                    }
                    main { c.play() }
                    await("first explicit replay advances from parked cursor") {native.isPlaying && native.currentPosition>parkedCursor &&
                        state().getJSONArray("decks").getJSONObject(0).getDouble("sourceFrame")>loadFrame &&
                        (!removeBeforeSecondPreview || editedQueue())}
                    if(removeBeforeSecondPreview)android.util.Log.i("MountDiag","one-occurrence queue/index 0 retained at paused Prepare and advancing Play")
                }
            }
        }
    }

    private fun longWav(ms:Long):ByteArray {
        val rate=16_000;val samples=(ms*rate/1_000).toInt()
        return java.nio.ByteBuffer.allocate(44+samples*2).order(java.nio.ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36+samples*2).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16)
            put("data".toByteArray()).putInt(samples*2)
            repeat(samples) { putShort(if(it%80<40) 700 else -700) }
        }.array()
    }
}
