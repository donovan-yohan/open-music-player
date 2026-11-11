package com.soundq.android.playback.nativeengine

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import kotlinx.coroutines.*
import kotlinx.coroutines.android.asCoroutineDispatcher
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CompletableFuture

/** Evidence, not a bookmark mutation. Revalidate the captured service/occurrence
 * and seek intent at journal admission; a queued snapshot can be superseded. */
internal data class NativeNaturalEndReceipt(
    val count: Long, val generation: Long, val identity: Long, val traversalRevision: Long,
)

internal data class NativeCallbackDeck(
    val identity: Long, val generation: Long, val positionMs: Long, val durationMs: Long,
    val sourceRate: Int, val sourceFrames: Long, val ready: Boolean, val preparing: Boolean,
    val playing: Boolean, val eofCount: Long, val error: Int,
    val sourceFrame: Double = Double.NaN, val rate: Double = Double.NaN,
    val nominalSourceFrame: Double = Double.NaN, val scratching: Boolean = false,
    val gesture: Long = 0, val lastMoveEventNanos: Long = 0, val lastMoveAppliedNanos: Long = 0,
    val lastMoveSequence: Long = 0, val heldZero: Boolean = false,
    val syncReference: Long = 0, val syncBeats: Int = 0, val syncState: Int = 0,
    val syncPhaseErrorFrames: Double = 0.0,
    val pitchPreserved: Boolean = false, val processingEpoch: Long = 0,
    val effectiveBpm: Double = Double.NaN, val tempoGeneration: Long = 0,
    val boundaryGain: Double = 1.0,
    val traversalRevision: Long = 0,
    val naturalEnd: NativeNaturalEndReceipt? = null,
    /** Requested ordinary listening speed; [rate] is the applied engine pace. */
    val speed: Double = 1.0,
)

internal data class NativeCallbackSnapshot(
    val json: String, val error: Int, val deck: NativeCallbackDeck,
    val decks: List<NativeCallbackDeck> = listOf(deck), val scheduleRevision: Long = 0,
    val globalPositionMs: Long = 0, val scheduleDurationMs: Long = 0,
    val scheduleReady: Boolean = false, val schedulePlaying: Boolean = false,
    val scheduleEnded: Boolean = false, val scheduleError: Int = 0,
    val tempoApplied: Long = 0, val tempoRefused: Long = 0, val sampleRate: Int = 0,
    val naturalEndVersion: Int = 0,
    val speedMin: Double = 1.0, val speedMax: Double = 1.0,
) {
    companion object {
        private fun naturalEnd(root: JSONObject, deck: JSONObject): NativeNaturalEndReceipt? {
            // Old/future producers cannot accidentally upgrade generic EOF into
            // bookmark authority. Schedule completion remains its own contract.
            if (root.optInt("naturalEndVersion") != 1 || !root.optBoolean("coherent") ||
                root.optLong("scheduleRevision") != 0L || root.getInt("error") != 0 ||
                deck.getInt("error") != 0 || !deck.getBoolean("ready") || deck.getBoolean("preparing")) return null
            val count = deck.optLong("naturalEndCount")
            val generation = deck.optLong("naturalEndGeneration")
            val identity = deck.optLong("naturalEndIdentity")
            val revision = deck.optLong("naturalEndTraversalRevision")
            if (count <= 0 || generation <= 0 || identity <= 0 || revision <= 0 ||
                generation != deck.getLong("generation") || identity != deck.getLong("identity") ||
                revision != deck.optLong("traversalRevision")) return null
            return NativeNaturalEndReceipt(count, generation, identity, revision)
        }
        fun parse(json: String): NativeCallbackSnapshot {
            val root = JSONObject(json)
            val array = root.getJSONArray("decks")
            val decks = (0 until array.length()).map { n -> val deck = array.getJSONObject(n); NativeCallbackDeck(
                deck.getLong("identity"), deck.getLong("generation"), deck.getLong("positionMs"),
                deck.getLong("durationMs"), deck.getInt("sourceRate"), deck.getLong("sourceFrames"),
                deck.getBoolean("ready"), deck.getBoolean("preparing"), deck.getBoolean("playing"),
                deck.getLong("eofCount"), deck.getInt("error"),
                deck.optDouble("sourceFrame", Double.NaN), deck.optDouble("rate", Double.NaN),
                deck.optDouble("nominalSourceFrame", Double.NaN), deck.optBoolean("scratching"),
                deck.optLong("gesture"), deck.optLong("lastMoveEventNanos"), deck.optLong("lastMoveAppliedNanos"),
                deck.optLong("lastMoveSequence"), deck.optBoolean("heldZero"),
                deck.optLong("syncReference"), deck.optInt("syncBeats"), deck.optInt("syncState"), deck.optDouble("syncPhaseErrorFrames", 0.0),
                deck.optBoolean("pitchPreserved"), deck.optLong("processingEpoch"), deck.optDouble("effectiveBpm",Double.NaN), deck.optLong("tempoGeneration"),
                deck.optDouble("boundaryGain", 1.0),
                deck.optLong("traversalRevision"), naturalEnd(root, deck), deck.optDouble("speed", 1.0),
            ) }
            val rate = root.optInt("sampleRate", 0)
            return NativeCallbackSnapshot(json, root.getInt("error"), decks.first(), decks,
                root.optLong("scheduleRevision"), if (rate > 0) root.optLong("globalFrame") * 1000 / rate else 0,
                if (rate > 0) root.optLong("durationFrames") * 1000 / rate else 0,
                root.optBoolean("scheduleReady"), root.optBoolean("schedulePlaying"), root.optBoolean("scheduleEnded"), root.optInt("scheduleError"), root.optLong("tempoApplied"), root.optLong("tempoRefused"), rate, root.optInt("naturalEndVersion"),
                root.optDouble("speedMin", 1.0), root.optDouble("speedMax", 1.0))
        }
    }
}

/** Captured native headroom, never serialized to UI or reconstructed from a target. */
internal class NativeTempoReservation internal constructor(internal val token: Long) {
    @Volatile internal var finished = false
}

/** The one native handle and every JNI call have exactly one HandlerThread owner. */
internal class NativeCallbackOwner(
    private val calls: NativeCallbackCalls,
    private val observe: (NativeCallbackSnapshot?) -> Unit,
) {
    private val thread = HandlerThread("SoundQ-native-control").apply { start() }
    private val handler = Handler(thread.looper)
    private val dispatcher = handler.asCoroutineDispatcher("SoundQ-native-control")
    private val main = Handler(Looper.getMainLooper())
    private var handle = 0L
    private var openingFailed = false
    private var closing = false
    private val borrowed = mutableSetOf<File>()
    private val ordinaryFiles = mutableMapOf<Int, File>()
    private var arrangementBorrowed = false
    @Volatile private var observationRevision = 0L
    @Volatile var diagnostics: String = "{}"
        private set
    val released = CompletableFuture<Boolean>()

    private val poll = object : Runnable {
        override fun run() {
            if (closing || handle == 0L) return
            try {
                val snapshot = NativeCallbackSnapshot.parse(calls.state(handle))
                diagnostics = snapshot.json
                val revision = observationRevision
                main.post { if (revision == observationRevision) observe(snapshot) }
            } catch (_: Throwable) {
                val revision = observationRevision
                main.post { if (revision == observationRevision) observe(null) }
            }
            if (!closing) handler.postDelayed(this, 50)
        }
    }

    init {
        handler.post {
            try { handle = calls.open(); openingFailed = handle == 0L }
            catch (_: Throwable) { openingFailed = true }
            if (openingFailed) main.post { observe(null) } else handler.post(poll)
        }
    }

    suspend fun load(file: File, identity: Long, generation: Long, position: Long, current: () -> Boolean, speed: Double = 1.0): Boolean = loadDeck(0, file, identity, generation, position, current, speed)
    suspend fun loadDeck(deck: Int, file: File, identity: Long, generation: Long, position: Long, current: () -> Boolean, speed: Double = 1.0): Boolean =
        withContext(dispatcher) {
            // Calling load transfers custody even if admission is revoked before JNI.
            // A throwing JNI load has uncertain custody. Keep its file through release.
            if (deck !in 0..1 || arrangementBorrowed || ordinaryFiles.containsKey(deck)) { borrowed.add(file); return@withContext false }
            borrowed.add(file)
            ordinaryFiles[deck] = file
            if (closing || openingFailed || handle == 0L || !current()) return@withContext false
            try { if (speed == 1.0) calls.load(handle, deck, file.absolutePath, identity, generation, position)
                else calls.loadSpeed(handle, deck, file.absolutePath, identity, generation, position, speed) }
            catch (_: Throwable) { false }
        }

    suspend fun control(operation: Int, value: Double = 0.0, current: () -> Boolean = { true }): Boolean = controlDeck(0, operation, value, current)
    suspend fun controlDeck(deck: Int, operation: Int, value: Double = 0.0, current: () -> Boolean = { true }): Boolean =
        withContext(dispatcher) {
            !closing && handle != 0L && current() &&
                try { calls.control(handle, operation, deck, value, System.nanoTime()) } catch (_: Throwable) { false }
        }

    suspend fun crossfade(outgoing: Int, outgoingGeneration: Long, incoming: Int, incomingGeneration: Long, milliseconds: Long, current: () -> Boolean): Boolean = withContext(dispatcher) {
        !closing && handle != 0L && current() && try { calls.crossfade(handle, outgoing, outgoingGeneration, incoming, incomingGeneration, milliseconds) } catch (_: Throwable) { false }
    }

    /** Per-slot unassign ACK plus concrete WorkerDeck destruction, never EOF alone. */
    suspend fun unloadDeck(deck: Int): Boolean = withContext(dispatcher) {
        val file = ordinaryFiles[deck] ?: return@withContext true
        if (closing || handle == 0L) return@withContext false
        val retired = try {
            calls.control(handle, 8, deck, 0.0, System.nanoTime()) && withTimeoutOrNull(15_000) {
                while (true) {
                    val d = JSONObject(calls.state(handle)).getJSONArray("decks").getJSONObject(deck)
                    if (d.getLong("identity") == 0L && !d.getBoolean("ready") && !d.getBoolean("preparing") && d.optInt("openDecoders", -1) == 0) break
                    delay(20)
                }; true
            } == true
        } catch (_: Throwable) { false }
        if (retired) {
            ordinaryFiles.remove(deck); borrowed.remove(file)
            withContext(Dispatchers.IO) { file.delete() }
        }
        retired
    }

    /** Explicit Play/Apply only. Keeps decoder/file custody and never submits Play. */
    suspend fun recoverOutput(current: () -> Boolean): Boolean = withContext(dispatcher) {
        if (closing || handle == 0L || !current()) return@withContext false
        observationRevision++ // prior-route snapshots cannot retire this new intent
        try { calls.control(handle, 9, 0, 0.0, System.nanoTime()) && current() }
        catch (_: Throwable) { false }
    }

    /** One queued runnable and one latest Move, independent of event rate. Terminals bypass the lane. */
    private data class ScratchCall(val operation: Int, val instance: Long, val gesture: Long, val event: Long, val rate: Double, val current: () -> Boolean, val done: (Boolean) -> Unit)
    private val moveLock = Any()
    private var latestMove: ScratchCall? = null
    private var moveQueued = false
    private var terminalScratch: ScratchCall? = null
    private var terminalAttempts = 0
    private val retryTerminal = object : Runnable {
        override fun run() {
            val call = terminalScratch ?: return
            val attempted = !closing && handle != 0L && call.current()
            val accepted = attempted && try { calls.scratch(handle, call.operation, call.instance, call.gesture, call.event, call.rate) } catch (_: Throwable) { false }
            if (attempted && !accepted && ++terminalAttempts < 20) { handler.postDelayed(this, 5); return }
            terminalScratch = null
            // A full/refused reliable lane must not leave a live gesture running.
            if (attempted && !accepted) try { calls.arrangement(handle, 2, 0) } catch (_: Throwable) { }
            main.post { call.done(accepted) }
        }
    }
    private fun dispatchScratch(call: ScratchCall) {
        if (call.operation == 3 || call.operation == 4) {
            terminalScratch = call; terminalAttempts = 0
            handler.removeCallbacks(retryTerminal); retryTerminal.run(); return
        }
        val accepted = !closing && handle != 0L && call.current() &&
            try { calls.scratch(handle, call.operation, call.instance, call.gesture, call.event, call.rate) } catch (_: Throwable) { false }
        main.post { call.done(accepted) }
    }
    private val drainMove = object : Runnable {
        override fun run() {
            val next = synchronized(moveLock) { latestMove.also { latestMove = null } }
            next?.let(::dispatchScratch)
            synchronized(moveLock) {
                if (latestMove != null) handler.post(this) else moveQueued = false
            }
        }
    }
    fun offerScratch(operation: Int, instance: Long, gesture: Long, eventNanos: Long, rate: Double, current: () -> Boolean, done: (Boolean) -> Unit = {}) {
        val call = ScratchCall(operation, instance, gesture, eventNanos, rate, current, done)
        synchronized(moveLock) {
            if (operation == 2) {
                latestMove = call
                if (!moveQueued) { moveQueued = true; handler.post(drainMove) }
            } else {
                if (operation == 3 || operation == 4) {
                    latestMove = null; handler.removeCallbacks(drainMove); moveQueued = false
                }
                handler.post { dispatchScratch(call) }
            }
        }
    }
    suspend fun sync(incoming: Long, reference: Long, beats: Int, referenceGrid: com.soundq.android.playback.QualifiedLiveGrid?, incomingGrid: com.soundq.android.playback.QualifiedLiveGrid?, current: () -> Boolean): Boolean = withContext(dispatcher) {
        !closing && handle != 0L && current() && try {
            calls.sync(handle, incoming, reference, beats,
                referenceGrid?.bpm ?: 0.0, referenceGrid?.anchorMs ?: 0.0, referenceGrid?.groupOriginMs ?: -1.0,
                incomingGrid?.bpm ?: 0.0, incomingGrid?.anchorMs ?: 0.0, incomingGrid?.groupOriginMs ?: -1.0)
        } catch (_: Throwable) { false }
    }

    suspend fun snapshot(current: () -> Boolean): NativeCallbackSnapshot? = withContext(dispatcher) {
        if (closing || handle == 0L || !current()) null
        else try { NativeCallbackSnapshot.parse(calls.state(handle)).takeIf { current() } } catch (_: Throwable) { null }
    }
    // Tags belong to this Host, not to an occurrence, document or lease.
    private var tempoSequence = 0L
    private var retainedTempoReservation: NativeTempoReservation? = null
    suspend fun reserveTempo(revision: Long, instance: Long, sourceBpm: Double, originBpm: Double, current: () -> Boolean): NativeTempoReservation? = withContext(dispatcher) {
        if (closing || handle == 0L || !current()) return@withContext null
        retainedTempoReservation?.takeIf { it.finished }?.let {
            // Exact old token release changes no audio. The NEW captured service
            // owner authorizes this queued cleanup before its own reservation.
            try { calls.releaseTempo(handle, it.token) } catch (_: Throwable) { }
            retainedTempoReservation = null
        }
        val token = try { calls.reserveTempo(handle, revision, instance, sourceBpm, originBpm) } catch (_: Throwable) { 0L }
        if (token <= 0) null else NativeTempoReservation(token).also { retainedTempoReservation = it }
    }
    suspend fun releaseTempo(reservation: NativeTempoReservation, current: () -> Boolean): Boolean = withContext(dispatcher) {
        reservation.finished = true
        val accepted = !closing && handle != 0L && current() && try { calls.releaseTempo(handle, reservation.token) } catch (_: Throwable) { false }
        if (accepted && retainedTempoReservation === reservation) retainedTempoReservation = null
        accepted
    }
    suspend fun restoreTempo(reservation: NativeTempoReservation, current: () -> Boolean): Long? = withContext(dispatcher) {
        if (closing || handle == 0L || reservation.finished || !current() || tempoSequence == Long.MAX_VALUE) return@withContext null
        val tag = ++tempoSequence
        if (try { calls.restoreTempo(handle, reservation.token, tag) } catch (_: Throwable) { false }) tag else null
    }
    suspend fun liveTempo(revision: Long, instance: Long, sourceBpm: Double, targetBpm: Double, glideMs: Long, reservation: NativeTempoReservation, current: () -> Boolean): Long? = withContext(dispatcher) {
        if (closing || handle == 0L || reservation.finished || !current() || tempoSequence == Long.MAX_VALUE) return@withContext null
        val rate = try { JSONObject(calls.state(handle)).getInt("sampleRate") } catch (_: Throwable) { return@withContext null }
        if (rate <= 0 || glideMs !in 0..10_000) return@withContext null
        val tag = ++tempoSequence
        if (try { calls.liveTempo(handle, revision, instance, tag, sourceBpm, targetBpm, glideMs * rate / 1000, reservation.token) } catch (_: Throwable) { false }) tag else null
    }
    suspend fun retainedBytes(): Long = withContext(dispatcher) { borrowed.sumOf { it.length() } }
    suspend fun prepareSchedule(candidate: NativeCallbackArrangement, revision: Long, current: () -> Boolean): Boolean = withContext(dispatcher) {
        if (closing || handle == 0L || !current()) return@withContext false
        try {
            val accepted=candidate.tempo?.let {calls.prepareScheduleV2(handle,revision,candidate.paths(),candidate.values,it)}
                ?: calls.prepareSchedule(handle,revision,candidate.paths(),candidate.values)
            accepted && current()
        }
        catch (_: Throwable) { false }
    }
    suspend fun discardSchedule() = withContext(dispatcher) {
        if (handle != 0L) try { calls.arrangement(handle, 6, 0) } catch (_: Throwable) { false } else false
    }
    suspend fun installSchedule(candidate: NativeCallbackArrangement, current: () -> Boolean): Boolean = withContext(dispatcher) {
        // All source files transfer together, before any potentially throwing JNI.
        borrowed.addAll(candidate.files)
        arrangementBorrowed = true
        val accepted = !closing && handle != 0L && current() && try { calls.arrangement(handle, 4, 0) } catch (_: Throwable) { false }
        if (!accepted && handle != 0L) try { calls.arrangement(handle, 6, 0) } catch (_: Throwable) { /* uncertain metadata retained; bytes remain borrowed */ }
        accepted
    }
    suspend fun arrangement(operation: Int, value: Long = 0, current: () -> Boolean = { true }): Boolean = withContext(dispatcher) {
        !closing && handle != 0L && current() && try { calls.arrangement(handle, operation, value) } catch (_: Throwable) { false }
    }
    /** No successor can load until this exact source's concrete decoder-release receipt. */
    suspend fun unload(): Boolean {
        val ordinary = withContext(dispatcher) { ordinaryFiles.keys.toList() }
        for (deck in ordinary) if (!unloadDeck(deck)) return false
        val result = withContext(dispatcher) {
            if (borrowed.isEmpty()) return@withContext true
            if (closing || handle == 0L) return@withContext false
            try {
                if (arrangementBorrowed) {
                    if (!calls.arrangement(handle, 5, 0)) return@withContext false
                } else if (!calls.control(handle, 8, 0, 0.0, System.nanoTime())) return@withContext false
                withTimeoutOrNull(15_000) {
                    while (true) {
                        val root = JSONObject(calls.state(handle))
                        if (arrangementBorrowed && root.optLong("scheduleRevision", -1) == 0L && !root.optBoolean("scheduleRetiring", true)) break
                        val deck = root.getJSONArray("decks").getJSONObject(0)
                        if (!arrangementBorrowed && deck.getLong("identity") == 0L && !deck.getBoolean("ready") &&
                            !deck.getBoolean("preparing") && deck.optInt("openDecoders", -1) == 0) break
                        delay(20)
                    }
                    true
                } ?: false
            } catch (_: Throwable) { false }
        }
        if (result) { arrangementBorrowed = false; deleteBorrowed() }
        return result
    }

    private suspend fun deleteBorrowed() {
        val files = withContext(dispatcher) { borrowed.toList().also { borrowed.clear(); ordinaryFiles.clear() } }
        withContext(Dispatchers.IO) { files.forEach { it.delete() } }
    }

    suspend fun close() {
        val success = withContext(dispatcher) {
            closing = true
            handler.removeCallbacks(poll)
            try {
                if (handle == 0L) !openingFailed else calls.close(handle).also { if (it) handle = 0 }
            } catch (_: Throwable) { false }
        }
        if (success) deleteBorrowed()
        released.complete(success)
        // Failed close deliberately retains both owner and encoded files, never certifies release.
        if (success) thread.quitSafely() else failedOwners.add(this)
    }

    companion object {
        private val failedOwners = java.util.concurrent.CopyOnWriteArrayList<NativeCallbackOwner>()
    }
}
