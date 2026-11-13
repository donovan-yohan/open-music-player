package com.soundq.android.playback.nativeengine

import android.os.Looper
import androidx.media3.common.*
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.soundq.android.AppGraph
import com.soundq.android.data.AccountScope
import com.soundq.android.data.AuthState
import com.soundq.android.playback.*
import com.soundq.android.playback.QueuePolicy
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.listening.ListeningCompletionPlayer
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.combine
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/** Service-owned occurrence queue. Native acknowledgements are the only running position clock. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class NativeCallbackPlayer(
    private val graph: AppGraph,
    private val grants: ConcurrentHashMap<String, MediaGrant>,
    jobs: CoroutineScope,
    calls: NativeCallbackCalls = JniNativeCallbackCalls,
    private val source: NativeCallbackSource = GrantedNativeCallbackSource(graph, grants),
    private val random: Random = Random.Default,
) : SimpleBasePlayer(Looper.getMainLooper()), ListeningCompletionPlayer {
    private var items = emptyList<MediaItem>()
    private var order = emptyList<Int>()
    private var index = 0
    private var position = 0L
    private var playback = Player.STATE_IDLE
    @Volatile private var intent = false
    private var repeat = Player.REPEAT_MODE_OFF
    private var shuffle = false
    private var restoredShuffle: Boolean? = null
    private var queueScope: AccountScope? = null
    private var error: PlaybackException? = null
    private var outputUnavailable = false
    private var outputRecoveryRevision: Long? = null
    private var arrangement: NativeCallbackArrangement? = null
    private var nativeScheduleRevision = 0L
    private var arrangementGrants = emptyMap<String, MediaGrant>()
    private var arrangementSourceItems = emptyList<MediaItem>()
    private var preparedArrangement: NativeCallbackArrangement? = null
    private var selectedLoaded = false
    private var activeGrant: MediaGrant? = null
    private var activeUri: String? = null
    private var acknowledgedPlaying = false
    private var eofCount = 0L
    private var ordinaryDeck = 0
    private var ordinaryIdentity = 0L
    private var sourceSequence = 0L
    private class Successor(val item: MediaItem, val grant: MediaGrant, val uri: String,
        val deck: Int, val identity: Long, val outgoing: MediaItem, val outgoingGrant: MediaGrant,
        val outgoingUri: String, val outgoingDeck: Int, val outgoingIdentity: Long, val outgoingEof: Long,
        val speed: Double = 1.0) {
        var armed = false
        var arming = false
        var completed = false
    }
    private var successor: Successor? = null
    private var successorJob: Job? = null
    private var successorRevision = 0L
    private var successorAttempt: String? = null
    private fun successorCurrent(c: Successor) = successor === c && currentScope() &&
        grants[c.uri] === c.grant && c.grant.current(graph) &&
        grants[c.outgoingUri] === c.outgoingGrant && c.outgoingGrant.current(graph)

    /** Explicit edits permit retry; a failed optional source stays latched across polls. */
    private fun cancelSuccessor(preserveAttempt: Boolean = false,natural:Boolean=false) {
        successorRevision++; successorJob?.cancel()
        if (!preserveAttempt) successorAttempt = null
        val c = successor; successor = null
        if (c != null) {
            val keepDeck = ordinaryDeck; val keepIdentity = ordinaryIdentity
            val otherDeck = if (keepDeck == c.deck) c.outgoingDeck else c.deck
            val otherIdentity = if (keepDeck == c.deck) c.outgoingIdentity else c.identity
            journal.retire(otherDeck,drain=natural)
            val predecessor = tail
            tail = lifetime.launch {
                predecessor?.join()
                if (c.armed || c.arming) owner.crossfade(keepDeck, keepIdentity, otherDeck, otherIdentity, 0) { true }
                if (!owner.unloadDeck(otherDeck) && !released) fail("Crossfade source could not be released")
            }
        }
    }

    /** Acquire only one immediate traversal successor. IO and decoding remain off callback. */
    private fun prepareSuccessor() {
        val preference = graph.crossfadePreferences.state.value
        if (!preference.ready || preference.error || preference.seconds == 0 || released || arrangement != null ||
            !selectedLoaded || playback != Player.STATE_READY || successor != null || successorJob != null || desiredSeek != null) return
        // Finite crossfade scheduling needs sealed endpoints. Do not repeatedly
        // acquire/cancel successors while this local source end is still unknown.
        if(activeGrant?.device!=null && selected()?.mediaId !in durations)return
        val next = NativeCallbackTraversal.next(activeOrder(), index, repeat, true) ?: return
        if (next == index) return // Repeat One is the existing source-local cycle.
        val item = items[next]; val uri = item.localConfiguration!!.uri.toString()
        val grant = grants[uri] ?: return
        val attempt = "$ordinaryIdentity/${item.mediaId}/${preference.revision}"
        if (successorAttempt == attempt) return
        successorAttempt = attempt
        val generation = epoch; val revision = successorRevision
        sourceSequence = maxOf(sourceSequence, epoch) + 2
        val c = Successor(item, grant, uri, 1 - ordinaryDeck, sourceSequence, selected() ?: return,
            activeGrant ?: return, activeUri ?: return, ordinaryDeck, ordinaryIdentity, eofCount, loadSpeed(item))
        successor = c
        fun current() = !released && epoch == generation && successorRevision == revision && successorCurrent(c)
        val predecessor = tail
        preparing.incrementAndGet()
        val job = lifetime.launch(start = CoroutineStart.LAZY) {
            var file: NativePlaybackSource? = null; var transferred = false
            try {
                predecessor?.join(); check(current())
                withContext(NonCancellable + Dispatchers.IO) { file = source.acquire(item, ::current) }
                ensureActive(); check(current())
                transferred = true
                check(withContext(NonCancellable) { owner.loadDeck(c.deck, requireNotNull(file), c.identity, c.identity, journal.initialResume(requireNotNull(file),grant,c.deck), ::current, c.speed) })
                check(current())
                bindJournal(item,grant,requireNotNull(file),c.deck,c.identity,true,::current)
                owner.controlDeck(c.deck, 7, volume.toDouble(), ::current)
            } catch (_: CancellationException) { }
            catch (_: Exception) { if (current()) cancelSuccessor(preserveAttempt = true) }
            finally {
                try {
                    if (!transferred) withContext(NonCancellable + Dispatchers.IO) { file?.let {owner.releaseUnborrowed(it)} }
                } finally {
                    // Returning from NonCancellable IO to a revoked job can throw
                    // again. That must not strand the retained acquisition handle.
                    if (successorJob === currentCoroutineContext()[Job]) successorJob = null
                }
            }
        }
        job.invokeOnCompletion { preparing.decrementAndGet() }
        successorJob = job; tail = job; job.start()
    }

    /** Native gains and cursors, never a UI/poll gain scheduler. Returns true on EOF handoff. */
    private fun observeSuccessor(snapshot: NativeCallbackSnapshot): Boolean {
        val c = successor ?: return false
        if (!successorCurrent(c)) { intent = false; retireSelection(); playback = Player.STATE_IDLE; return true }
        val a = snapshot.decks.getOrNull(c.outgoingDeck) ?: return false
        val b = snapshot.decks.getOrNull(c.deck) ?: return false
        if (a.identity != c.outgoingIdentity || b.identity != c.identity || a.generation != c.outgoingIdentity || b.generation != c.identity) return false
        if (b.error != 0) { cancelSuccessor(preserveAttempt = true); return false }
        if (!c.armed && !c.arming && b.ready && a.ready && a.eofCount == c.outgoingEof) {
            val preference = graph.crossfadePreferences.state.value
            if (!preference.ready || preference.error || preference.seconds == 0) { cancelSuccessor(); return false }
            val length = minOf(preference.seconds * 1000L, a.durationMs / 2, b.durationMs / 2)
            if (length <= 0) { cancelSuccessor(preserveAttempt = true); return false }
            c.arming = true
            val generation = epoch; val revision = successorRevision
            lifetime.launch {
                val accepted = owner.crossfade(c.outgoingDeck, c.outgoingIdentity, c.deck, c.identity, length) {
                    !released && epoch == generation && successorRevision == revision && successorCurrent(c)
                }
                if (successor === c) { c.arming = false; c.armed = accepted }
            }
        }
        if (!c.armed) return false
        // Native installs an overlap only from incoming cursor zero. A resumed successor whose seek
        // landed first keeps both gains at 1; it stays paused until the outgoing EOF handoff below.
        val overlap = a.boundaryGain < 1.0 || b.boundaryGain < 1.0
        if (overlap && (b.playing || b.positionMs > 0) && b.boundaryGain >= a.boundaryGain - 1e-12 && ordinaryDeck != c.deck) {
            index = items.indexOfFirst { it.mediaId == c.item.mediaId }
            if (index < 0) { intent = false; retireSelection(); return true }
            ordinaryDeck = c.deck; ordinaryIdentity = c.identity; activeGrant = c.grant; activeUri = c.uri
            position = b.positionMs; eofCount = b.eofCount
        }
        if (a.eofCount <= c.outgoingEof) return false
        val generation = epoch; val revision = transportRevision
        // Completion is the outgoing occurrence's exact native EOF, not selection midpoint.
        val callbacks = if (c.completed) emptyList() else completions.toList()
        c.completed = true
        for (callback in callbacks) {
            if (generation != epoch || revision != transportRevision || successor !== c) return true
            callback(c.outgoing)
        }
        if (generation != epoch || revision != transportRevision || successor !== c) return true
        index = items.indexOfFirst { it.mediaId == c.item.mediaId }
        ordinaryDeck = c.deck; ordinaryIdentity = c.identity; activeGrant = c.grant; activeUri = c.uri
        durations[c.item.mediaId] = b.durationMs
        position = b.positionMs; eofCount = b.eofCount; acknowledgedPlaying = b.playing
        playback = if (b.ready) Player.STATE_READY else Player.STATE_BUFFERING
        cancelSuccessor(natural=true) // keeps incoming; releases outgoing only after its unassign receipt
        // The callback can reach outgoing EOF between a readiness observation
        // and arm consumption. Reuse the prepared incoming source in that case;
        // only still-current explicit Play may start it, never Pause/revocation.
        if (intent && b.ready && !b.playing && b.eofCount == 0L) dispatchIntent()
        invalidateState()
        return true
    }
    private var seekRevision = 0L
    private var desiredSeek: Long? = null
    private var submittedSeek: Long? = null
    private var acknowledgedSeekPosition: Long? = null
    private var pausePosition: Long? = null
    private var acknowledgedPausePosition: Long? = null
    private var modeRestored = false
    private var volume = 1f
    private val durations = mutableMapOf<String, Long>()
    private val completions = mutableListOf<(MediaItem) -> Unit>()
    @Volatile private var epoch = 1L
    @Volatile private var released = false
    @Volatile private var transportRevision = 0L
    private var pending: Job? = null
    private var tail: Job? = null
    private val preparing = AtomicInteger()
    // Intentionally not a child of service jobs. Cancellation may revoke IO, never native close.
    private val lifetime = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val owner = NativeCallbackOwner(calls, ::observe,graph.phoneAudio::originalDescriptorsDrained)
    private val journal = NativeListeningJournal(graph,lifetime)
    private var explicitSeek=0L

    // ---- Ordinary listening speed (never arrangement tempo/BPM) ----
    /** Service-owned per-track preference consulted at each ordinary deck load. */
    var speedFor: (MediaItem) -> Double = { 1.0 }
    var onSpeedChanged: (() -> Unit)? = null
    private var speedBounds = 1.0 to 1.0
    internal val listeningSpeedBounds get() = speedBounds
    /** Explicit original-file mutation barrier. It grants no filesystem deletion authority. */
    internal suspend fun retirePhoneFile(ref:com.soundq.android.playback.PlaybackRef.Device):Boolean {
        fun matches(item:MediaItem)=(com.soundq.android.playback.PlaybackRef.read(item.mediaMetadata.extras?.getString("playbackRef")) as? com.soundq.android.playback.PlaybackRef.Device)?.let {graph.phoneAudio.sameFile(it,ref)}==true
        if(arrangement!=null&&arrangementSourceItems.any(::matches))return false
        val fileId=graph.phoneAudio.sourceFileId(ref).value.toString()
        // A previously failed close can retain custody without a native identity or queue row.
        if(items.none(::matches))return owner.sourcesDrained(fileId)
        val acquisition=if(selected()?.let(::matches)==true)pending else null
        val nextAcquisition=successorJob
        val identities=mutableSetOf<Long>()
        if(selected()?.let(::matches)==true)identities+=ordinaryIdentity
        successor?.let {if(matches(it.item))identities+=it.identity;if(matches(it.outgoing))identities+=it.outgoingIdentity}
        if(selected()?.let(::matches)==true) {pause();stop()}
        val remaining=items.filterNot(::matches)
        val fallback=index.coerceIn(0,(remaining.size-1).coerceAtLeast(0))
        mutate(remaining,rebuilt(remaining,fallback),fallback,selected()?.let(::matches)!=true)
        invalidateState()
        return withTimeoutOrNull(30_000) {
            acquisition?.join();nextAcquisition?.join();tail?.join()
            val snapshot=owner.snapshot {true} ?: return@withTimeoutOrNull false
            snapshot.decks.none {it.identity in identities} && owner.sourcesDrained(fileId)
        }==true
    }
    /** Set when the native capability first arrives (or changes): a deck loaded before it
     * could only start at 1.0, so the selected source re-applies its stored speed once. */
    private var reconcileSpeed = false
    private var observedSpeed: Pair<Long, Double>? = null // ordinary deck identity -> applied engine rate
    private class SpeedRequest(val occurrence: String, val speed: Double, val done: (Boolean) -> Unit) {
        var submittedIdentity = 0L
        var finished = false
        fun finish(ok: Boolean) { if (!finished) { finished = true; done(ok) } }
    }
    private var speedRequest: SpeedRequest? = null
    private var speedDeadline: Job? = null
    private fun loadSpeed(item: MediaItem): Double {
        val (min, max) = speedBounds
        // Jam occurrences follow the shared party clock; never a private listening pace.
        if (item.mediaMetadata.extras?.getString("soundqJam") != null) return 1.0
        val wanted = runCatching { speedFor(item) }.getOrDefault(1.0)
        // Before the first native capability report only normal speed is admissible.
        return if (wanted.isFinite() && (wanted == 1.0 || (min < 1.0 && max > 1.0 && wanted in min..max))) wanted else 1.0
    }
    private fun retireSpeedRequest() {
        val request = speedRequest ?: return
        speedRequest = null; speedDeadline?.cancel(); speedDeadline = null
        request.finish(false)
    }
    /** Accepted speed for the selected occurrence: the native deck's applied rate once its
     * source is assigned, otherwise the stored preference that will apply at load. */
    internal fun listeningSpeed(): com.soundq.android.playback.ListeningSpeedState? {
        val item = selected() ?: return null
        val (min, max) = speedBounds
        val reason = when {
            arrangement != null -> com.soundq.android.playback.ListeningSpeedUnavailable.Arrangement
            item.mediaMetadata.extras?.getString("soundqJam") != null -> com.soundq.android.playback.ListeningSpeedUnavailable.Jam
            !(min < 1.0 && max > 1.0) -> com.soundq.android.playback.ListeningSpeedUnavailable.Source
            else -> null
        }
        val applied = observedSpeed?.takeIf { selectedLoaded && it.first == ordinaryIdentity && arrangement == null }?.second
        return com.soundq.android.playback.ListeningSpeedState(item.mediaId, if (reason != null && arrangement != null) 1.0 else applied ?: loadSpeed(item), min, max, reason)
    }
    /** One latest-wins request for exactly [occurrence]. Completion is the native applied-rate
     * receipt (or, with no assigned source, acceptance of the preference for its next load).
     * A selection change, refusal or timeout completes false and changes nothing audible. */
    internal fun requestSpeed(occurrence: String, speed: Double, done: (Boolean) -> Unit) {
        retireSpeedRequest()
        val item = selected()
        val state = listeningSpeed()
        if (released || item == null || item.mediaId != occurrence || state == null || state.unavailable != null ||
            !speed.isFinite() || speed !in state.min..state.max || !currentScope()) { done(false); return }
        val request = SpeedRequest(occurrence, speed, done)
        if (!selectedLoaded && pending == null) { request.finish(true); return } // applies at next load
        speedRequest = request
        speedDeadline = lifetime.launch { delay(8_000); if (speedRequest === request) retireSpeedRequest() }
    }
    /** Called after an accepted preference change; a prepared successor of the same track
     * must not start at its stale speed. */
    internal fun speedPreferenceChanged() {
        val c = successor ?: return
        if (loadSpeed(c.item) != c.speed) cancelSuccessor()
    }
    private fun observeSpeed(deck: NativeCallbackDeck) {
        val previous = observedSpeed
        if (reconcileSpeed && speedRequest == null && deck.ready && arrangement == null) {
            reconcileSpeed = false
            selected()?.let { item ->
                val wanted = loadSpeed(item)
                if (deck.speed != wanted) requestSpeed(item.mediaId, wanted) { invalidateState(); onSpeedChanged?.invoke() }
            }
        }
        if (deck.rate.isFinite() && deck.rate > 0 && !deck.scratching) observedSpeed = ordinaryIdentity to deck.rate
        val request = speedRequest
        if (request != null) {
            if (selected()?.mediaId != request.occurrence) retireSpeedRequest()
            else if (deck.ready && deck.speed == request.speed && deck.rate == request.speed) {
                speedRequest = null; speedDeadline?.cancel(); speedDeadline = null; request.finish(true)
            } else if (deck.ready && request.submittedIdentity != ordinaryIdentity) {
                request.submittedIdentity = ordinaryIdentity
                val generation = epoch; val identity = ordinaryIdentity; val slot = ordinaryDeck
                lifetime.launch {
                    val admitted = owner.controlDeck(slot, 10, request.speed) {
                        !released && generation == epoch && identity == ordinaryIdentity && speedRequest === request
                    }
                    if (!admitted && speedRequest === request) retireSpeedRequest()
                }
            }
        }
        if (previous != observedSpeed) { invalidateState(); onSpeedChanged?.invoke() }
    }
    val nativeReleased get() = owner.released
    val preparationSettled get() = preparing.get() == 0
    @JvmName("nativeDiagnostics")
    internal fun nativeDiagnostics(): String = owner.diagnostics
    internal fun nativeTraversalForTest(): List<Int> = order.toList()
    private val accountJob = jobs.launch {
        combine(graph.session.state, graph.session.scopeRevision) { state, _ -> state }.collect { auth ->
            val scope = queueScope
            if(items.isNotEmpty()&&scope==null&&!graph.phoneAudio.current(queueVersion)){clearQueue();invalidateState()}
            if (items.isNotEmpty() && scope != null && !graph.session.current(scope)) {
                if (auth is AuthState.LocalLocked || graph.session.resumesLocal(scope)) {
                    retireSelection()
                    intent = false
                    playback = Player.STATE_IDLE
                    if (graph.session.resumesLocal(scope)) queueScope = graph.session.capture()
                } else clearQueue()
                invalidateState()
            }
        }
    }

    @Volatile var performanceDecks: Map<String, PerformanceDeck> = emptyMap()
        private set
    var onPerformanceChanged: (() -> Unit)? = null
    private var performanceIdentity: ArrangementIdentity? = null
    private class CapturedSync(val qualified: () -> Boolean) {
        var unlinkAdmitted = false
    }
    private val syncQualifications = mutableMapOf<String, CapturedSync>()
    internal fun syncRetirementObserved(identity: ArrangementIdentity, incoming: String): Boolean =
        performanceIdentity == identity && incoming !in syncQualifications &&
            performanceDecks[incoming]?.let { it.target.identity == identity && it.syncState == LiveSyncState.Off } == true
    @Volatile private var performanceLifetime = 0L
    @Volatile private var performanceTransportHeld = false
    internal fun retirePerformanceTransport() {
        performanceTransportHeld = true
        revokePerformance()
        performanceDecks = emptyMap()
        onPerformanceChanged?.invoke()
    }
    /** One service-owned transaction. Native schedule stays immutable across durable revision adoption. */
    private class CapturedTempo(val lease: TempoPreviewLease, val epoch: Long, val schedule: Long,
        val document: TimelineDocument, val grants: Map<String, MediaGrant>, val qualified: () -> Boolean,
        val callerCurrent: () -> Boolean) {
        var reservation: NativeTempoReservation? = null
        var state = TempoPreviewState(lease)
        var closed = false
        var latest: Pair<Double, Long>? = null
        var pump: Job? = null
        var terminal: Job? = null
        var deadline: Job? = null
    }
    private var tempoPreview: CapturedTempo? = null
    private var durablePerformanceDocument: TimelineDocument? = null
    internal var tempoPreviewState: TempoPreviewState? = null
        private set
    private fun publishTempo(c: CapturedTempo, next: TempoPreviewState) {
        c.state = next
        if (tempoPreview === c) { tempoPreviewState = next; onPerformanceChanged?.invoke() }
    }
    private fun tempoOwnerCurrent(c: CapturedTempo): Boolean = tempoPreview === c && !released && epoch == c.epoch &&
        arrangement?.revision == c.schedule && performanceIdentity == c.lease.target.identity &&
        performanceLifetime == c.lease.transport && assignmentCurrent() && c.qualified() && c.callerCurrent() &&
        c.grants.all { (uri, grant) -> grants[uri] === grant && grant.current(graph) }
    internal suspend fun beginTempo(target: PerformanceTarget, source: TempoSourceIdentity, qualified: () -> Boolean,
        current: () -> Boolean): TempoPreviewLease? {
        val active = arrangement ?: return null
        val document = durablePerformanceDocument ?: active.document
        val deck = readyDeck(target.occurrence) ?: return null
        val clip = document.clips.singleOrNull { it.occurrence == target.occurrence } ?: return null
        if (!canPerform(target.identity) || !intent || !deck.playing || tempoPreview != null || scratch != null ||
            !qualified() || !current() || source.occurrence != clip.occurrence || source.track != clip.track ||
            source.durationMs != clip.sourceDurationMs || !source.supportsTempoOnly() || deck.scratching ||
            deck.syncState != LiveSyncState.Off || document.phaseLink?.contains(clip.occurrence) == true ||
            document.tempoRamps.any { it.outgoing.occurrence == clip.occurrence || it.incoming.occurrence == clip.occurrence } ||
            clip.rates.segments.isNotEmpty()) return null
        val origin = deck.effectiveBpm ?: (deck.rate * source.sourceBpm)
        if (!origin.isFinite() || origin !in 10.0..600.0 || origin / source.sourceBpm !in 0.8..1.5) return null
        val lease = TempoPreviewLease(target, java.util.UUID.randomUUID().toString(), performanceLifetime, source, origin)
        val c = CapturedTempo(lease, epoch, active.revision, document, arrangementGrants.toMap(), qualified, current)
        tempoPreview = c // serialize competing Begin while native claims headroom
        val beginJob = currentCoroutineContext()[Job]
        val reservation = withContext(NonCancellable) {
            owner.reserveTempo(c.schedule, instance(target.occurrence) ?: 0, source.sourceBpm, origin) { beginJob?.isActive != false && tempoOwnerCurrent(c) }
        }
        c.reservation = reservation
        if (reservation == null || beginJob?.isActive == false || !tempoOwnerCurrent(c)) {
            if (tempoPreview === c) tempoPreview = null
            reservation?.finished = true
            reservation?.let { withContext(NonCancellable) { owner.releaseTempo(it) { !released && epoch == c.epoch && arrangement?.revision == c.schedule && c.callerCurrent() } } }
            return null
        }
        publishTempo(c, c.state)
        return lease
    }
    internal fun previewTempo(lease: TempoPreviewLease, revision: Long, bpm: Double, glideMs: Long): Boolean {
        val c = tempoPreview ?: return false
        if (c.lease != lease || c.closed || !tempoOwnerCurrent(c) || revision <= c.state.revision ||
            !bpm.isFinite() || bpm !in 10.0..600.0 || bpm / lease.source.sourceBpm !in 0.8..1.5 || glideMs !in 0..10_000) return false
        publishTempo(c, c.state.copy(revision = revision, desiredTag = 0, desiredBpm = bpm, phase = TempoPreviewPhase.Preparing, message = null))
        c.latest = bpm to glideMs
        if (c.pump?.isActive != true) c.pump = lifetime.launch {
            while (!c.closed && tempoOwnerCurrent(c)) {
                val next = c.latest ?: break
                c.latest = null
                val request = c.state.revision
                val tag = owner.liveTempo(c.schedule, instance(lease.target.occurrence) ?: break,
                    lease.source.sourceBpm, next.first, next.second, c.reservation ?: break) { !c.closed && tempoOwnerCurrent(c) && c.state.revision == request }
                if (c.closed || !tempoOwnerCurrent(c)) break
                if (c.state.revision == request) publishTempo(c, c.state.copy(desiredTag = tag ?: 0,
                    phase = if (tag == null) TempoPreviewPhase.Refused else TempoPreviewPhase.Preparing,
                    message = if (tag == null) "Live BPM refused. No BPM was saved. Try another value or Cancel." else null))
            }
        }
        return true
    }
    private fun observeTempo(snapshot: NativeCallbackSnapshot) {
        val c = tempoPreview ?: return
        if (!tempoOwnerCurrent(c)) { retireTempo("Preview retired because its source, account or transport changed."); return }
        val tag = c.state.desiredTag
        if (tag == 0L) return
        val deck = snapshot.decks.singleOrNull { it.identity == instance(c.lease.target.occurrence) && it.generation == c.schedule }
        if (snapshot.scheduleRevision != c.schedule) return
        if (snapshot.tempoRefused == tag) publishTempo(c, c.state.copy(phase = TempoPreviewPhase.Refused,
            message = "Native rendering refused this BPM. No BPM was saved. Cancel to restore."))
        else if (snapshot.tempoApplied == tag && deck?.tempoGeneration == tag && deck.effectiveBpm.isFinite()) {
            val reached = kotlin.math.abs(deck.effectiveBpm - c.state.desiredBpm) < 0.00001
            val phase = if (reached && !c.closed) TempoPreviewPhase.Applied else c.state.phase
            publishTempo(c, c.state.copy(appliedTag = tag, appliedBpm = deck.effectiveBpm, phase = phase))
        }
    }
    private suspend fun awaitTempo(c: CapturedTempo): Boolean = withTimeoutOrNull(8_000) {
        while (tempoOwnerCurrent(c)) {
            if (c.state.phase == TempoPreviewPhase.Refused) return@withTimeoutOrNull false
            if (c.state.desiredTag > 0 && c.state.appliedTag == c.state.desiredTag &&
                kotlin.math.abs(c.state.appliedBpm - c.state.desiredBpm) < 0.00001) return@withTimeoutOrNull true
            delay(20)
        }
        false
    } ?: false
    /** Close is revocable by Cancel while waiting for native receipt, never by late motion. */
    internal fun saveTempo(lease: TempoPreviewLease, revision: Long, commit: suspend (Double, () -> Boolean) -> TimelineDocument?,
        done: (TimelineDocument?) -> Unit) {
        val completed = java.util.concurrent.atomic.AtomicBoolean(false)
        val reply: (TimelineDocument?) -> Unit = { if(completed.compareAndSet(false,true)) done(it) }
        val c = tempoPreview
        if (c == null || c.lease != lease || c.closed || c.state.revision != revision || !tempoOwnerCurrent(c)) { reply(null); return }
        // Drain the one latest target before closing motion. No coroutine cancellation owns cleanup.
        tempoDeadline(c) { reply(null) }
        c.closed = true
        val pendingTarget = c.latest; c.latest = null
        c.terminal = lifetime.launch {
            c.pump?.join()
            if (!tempoOwnerCurrent(c) || c.state.phase == TempoPreviewPhase.Restoring) { reply(null); return@launch }
            if (pendingTarget != null || c.state.desiredTag == 0L) {
                val target = pendingTarget ?: (c.state.desiredBpm to 0L)
                val tag = owner.liveTempo(c.schedule, instance(lease.target.occurrence) ?: 0,
                    lease.source.sourceBpm, target.first, target.second, requireNotNull(c.reservation)) { tempoOwnerCurrent(c) && c.state.phase != TempoPreviewPhase.Restoring }
                publishTempo(c, c.state.copy(desiredTag = tag ?: 0, phase = if (tag == null) TempoPreviewPhase.Refused else TempoPreviewPhase.Saving))
            } else publishTempo(c, c.state.copy(phase = TempoPreviewPhase.Saving))
            if (!awaitTempo(c) || c.state.phase == TempoPreviewPhase.Restoring) {
                if (tempoPreview === c && c.state.phase != TempoPreviewPhase.Restoring) {
                    c.deadline?.cancel(); c.closed = false; publishTempo(c, c.state.copy(phase = TempoPreviewPhase.Refused, message = "BPM was not saved. Native application did not complete. Cancel to restore."))
                }
                reply(null); return@launch
            }
            val accepted = commit(c.state.desiredBpm) { tempoPreview === c && tempoOwnerCurrent(c) && c.state.phase == TempoPreviewPhase.Saving }
            if (accepted != null && tempoPreview === c && tempoOwnerCurrent(c)) {
                // No suspension between the durable write and identity adoption.
                // This capability may now release headroom, never restore audio.
                c.reservation?.finished = true
                c.reservation?.let { reservation -> lifetime.launch {
                    owner.releaseTempo(reservation) { tempoOwnerCurrent(c) }
                } }
                durablePerformanceDocument = accepted
                performanceIdentity = lease.target.identity.copy(revision = accepted.revision)
                publishTempo(c, c.state.copy(phase = TempoPreviewPhase.Saved, message = "BPM saved. Playback continues."))
                c.deadline?.cancel(); tempoPreview = null
                reply(accepted)
            } else {
                c.deadline?.cancel(); c.closed = false; publishTempo(c, c.state.copy(phase = TempoPreviewPhase.Applied, message = "BPM is live only. Save failed; prior saved arrangement is unchanged. Retry or Cancel to restore.")); reply(null)
            }
        }
        c.terminal?.invokeOnCompletion { cause -> if (cause != null) reply(null) }
    }
    internal fun cancelTempo(lease: TempoPreviewLease, done: (Boolean) -> Unit = {}) {
        val completed = java.util.concurrent.atomic.AtomicBoolean(false)
        val reply: (Boolean) -> Unit = { if(completed.compareAndSet(false,true)) done(it) }
        val c = tempoPreview
        if (c == null || c.lease != lease) { reply(false); return }
        if (c.state.phase == TempoPreviewPhase.Restoring) { reply(false); return }
        c.closed = true; c.latest = null
        c.terminal?.cancel() // Cancel revokes a waiting Save before it may publish or persist.
        publishTempo(c, c.state.copy(revision = c.state.revision + 1, desiredTag = 0, desiredBpm = lease.originBpm,
            phase = TempoPreviewPhase.Restoring, message = "Restoring accepted BPM…"))
        tempoDeadline(c) { reply(false) }
        lifetime.launch {
            c.pump?.join()
            val tag = c.reservation?.let { owner.restoreTempo(it) { tempoOwnerCurrent(c) && tempoPreview === c && c.state.phase == TempoPreviewPhase.Restoring } }
            if (tempoPreview !== c) { reply(false); return@launch }
            publishTempo(c, c.state.copy(desiredTag = tag ?: 0))
            val restored = tag != null && awaitTempo(c)
            c.reservation?.finished = true
            if (tempoPreview === c) {
                publishTempo(c, c.state.copy(phase = if (restored) TempoPreviewPhase.Restored else TempoPreviewPhase.Retired,
                    message = if (restored) "Accepted BPM restored." else "Restore did not complete. Saved arrangement is unchanged; playback may retain the live BPM."))
                c.deadline?.cancel(); tempoPreview = null
            }
            reply(restored)
        }
    }
    private fun tempoDeadline(c: CapturedTempo, complete: () -> Unit) {
        c.deadline?.cancel()
        c.deadline = lifetime.launch {
            delay(10_000)
            if (tempoPreview === c) {
                retireTempo("Live BPM completion timed out. Saved arrangement is unchanged; playback may retain the live BPM.")
                complete()
            }
        }
    }
    private fun retireTempo(message: String) {
        val c = tempoPreview ?: return
        c.closed = true; c.latest = null; c.deadline?.cancel(); c.terminal?.cancel()
        c.reservation?.finished = true
        publishTempo(c, c.state.copy(phase = TempoPreviewPhase.Retired, message = message))
        tempoPreview = null
        c.reservation?.let { reservation -> lifetime.launch {
            owner.releaseTempo(reservation) { !released && epoch == c.epoch && arrangement?.revision == c.schedule && c.callerCurrent() }
        } }
    }
    internal fun cancelOwnedTempo() { tempoPreview?.let { cancelTempo(it.lease) } }

    private var gestureSequence = 0L
    private var lastScratchEvent = 0L
    @Volatile private var scratch: CapturedScratch? = null
    private class CapturedScratch(val lease: ScratchLease, val instance: Long, val epoch: Long, val grants: Map<String, MediaGrant>) {
        @Volatile var terminal = false
        @Volatile var admitted = false
        var event = 0L
    }
    internal suspend fun sourceReturn(identity: ArrangementIdentity, current: () -> Boolean): Pair<String, Long>? {
        val active = arrangement ?: return null
        val generation = epoch
        val snapshot = owner.snapshot { !released && generation == epoch && performanceIdentity == identity && assignmentCurrent() && current() } ?: return null
        if (snapshot.scheduleRevision != active.revision || generation != epoch || !current()) return null
        val global = snapshot.globalPositionMs
        val running = snapshot.decks.firstOrNull { deck ->
            val clip = active.document.clips.getOrNull((deck.identity - 1).toInt())
            clip != null && deck.generation == active.revision && !snapshot.scheduleEnded && deck.ready &&
                deck.sourceFrame.isFinite() && deck.sourceRate > 0 &&
                deck.sourceFrame < minOf(deck.sourceFrames.toDouble(), clip.sourceOutMs * deck.sourceRate / 1000.0) &&
                (deck.playing || deck.tempoGeneration > 0)
        }
        val clip = running?.let { active.document.clips[(it.identity - 1).toInt()] }
            ?: active.document.clips.firstOrNull { global >= it.globalStartMs && global < it.globalEndMs }
        if (clip == null) {
            if (snapshot.scheduleEnded || snapshot.scheduleDurationMs > 0 && global >= snapshot.scheduleDurationMs) {
                val last = active.document.clips.maxByOrNull { it.globalEndMs } ?: return null
                return last.occurrence to last.sourceOutMs
            }
            return null
        }
        val ordinal = active.document.clips.indexOf(clip) + 1L
        val deck = snapshot.decks.singleOrNull { it.identity == ordinal && it.generation == active.revision } ?: return null
        if (!deck.sourceFrame.isFinite() || deck.sourceRate <= 0) return null
        return clip.occurrence to (deck.sourceFrame * 1000.0 / deck.sourceRate).toLong().coerceIn(clip.sourceInMs, clip.sourceOutMs)
    }
    internal fun bindPerformance(identity: ArrangementIdentity) {
        check((durablePerformanceDocument ?: arrangement?.document)?.revision == identity.revision && selected()?.mediaId == identity.install)
        performanceIdentity = identity
    }
    internal fun canPerform(identity: ArrangementIdentity): Boolean = !released && performanceIdentity == identity &&
        !performanceTransportHeld && selectedLoaded && arrangement != null && assignmentCurrent() && desiredSeek == null && playback == Player.STATE_READY
    private fun performanceCurrent(capture: CapturedScratch): Boolean = !released && capture.epoch == epoch &&
        capture.lease.transport == performanceLifetime && performanceIdentity == capture.lease.target.identity &&
        capture.grants.all { (uri, grant) -> grants[uri] === grant && grant.current(graph) } && assignmentCurrent()
    private fun instance(occurrence: String): Long? = arrangement?.document?.clips?.indexOfFirst { it.occurrence == occurrence }
        ?.takeIf { it >= 0 }?.let { it + 1L }
    private fun readyDeck(occurrence: String): PerformanceDeck? = performanceDecks[occurrence]?.takeIf {
        it.target.identity == performanceIdentity && it.ready && it.sourcePositionMs.isFinite() && it.rate.isFinite()
    }
    private fun validEvent(event: Long): Boolean {
        val now = android.os.SystemClock.uptimeMillis() * 1_000_000L
        return event > 0 && event > lastScratchEvent && event <= now + 1_000_000L && now - event <= 2_000_000_000L
    }
    internal fun beginScratch(target: PerformanceTarget, eventNanos: Long, current: () -> Boolean, done: (ScratchLease?) -> Unit) {
        if (!current() || !canPerform(target.identity) || scratch != null || tempoPreview != null || !validEvent(eventNanos)) return done(null)
        val deck = readyDeck(target.occurrence) ?: return done(null)
        if (deck.keylock || deck.scratching || performanceDecks.values.any { it.syncReferenceOccurrence == target.occurrence && it.syncState !in listOf(LiveSyncState.Off, LiveSyncState.Failed) }) return done(null)
        val nativeInstance = instance(target.occurrence) ?: return done(null)
        check(gestureSequence < Long.MAX_VALUE)
        val lease = ScratchLease(target, ++gestureSequence, java.util.UUID.randomUUID().toString(), performanceLifetime)
        val capture = CapturedScratch(lease, nativeInstance, epoch, arrangementGrants.toMap()).also { it.event = eventNanos }
        scratch = capture; lastScratchEvent = eventNanos
        owner.offerScratch(1, nativeInstance, lease.id, eventNanos, 0.0, { performanceCurrent(capture) && !capture.terminal && current() }) { accepted ->
            capture.admitted = accepted
            if (accepted && scratch === capture && !capture.terminal && performanceCurrent(capture) && current()) done(lease)
            else { if (scratch === capture) revokePerformance(); done(null) }
        }
    }
    internal fun moveScratch(lease: ScratchLease, rate: Double, eventNanos: Long): Boolean {
        val capture = scratch ?: return false
        if (capture.lease != lease || capture.terminal || !capture.admitted || !performanceCurrent(capture) ||
            !rate.isFinite() || rate !in -8.0..8.0 || !validEvent(eventNanos) || eventNanos <= capture.event) return false
        capture.event = eventNanos; lastScratchEvent = eventNanos
        owner.offerScratch(2, capture.instance, lease.id, eventNanos, rate, { performanceCurrent(capture) && !capture.terminal })
        return true
    }
    internal fun finishScratch(lease: ScratchLease, eventNanos: Long, cancel: Boolean): Boolean {
        val capture = scratch ?: return false
        if (capture.lease != lease || capture.terminal || !performanceCurrent(capture)) return false
        val now = android.os.SystemClock.uptimeMillis() * 1_000_000L
        if (eventNanos > now + 1_000_000L) return false
        // Terminals express causal cleanup, not motion. Equal-ms Up/coroutine Cancel
        // must follow the last accepted Move even when its physical event is old.
        val terminalEvent = if (validEvent(eventNanos) && eventNanos > capture.event) eventNanos
            else maxOf(now, lastScratchEvent + 1, capture.event + 1)
        if (!validEvent(terminalEvent)) return false
        capture.terminal = true; lastScratchEvent = terminalEvent
        // Dispatch still checks captured lifetime, not the mutable active-gesture pointer.
        owner.offerScratch(if (cancel) 4 else 3, capture.instance, lease.id, terminalEvent, 0.0, { performanceCurrent(capture) }) { accepted ->
            if (scratch === capture) {
                if (!accepted && performanceCurrent(capture)) revokePerformance()
                else scratch = null
            }
        }
        return true
    }
    /** Called synchronously at transport/lifecycle admission, before queued JNI can resume. */
    internal fun revokePerformance() {
        retireTempo("Preview retired by transport or playback lifecycle. Saved arrangement is unchanged.")
        val capture = scratch
        scratch = null; capture?.terminal = true
        performanceLifetime++
        if (capture != null) {
            val event = maxOf(android.os.SystemClock.uptimeMillis() * 1_000_000L, capture.event + 1)
            lastScratchEvent = maxOf(lastScratchEvent, event)
            // Reliable cancellation targets only this native immutable schedule. Never a successor.
            owner.offerScratch(4, capture.instance, capture.lease.id, event, 0.0,
                { !released && epoch == capture.epoch && arrangement != null })
        }
    }
    internal suspend fun syncIncoming(identity: ArrangementIdentity, reference: String, incoming: String, beats: Int,
        referenceGrid: QualifiedLiveGrid, incomingGrid: QualifiedLiveGrid, qualified: () -> Boolean = { true }, current: () -> Boolean): Boolean {
        if (!current() || !canPerform(identity) || reference == incoming || scratch != null || tempoPreview != null || incoming in syncQualifications) return false
        val a = readyDeck(reference) ?: return false
        val b = readyDeck(incoming) ?: return false
        if (a.keylock || b.keylock || a.scratching || b.scratching || a.rate <= 0 || a.syncState in listOf(LiveSyncState.Pending, LiveSyncState.Rejoining, LiveSyncState.ScratchSuspended)) return false
        val document = arrangement?.document ?: return false
        val ca = document.clips.singleOrNull { it.occurrence == reference } ?: return false
        val cb = document.clips.singleOrNull { it.occurrence == incoming } ?: return false
        if (!referenceGrid.valid(ca.sourceDurationMs, beats) || !incomingGrid.valid(cb.sourceDurationMs, beats)) return false
        val ratio = a.rate * referenceGrid.bpm / incomingGrid.bpm
        if (!ratio.isFinite() || ratio !in 0.25..4.0) return false
        // Native rejects cycles too; retain a cheap exact occurrence check here.
        var next: String? = reference
        val seen = mutableSetOf(incoming)
        while (next != null) { if (!seen.add(next)) return false; next = performanceDecks[next]?.syncReferenceOccurrence }
        val generation = epoch; val lifetime = performanceLifetime
        val nativeIncoming = instance(incoming) ?: return false
        val nativeReference = instance(reference) ?: return false
        // Claim before suspending: neither another controller nor an unobserved
        // native ACK may reconfigure this installed incoming.
        val capture = CapturedSync(qualified)
        syncQualifications[incoming] = capture
        val accepted = owner.sync(nativeIncoming, nativeReference, beats, referenceGrid, incomingGrid) {
            current() && qualified() && generation == epoch && lifetime == performanceLifetime && canPerform(identity)
        }
        if (epoch != generation || syncQualifications[incoming] !== capture) return false
        if (!accepted) syncQualifications.remove(incoming)
        return accepted
    }
    internal fun revokePerformanceTarget(identity: ArrangementIdentity, occurrence: String) {
        if (performanceIdentity == identity) {
            performanceDecks = performanceDecks - occurrence
            scratch?.takeIf { it.lease.target.occurrence == occurrence }?.let { revokePerformance() }
        }
    }
    internal suspend fun unlinkForRetirement(identity: ArrangementIdentity, incoming: String, current: () -> Boolean): Boolean {
        val generation = epoch
        val capture = syncQualifications[incoming] ?: return false
        val accepted = owner.sync(instance(incoming) ?: return false, 0, 0, null, null) {
            !released && generation == epoch && performanceIdentity == identity && syncQualifications[incoming] === capture && assignmentCurrent() && current()
        }
        if (accepted && generation == epoch && syncQualifications[incoming] === capture) capture.unlinkAdmitted = true
        return accepted
    }
    internal suspend fun unlinkIncoming(identity: ArrangementIdentity, incoming: String, current: () -> Boolean): Boolean {
        if (!current() || !canPerform(identity) || readyDeck(incoming) == null) return false
        val generation = epoch; val lifetime = performanceLifetime
        val capture = syncQualifications[incoming] ?: CapturedSync { true }.also { syncQualifications[incoming] = it }
        val accepted = owner.sync(instance(incoming) ?: return false, 0, 0, null, null) {
            current() && generation == epoch && lifetime == performanceLifetime && syncQualifications[incoming] === capture && canPerform(identity)
        }
        if (accepted && generation == epoch && syncQualifications[incoming] === capture) capture.unlinkAdmitted = true
        return accepted
    }
    private fun publishPerformance(snapshot: NativeCallbackSnapshot, active: NativeCallbackArrangement, notify: Boolean = true) {
        val identity = performanceIdentity ?: return
        val clips = active.document.clips
        performanceDecks = snapshot.decks.asSequence().filter { it.identity in 1..clips.size.toLong() && it.generation == active.revision }
            .mapNotNull { deck ->
                val clip = clips[(deck.identity - 1).toInt()]
                if (snapshot.globalPositionMs < clip.globalStartMs || (deck.tempoGeneration == 0L && snapshot.globalPositionMs >= clip.globalEndMs) ||
                    (deck.tempoGeneration > 0L && (snapshot.scheduleEnded || deck.sourceFrame >= minOf(deck.sourceFrames.toDouble(), clip.sourceOutMs * deck.sourceRate / 1000.0))) ||
                    !deck.sourceFrame.isFinite() || !deck.nominalSourceFrame.isFinite() || !deck.rate.isFinite() || deck.sourceRate <= 0 ||
                    deck.syncState !in 0..5 || !deck.syncPhaseErrorFrames.isFinite()) return@mapNotNull null
                val qualification = syncQualifications[clip.occurrence]
                if (qualification != null) {
                    // JNI admission is not an unlink ACK. Only this installed
                    // native Off observation retires the exact obsolete capture.
                    if (qualification.unlinkAdmitted && deck.syncState == 0 && deck.syncReference == 0L && deck.syncBeats == 0)
                        syncQualifications.remove(clip.occurrence)
                    else if (!qualification.qualified()) return@mapNotNull null
                }
                val reference = clips.getOrNull((deck.syncReference - 1).toInt())?.occurrence.takeIf { deck.syncReference > 0 }
                val ready = deck.ready && deck.error == 0 && !deck.preparing
                clip.occurrence to PerformanceDeck(PerformanceTarget(identity, clip.occurrence), deck.sourceFrame * 1000.0 / deck.sourceRate,
                    deck.rate, deck.nominalSourceFrame * 1000.0 / deck.sourceRate, ready, deck.playing, deck.scratching, deck.gesture, deck.heldZero,
                    reference, deck.syncBeats, if (!ready && deck.syncState == 2) LiveSyncState.Failed else LiveSyncState.entries[deck.syncState],
                    deck.syncPhaseErrorFrames, deck.lastMoveEventNanos, deck.lastMoveAppliedNanos, deck.lastMoveSequence,
                    deck.pitchPreserved,deck.processingEpoch,deck.effectiveBpm.takeIf {it.isFinite()&&it>0},deck.tempoGeneration)
            }.take(4).toMap()
        scratch?.let { if (readyDeck(it.lease.target.occurrence) == null) revokePerformance() }
        if (notify) onPerformanceChanged?.invoke()
    }

    private fun done(): ListenableFuture<*> = Futures.immediateVoidFuture()
    private var queueVersion=-1L
    private fun currentScope() = if(queueScope!=null)queueScope?.let(graph.session::current)==true else graph.phoneAudio.current(queueVersion)
    private fun assignmentCurrent() = currentScope() && if (arrangement != null)
        arrangementGrants.isNotEmpty() && arrangementGrants.all { (uri, grant) -> grants[uri] === grant && grant.current(graph) }
        else activeGrant?.let { grants[activeUri] === it && it.current(graph) } == true
    private fun selected() = items.getOrNull(index)
    private fun activeOrder() = if (shuffle) order else items.indices.toList()
    private fun duration(item: MediaItem): Long = durations[item.mediaId]
        ?: (item.mediaMetadata.extras?.getLong("durationMs") ?: 0L).takeIf { it > 0 }
        ?: C.TIME_UNSET
    private fun bounded(item: MediaItem, value: Long): Long {
        // Local metadata duration is a UI hint until a decoded-EOS seal arrives.
        if(grants[item.localConfiguration?.uri.toString()]?.device!=null && item.mediaId !in durations)
            return value.coerceIn(0,24L*60*60*1000)
        val duration = duration(item)
        return if (duration == C.TIME_UNSET) value.coerceAtLeast(0) else value.coerceIn(0, duration)
    }

    /** Pure complete-queue admission precedes any state change, cancellation or IO. */
    internal fun validateQueueMetadata(next:List<MediaItem>)=validate(next)
    private fun validate(next: List<MediaItem>) {
        require(QueuePolicy.acceptsAppend(0,next.size)) // Full metadata only. Native source residency is unchanged.
        require(next.map { it.mediaId }.toSet().size == next.size) { "Occurrence IDs must be distinct" }
        var scope: AccountScope? = null
        var metadataBytes=0L
        next.forEach { item ->
            val rowBytes=QueuePolicy.metadataBytes(item.mediaId,item.mediaMetadata.title?.toString().orEmpty(),item.mediaMetadata.artist?.toString().orEmpty())
            require(rowBytes<=500_000) // Every durable page must be independently representable.
            metadataBytes+=rowBytes
            require(metadataBytes<=QueuePolicy.MAX_METADATA_BYTES)
            require(item.mediaId.isNotBlank())
            val uri = requireNotNull(item.localConfiguration).uri
            require(uri.scheme in setOf("soundq","soundqdevice")) { "Native callback supports ordinary sources only" }
            val grant = requireNotNull(grants[uri.toString()]) { "Source grant required" }
            if(grant.device==null)check(grant.current(graph))
            if(grant.device==null) {
                if (scope == null) scope = grant.scope
                require(scope.accountId == grant.scope.accountId && scope.epoch == grant.scope.epoch)
            }
            val metadata = requireNotNull(item.mediaMetadata.extras)
            if(grant.device==null) {
                require(metadata.getLong("trackId") == grant.track.value)
                PlaybackRef.read(metadata.getString("playbackRef"))?.let {ref->require(ref is PlaybackRef.Server&&ref.endpoint==graph.endpoint.identity&&ref.account==grant.scope.accountId&&ref.trackId==grant.track)}
            }
            else require(uri.scheme=="soundqdevice"&&PlaybackRef.read(metadata.getString("playbackRef"))==grant.device)
            require(metadata.getBoolean("localOnly") == grant.localOnly)
        }
    }

    override fun getState(): State {
        val commands = Player.Commands.Builder().addAll(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_PREPARE, Player.COMMAND_STOP, Player.COMMAND_RELEASE,
            Player.COMMAND_CHANGE_MEDIA_ITEMS, Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_METADATA, Player.COMMAND_SET_REPEAT_MODE,
            Player.COMMAND_SET_SHUFFLE_MODE, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_MEDIA_ITEM, Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
            Player.COMMAND_GET_VOLUME, Player.COMMAND_SET_VOLUME, Player.COMMAND_GET_AUDIO_ATTRIBUTES,
        ).build()
        val rows = items.map { item ->
            val duration = duration(item)
            MediaItemData.Builder(item.mediaId).setMediaItem(item).setIsSeekable(true)
                .setDurationUs(if (duration == C.TIME_UNSET) C.TIME_UNSET else Math.multiplyExact(duration, 1000)).build()
        }
        val base = State.Builder().setAvailableCommands(commands).setPlaylist(rows)
            .setPlayWhenReady(intent, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackSuppressionReason(if (intent && !acknowledgedPlaying && playback == Player.STATE_READY)
                Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS else Player.PLAYBACK_SUPPRESSION_REASON_NONE)
            .setPlaybackState(playback).setIsLoading(playback == Player.STATE_BUFFERING)
            .setPlayerError(error).setRepeatMode(repeat).setShuffleModeEnabled(shuffle).setVolume(volume)
            // Accepted listening pace only (controllers extrapolate source position with it).
            // COMMAND_SET_SPEED_AND_PITCH is not offered: requests use the receipted service command.
            .setPlaybackParameters(PlaybackParameters((listeningSpeed()?.takeIf { it.unavailable == null }?.accepted ?: 1.0).toFloat()))
            .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build())
        acknowledgedSeekPosition?.let { base.setPositionDiscontinuity(Player.DISCONTINUITY_REASON_SEEK, it) }
        if (acknowledgedSeekPosition == null) acknowledgedPausePosition?.let {
            // Keep the final correction separate from a user Seek.
            base.setPositionDiscontinuity(Player.DISCONTINUITY_REASON_INTERNAL, it)
        }
        acknowledgedSeekPosition = null
        acknowledgedPausePosition = null
        if (items.isNotEmpty()) {
            // Passing Long here makes SimpleBasePlayer extrapolate. Always use a constant supplier.
            val fixed = position
            base.setCurrentMediaItemIndex(index).setContentPositionMs(PositionSupplier { fixed })
                .setContentBufferedPositionMs(PositionSupplier { fixed }).setTotalBufferedDurationMs(PositionSupplier { 0 })
            val built = base.build()
            val sounding = performanceDecks.values.filter { it.playing }.map { it.target.occurrence }.toSet()
            val metadataDocument = arrangement?.document
            val metadata = if (metadataDocument != null && sounding.isNotEmpty()) arrangementMetadata(
                metadataDocument.clips.filter { it.occurrence in sounding }.map { clip ->
                    val names = arrangementSourceItems.firstOrNull { it.mediaId == clip.occurrence }?.mediaMetadata
                    ArrangementMetadataClip(clip.occurrence, names?.title?.toString()?.takeIf { it.isNotBlank() } ?: clip.title,
                        names?.artist?.toString().orEmpty(), 0, Long.MAX_VALUE)
                }, position)
            else metadataDocument?.arrangementMetadata(position) { occurrence ->
                arrangementSourceItems.firstOrNull { it.mediaId == occurrence }?.mediaMetadata?.let {
                    it.title?.toString().orEmpty() to it.artist?.toString().orEmpty()
                }
            }
            // Publish genuine current metadata without replacing the installed row, UID, URI or grants.
            val currentMetadata = metadata?.let { built.currentMetadata.buildUpon().setTitle(it.title).setArtist(it.artist).build() }
                ?: built.currentMetadata
            return built.buildUpon().setPlaylist(TraversalTimeline(built.timeline, activeOrder()), built.currentTracks, currentMetadata).build()
        }
        return base.build()
    }

    /** Acquire/probe a frozen candidate without changing the accepted selection. */
    internal suspend fun prepareArrangement(document: TimelineDocument, sourceItems: List<MediaItem>, current: () -> Boolean): NativeCallbackArrangement {
        validate(sourceItems)
        check(preparedArrangement == null)
        val captured = sourceItems.associate { it.localConfiguration!!.uri.toString() to grants.getValue(it.localConfiguration!!.uri.toString()) }
        val preparationEpoch = epoch
        fun valid() = !released && epoch == preparationEpoch && current() && captured.all { (uri, grant) -> grants[uri] === grant && grant.current(graph) }
        val revision = ++nativeScheduleRevision
        var candidate: NativeCallbackArrangement? = null
        // Settle the prior ordinary acquisition before reserving aggregate bytes.
        tail?.join()
        check(valid())
        // Apply may beat the periodic route-error observation. Retire the old
        // play intent before reopening, so preparing a new draft cannot replay
        // the previously accepted graph on its next healthy READY snapshot.
        val beforeRecovery = owner.snapshot(::valid)
        check(valid())
        if (beforeRecovery == null || beforeRecovery.error != 0) failOutput()
        check(owner.recoverOutput(::valid)) { "Audio output could not be reopened" }
        check(valid())
        outputUnavailable = false; error = null
        val budget = NativeCallbackArrangement.MAX_ENCODED_BYTES - owner.retainedBytes()
        try {
            withContext(NonCancellable + Dispatchers.IO) { candidate = NativeCallbackArrangement.prepare(document, revision, sourceItems, source, budget, ::valid) }
            currentCoroutineContext().ensureActive()
            check(valid())
            check(withContext(NonCancellable) { owner.prepareSchedule(requireNotNull(candidate), revision, ::valid) })
            currentCoroutineContext().ensureActive()
            check(valid())
            return requireNotNull(candidate).also { preparedArrangement = it }
        } catch (failure: Throwable) {
            withContext(NonCancellable) { owner.discardSchedule() }
            withContext(NonCancellable + Dispatchers.IO) { candidate?.close() }
            throw failure
        }
    }
    internal suspend fun discardArrangement(candidate: NativeCallbackArrangement) {
        if (preparedArrangement === candidate) {
            preparedArrangement = null
            withContext(NonCancellable) { owner.discardSchedule() }
            withContext(NonCancellable + Dispatchers.IO) { candidate.close() }
        }
    }
    /** Service commits the single synthetic row only after full encoded/extent admission. */
    internal fun installArrangement(candidate: NativeCallbackArrangement, item: MediaItem, sourceItems: List<MediaItem>) {
        check(preparedArrangement === candidate)
        val captured = sourceItems.associate { it.localConfiguration!!.uri.toString() to grants.getValue(it.localConfiguration!!.uri.toString()) }
        retireSelection()
        preparedArrangement = null
        arrangement = candidate; arrangementGrants = captured; arrangementSourceItems = sourceItems.toList()
        items = listOf(item); order = listOf(0); index = 0; position = 0; intent = false
        queueScope = captured.values.first().scope
        durations[item.mediaId] = candidate.document.clips.maxOf { it.globalEndMs }
        error = null; playback = Player.STATE_BUFFERING
        val generation = epoch
        val predecessor = tail
        preparing.incrementAndGet()
        val job = lifetime.launch(start = CoroutineStart.LAZY) {
            var transferred = false
            try {
                predecessor?.join()
                check(!released && epoch == generation && assignmentCurrent())
                transferred = true
                check(withContext(NonCancellable) { owner.installSchedule(candidate) { !released && epoch == generation && assignmentCurrent() } })
                check(epoch == generation && assignmentCurrent())
                selectedLoaded = true
                // Seek may have arrived while the predecessor's decoder-release
                // receipt held installation. Forward it only to this generation.
                desiredSeek?.let(::seekNative)
                withContext(NonCancellable) { owner.arrangement(7, (volume * 1_000_000).toLong()) { !released && epoch == generation } }
                // READY arrives from the native graph and all target-active binding receipts.
            } catch (_: CancellationException) { }
            catch (_: Exception) { if (epoch == generation) { retireSelection(); fail("Arrangement could not be installed") } }
            finally {
                if (!transferred) { withContext(NonCancellable) { owner.discardSchedule() }; withContext(NonCancellable + Dispatchers.IO) { candidate.close() } }
                if (epoch == generation) { pending = null; if (!released) invalidateState() }
            }
        }
        job.invokeOnCompletion { preparing.decrementAndGet() }
        pending = job; tail = job; job.start()
        invalidateState()
    }

    fun <T> restoringShuffle(enabled: Boolean, action: () -> T): T {
        check(restoredShuffle == null)
        restoredShuffle = enabled
        return try { action() } finally { restoredShuffle = null }
    }

    override fun handleSetMediaItems(mediaItems: List<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
        val next = mediaItems.toList()
        validate(next)
        val selected = if (startIndex == C.INDEX_UNSET) 0 else startIndex
        require(next.isEmpty() || selected in next.indices)
        retireSelection()
        items = next
        if (next.isEmpty()) intent = false
        index = selected
        position = next.getOrNull(index)?.let { bounded(it, if (startPositionMs == C.TIME_UNSET) 0 else startPositionMs) } ?: 0
        queueVersion=graph.session.version()
        queueScope = next.firstOrNull()?.localConfiguration?.uri?.toString()?.let { grants[it]?.takeIf {g->g.device==null}?.scope }
        order = if (restoredShuffle == true) NativeCallbackTraversal.permutation(next.size, index, random) else next.indices.toList()
        modeRestored = restoredShuffle != null && restoredShuffle != shuffle
        durations.keys.retainAll(next.map { it.mediaId }.toSet())
        playback = Player.STATE_IDLE
        error = null
        return done()
    }

    /** Revocation is synchronous. The old acquisition then joins before any successor is admitted. */
    private fun retireSelection(natural:Boolean=false) {
        retireSpeedRequest(); observedSpeed = null
        if(!natural)journal.freeze()
        cancelSuccessor(natural=natural)
        revokePerformance()
        performanceIdentity = null; durablePerformanceDocument = null; syncQualifications.clear(); performanceDecks = emptyMap(); onPerformanceChanged?.invoke()
        epoch++
        transportRevision++
        pending?.cancel()
        pending = null
        selectedLoaded = false
        activeGrant = null
        activeUri = null
        arrangement = null
        arrangementGrants = emptyMap()
        arrangementSourceItems = emptyList()
        acknowledgedPlaying = false
        desiredSeek = null
        submittedSeek = null
        acknowledgedSeekPosition = null
        pausePosition = null; acknowledgedPausePosition = null
        val retirement = epoch
        val retiringDeck=ordinaryDeck;val retiringIdentity=ordinaryIdentity
        val predecessor = tail
        tail = lifetime.launch {
            predecessor?.join()
            owner.controlDeck(retiringDeck,2) {true}
            var final=owner.snapshot {true}
            withTimeoutOrNull(2_000) {
                while(final?.decks?.getOrNull(retiringDeck)?.let {it.identity==retiringIdentity&&it.playing}==true) {
                    delay(10);final=owner.snapshot {true}
                }
            }
            journal.finalCursor(final)
            if (!owner.unload() && !released && epoch == retirement) fail("Audio source could not be released")
        }
    }

    private fun clearQueue() {
        retireSelection()
        items = emptyList(); order = emptyList(); index = 0; position = 0
        queueScope = null; intent = false; playback = Player.STATE_IDLE; error = null
        durations.clear()
    }

    override fun handlePrepare(): ListenableFuture<*> {
        if (released || items.isEmpty() || pending != null) return done()
        if (selectedLoaded) { dispatchIntent(recoverOutput = true); return done() }
        if (arrangement != null) return done()
        try { validate(items) } catch (_: Exception) { fail("Audio source is no longer available"); return done() }
        val item = requireNotNull(selected())
        val uri = item.localConfiguration!!.uri.toString()
        val grant = grants.getValue(uri)
        activeGrant = grant
        activeUri = uri
        queueScope = if(grant.device==null)grant.scope else null
        epoch = maxOf(epoch, sourceSequence) + 2
        val generation = epoch
        ordinaryDeck = 0; ordinaryIdentity = generation; sourceSequence = generation
        val predecessor = tail
        val seekAtPreparation=explicitSeek
        fun current() = !released && generation == epoch && grant.current(graph) && grants[uri] === grant
        playback = Player.STATE_BUFFERING
        error = null
        eofCount = 0
        preparing.incrementAndGet()
        val job = lifetime.launch(start = CoroutineStart.LAZY) {
            var file: NativePlaybackSource? = null
            var transferred = false
            try {
                predecessor?.join()
                check(current())
                check(owner.recoverOutput(::current)) { "Audio output could not be reopened" }
                check(current())
                outputUnavailable = false; error = null
                // NonCancellable recovers and releases a late result using its typed custody.
                withContext(NonCancellable + Dispatchers.IO) { file = source.acquire(item, ::current) }
                ensureActive()
                check(current())
                val original=file as? NativePlaybackSource.BorrowedOriginal
                val initialPosition = if(position==0L && explicitSeek==seekAtPreparation && original!=null)journal.initialResume(original,grant,ordinaryDeck) else position
                if(initialPosition!=position){position=initialPosition;acknowledgedSeekPosition=initialPosition}
                transferred = true
                val accepted = withContext(NonCancellable) { owner.load(requireNotNull(file), generation, generation, initialPosition, ::current, loadSpeed(item)) }
                check(current())
                check(accepted)
                bindJournal(item,grant,requireNotNull(file),ordinaryDeck,generation,position==0L&&explicitSeek==seekAtPreparation,::current)
                check(current())
                selectedLoaded = true
                desiredSeek = if (position != initialPosition&&acknowledgedSeekPosition==null) position else null
                withContext(NonCancellable) { owner.control(7, volume.toDouble(), ::current) }
                // Play is deferred one main turn so existing focus listener can reject it first.
                dispatchIntent(generation)
            } catch (_: CancellationException) {
                // Superseded work cannot change the successor's error or play intent.
            } catch (_: Exception) {
                if (generation==epoch&&currentScope()&&grants[uri]===grant) { fail(if(grant.device!=null)"Audio source could not be prepared. Check Local audio access or choose the file again." else "Audio source could not be prepared. Try again when the server is available."); retireSelection() }
            } finally {
                if (!transferred) withContext(NonCancellable + Dispatchers.IO) { file?.let {owner.releaseUnborrowed(it)} }
                if (generation == epoch) {
                    pending = null
                    if (!selectedLoaded && playback == Player.STATE_BUFFERING) {
                        intent = false
                        playback = Player.STATE_IDLE
                    }
                    if (!released) invalidateState()
                }
            }
        }
        job.invokeOnCompletion { preparing.decrementAndGet() }
        pending = job
        tail = job
        job.start()
        return done()
    }

    private suspend fun bindJournal(item:MediaItem,grant:MediaGrant,file:NativePlaybackSource,slot:Int,identity:Long,allowResume:Boolean,current:()->Boolean) {
        val ready=withTimeout(15_000) {
            var value:NativeCallbackDeck?=null
            while(value==null) {
                check(current())
                val d=owner.snapshot(current)?.decks?.getOrNull(slot)
                if(d!=null&&d.identity==identity&&d.generation==identity) {
                    check(d.error==0)
                    if(d.ready&&!d.preparing&&d.sourceRate>0)value=d
                }
                if(value==null)delay(20)
            }
            value
        }
        val resume=try {journal.bind(item,grant,file,requireNotNull(ready),slot,current)}catch(failure:Exception){if(grant.device!=null)throw failure else {check(current());return}}
        if(allowResume&&resume>0 && file !is NativePlaybackSource.BorrowedOriginal) {
            journal.fenceSeek(slot)
            check(journal.beginSeek(slot,2,ready.naturalEnd?.count ?: 0))
            check(current()&&owner.controlDeck(slot,3,resume.toDouble(),current))
            val acknowledged=withTimeout(8000) {
                var d:NativeCallbackDeck?=null
                while(d==null) {
                    check(current());val next=owner.snapshot(current)?.decks?.getOrNull(slot)
                    if(next!=null&&next.identity==identity&&next.generation==identity&&next.ready&&next.traversalRevision>ready.traversalRevision&&kotlin.math.abs(next.positionMs-resume)<=250)d=next
                    else delay(20)
                };requireNotNull(d)
            }
            journal.acknowledgeSeek(slot,acknowledged.traversalRevision,acknowledged.positionMs)
            if(slot==ordinaryDeck){position=acknowledged.positionMs;acknowledgedSeekPosition=position}
        }
    }

    private fun dispatchIntent(generation: Long = epoch, recoverOutput: Boolean = false) {
        val revision = transportRevision
        if (recoverOutput) outputRecoveryRevision = revision
        lifetime.launch {
            try {
                yield()
                if (released || generation != epoch || revision != transportRevision || !selectedLoaded) return@launch
                val playing = intent && assignmentCurrent()
                val current = { !released && generation == epoch && revision == transportRevision && (!playing || intent && assignmentCurrent()) }
                if (recoverOutput) {
                    // Reopening belongs to the retained source, not to Play's
                    // transport revision. Pause revokes Play but must still let
                    // this source accept its completed, paused output recovery.
                    val recoveryError = error
                    val recoveryCurrent = {
                        !released && generation == epoch && selectedLoaded && assignmentCurrent() &&
                            outputRecoveryRevision == revision && error === recoveryError
                    }
                    if (!owner.recoverOutput(recoveryCurrent)) {
                        if (recoveryCurrent()) failOutput()
                        return@launch
                    }
                    if (!recoveryCurrent()) return@launch
                    outputUnavailable = false; error = null
                    if (playback == Player.STATE_IDLE) playback = Player.STATE_BUFFERING
                } else if (outputUnavailable) return@launch
                // Completion never revives the captured Play after Pause/Seek.
                if (!current()) return@launch
                if (desiredSeek != null) { seekNative(requireNotNull(desiredSeek)); return@launch }
                if (arrangement != null && intent && playback != Player.STATE_READY) return@launch
                val accepted = if (arrangement != null) owner.arrangement(if (playing) 1 else 2, current = current)
                    else owner.controlDeck(ordinaryDeck, if (playing) 1 else 2, current = current)
                if (!accepted) {
                    if (generation == epoch && revision == transportRevision) {
                        val state = owner.snapshot { !released && generation == epoch && revision == transportRevision }
                        if (released || generation != epoch || revision != transportRevision) return@launch
                        if (state?.error != 0) failOutput() else fail("Audio output refused transport")
                    }
                }
            } finally {
                if (recoverOutput && outputRecoveryRevision == revision) outputRecoveryRevision = null
            }
        }
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if(playWhenReady!=intent)journal.transportIntent(playWhenReady)
        revokePerformance()
        if (!playWhenReady && arrangement != null) { performanceTransportHeld = true; performanceDecks = emptyMap() }
        transportRevision++
        pausePosition = if (!playWhenReady && selectedLoaded) position else null
        intent = playWhenReady && items.isNotEmpty() && currentScope()
        if (intent && playback == Player.STATE_ENDED) {
            handleSeek(index, 0, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        }
        dispatchIntent(recoverOutput = playWhenReady)
        return done()
    }

    override fun handleStop(): ListenableFuture<*> {
        // A stopped synthetic row has no ordinary source capability. Restore the
        // exact authorized originals paused; service timeline observation retires
        // accepted arrangement metadata. Native bytes still drain via old owner.
        val sources = arrangementSourceItems.takeIf { arrangement != null && assignmentCurrent() }
        intent = false
        retireSelection()
        if (sources != null) {
            items = sources; index = 0; position = 0
            order = if (shuffle) NativeCallbackTraversal.permutation(items.size, index, random) else items.indices.toList()
            durations.keys.retainAll(items.map { it.mediaId }.toSet())
        }
        playback = Player.STATE_IDLE
        error = null
        return done()
    }

    override fun handleRelease(): ListenableFuture<*> {
        if (released) return done()
        intent = false
        playback = Player.STATE_IDLE
        released = true
        accountJob.cancel()
        retireSelection()
        val predecessor = tail
        lifetime.launch {
            predecessor?.join()
            owner.close()
            lifetime.cancel()
        }
        return done()
    }

    override fun handleSetRepeatMode(repeatMode: Int): ListenableFuture<*> { cancelSuccessor(); repeat = repeatMode; return done() }
    override fun handleSetShuffleModeEnabled(shuffleModeEnabled: Boolean): ListenableFuture<*> {
        cancelSuccessor()
        if (shuffle != shuffleModeEnabled) {
            shuffle = shuffleModeEnabled
            if (!modeRestored) order = if (shuffle) NativeCallbackTraversal.permutation(items.size, index, random) else items.indices.toList()
        }
        modeRestored = false
        return done()
    }
    @Suppress("OVERRIDE_DEPRECATION")
    override fun handleSetVolume(volume: Float): ListenableFuture<*> {
        this.volume = volume
        val generation = epoch
        lifetime.launch { if (arrangement == null) {
            owner.controlDeck(ordinaryDeck, 7, volume.toDouble()) { !released && generation == epoch }
            successor?.let { c -> owner.controlDeck(if (ordinaryDeck == c.deck) c.outgoingDeck else c.deck, 7, volume.toDouble()) { !released && generation == epoch && successor === c } }
        }
            else owner.arrangement(7, (volume * 1_000_000).toLong()) { !released && generation == epoch } }
        return done()
    }

    private fun mutate(next: List<MediaItem>, nextOrder: List<Int>, fallback: Int, preserveCurrent: Boolean = true): ListenableFuture<*> {
        validate(next)
        cancelSuccessor()
        if (next.isEmpty()) { clearQueue(); return done() }
        val previous = selected()?.mediaId
        val retained = if (preserveCurrent) next.indexOfFirst {
            it.mediaId == previous && it.localConfiguration == selected()?.localConfiguration
        } else -1
        val needsPreparation = selectedLoaded || pending != null || playback != Player.STATE_IDLE
        if (retained < 0) retireSelection()
        items = next
        order = nextOrder
        index = if (retained >= 0) retained else fallback.coerceIn(next.indices)
        queueScope = grants.getValue(next.first().localConfiguration!!.uri.toString()).let { if (it.device == null) it.scope else null }
        if (retained < 0) { position = 0; playback = Player.STATE_IDLE; error = null; if (needsPreparation) handlePrepare() }
        durations.keys.retainAll(next.map { it.mediaId }.toSet())
        return done()
    }

    override fun handleAddMediaItems(insertionIndex: Int, mediaItems: List<MediaItem>): ListenableFuture<*> {
        if (mediaItems.isEmpty()) return done()
        val next = items.toMutableList().apply { addAll(insertionIndex, mediaItems) }
        val nextOrder = NativeCallbackTraversal.insert(order, insertionIndex, mediaItems.size, index,
            mediaItems.all { it.mediaMetadata.extras?.getBoolean("manual") == true },
            mediaItems.all { it.mediaMetadata.extras?.getString("origin") == "Continuation" },
            items.indices.filter { items[it].mediaMetadata.extras?.getBoolean("manual") == true }.toSet(), shuffle)
        return mutate(next, nextOrder, 0)
    }
    private fun rebuilt(next: List<MediaItem>, fallback: Int): List<Int> {
        val selected = next.indexOfFirst { it.mediaId == selected()?.mediaId }.takeIf { it >= 0 } ?: fallback
        return if (shuffle) NativeCallbackTraversal.permutation(next.size, selected, random) else next.indices.toList()
    }
    override fun handleRemoveMediaItems(fromIndex: Int, toIndex: Int): ListenableFuture<*> {
        val next = items.toMutableList().apply { subList(fromIndex, toIndex).clear() }
        return mutate(next, rebuilt(next, fromIndex), fromIndex, index !in fromIndex until toIndex)
    }
    override fun handleMoveMediaItems(fromIndex: Int, toIndex: Int, newIndex: Int): ListenableFuture<*> {
        val next = items.toMutableList().apply { val moved = subList(fromIndex, toIndex).toList(); subList(fromIndex, toIndex).clear(); addAll(newIndex, moved) }
        return mutate(next, rebuilt(next, 0), 0)
    }
    override fun handleReplaceMediaItems(fromIndex: Int, toIndex: Int, mediaItems: List<MediaItem>): ListenableFuture<*> {
        val next = items.toMutableList().apply { subList(fromIndex, toIndex).clear(); addAll(fromIndex, mediaItems) }
        return mutate(next, rebuilt(next, fromIndex), fromIndex, index !in fromIndex until toIndex)
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        if (items.isEmpty()) return done()
        explicitSeek++;journal.fenceSeek(ordinaryDeck)
        val traversal = activeOrder()
        val next = when (seekCommand) {
            Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM -> NativeCallbackTraversal.next(traversal, index, repeat, false) ?: return done()
            Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM -> NativeCallbackTraversal.previous(traversal, index, repeat)
            else -> if (mediaItemIndex == C.INDEX_UNSET) index else mediaItemIndex
        }
        require(next in items.indices)
        cancelSuccessor()
        retirePerformanceTransport()
        pausePosition = null
        val target = bounded(items[next], if (positionMs == C.TIME_UNSET || seekCommand in listOf(Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, Player.COMMAND_SEEK_TO_PREVIOUS, Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)) 0 else positionMs)
        transportRevision++
        if (next == index) {
            if (playback == Player.STATE_ENDED) playback = if (selectedLoaded) Player.STATE_READY else Player.STATE_IDLE
            desiredSeek = target
            if (!selectedLoaded) {
                if (arrangement == null) position = target
            } else seekNative(target)
            dispatchIntent()
        } else {
            val prepare = selectedLoaded || pending != null || playback != Player.STATE_IDLE
            retireSelection()
            index = next; position = target; playback = Player.STATE_IDLE; error = null
            if (prepare) handlePrepare()
        }
        return done()
    }

    private class ClockSeekReceipt(val generation:Long,val revision:Long,val target:Long,var acknowledged:Boolean=false)
    private var clockSeekReceipt:ClockSeekReceipt?=null
    private fun acknowledgeClockSeek(ready:Boolean,cursor:Long) {
        clockSeekReceipt?.takeIf {ready&&it.generation==epoch&&it.revision==transportRevision&&kotlin.math.abs(cursor-it.target)<=250}
            ?.acknowledged=true
    }

    /** One indexed seek, retaining play intent. Completion requires a latched native
     * cursor receipt, not command admission, controller masking or a later moving cursor. */
    internal suspend fun seekClock(index:Int,target:Long,current:()->Boolean):Boolean {
        if(!current()||index !in items.indices)return false
        seekTo(index,target)
        // A restored/stopped queue may not have a decoder yet. Prepare paused;
        // never turn a seek into Play, and never acknowledge an optimistic cursor.
        if(!selectedLoaded&&pending==null&&playback==Player.STATE_IDLE)prepare()
        val receipt=ClockSeekReceipt(epoch,transportRevision,target)
        clockSeekReceipt=receipt
        fun owns()=current()&&!released&&epoch==receipt.generation&&transportRevision==receipt.revision&&this.index==index&&error==null
        return try {
            withTimeoutOrNull(8_000) {
                while(owns()) {
                    if(receipt.acknowledged)return@withTimeoutOrNull true
                    delay(10)
                }
                false
            } ?: false
        } finally {if(clockSeekReceipt===receipt)clockSeekReceipt=null}
    }

    private fun seekNative(target: Long,naturalRepeat:Boolean=false) {
        if (submittedSeek == target) return
        val generation = epoch
        val revision = ++seekRevision
        submittedSeek = target
        val journalDeck=ordinaryDeck;val journalStamp=journal.stamp(journalDeck)
        lifetime.launch {
            val current = { !released && generation == epoch && revision == seekRevision && assignmentCurrent() }
            if(naturalRepeat&&!journal.fenceNaturalRepeat(journalDeck,journalStamp,current)){if(generation==epoch&&revision==seekRevision)submittedSeek=null;return@launch}
            if(arrangement==null&&!journal.beginSeek(ordinaryDeck,revision+2,eofCount)){if(generation==epoch&&revision==seekRevision)submittedSeek=null;return@launch}
            val accepted = if (arrangement != null) owner.arrangement(3, target, current)
                else { tail?.join(); owner.controlDeck(ordinaryDeck, 3, target.toDouble(), current) }
            if (!accepted && generation == epoch && revision == seekRevision) submittedSeek = null
        }
    }

    private fun fail(message: String) {
        if (released) return
        if (selectedLoaded) retireSelection()
        intent = false; acknowledgedPlaying = false; playback = Player.STATE_IDLE
        error = PlaybackException(message, null, PlaybackException.ERROR_CODE_IO_UNSPECIFIED)
        invalidateState()
    }

    /** A route error is not a source-release receipt. Keep selection and cursor. */
    private fun failOutput() {
        if (released) return
        if (!outputUnavailable) {
            revokePerformance()
            performanceTransportHeld = true; performanceDecks = emptyMap()
            transportRevision++
        }
        outputUnavailable = true
        intent = false; acknowledgedPlaying = false; playback = Player.STATE_IDLE
        submittedSeek = null
        error = PlaybackException("Audio output is unavailable. Press Play to retry.", null, PlaybackException.ERROR_CODE_IO_UNSPECIFIED)
        invalidateState()
    }

    /** Publish the final native Pause cursor once, not each in-flight moving poll. */
    private fun acknowledgePausePosition(ready: Boolean) {
        val before = pausePosition ?: return
        if (intent || acknowledgedPlaying || !ready || desiredSeek != null) return
        pausePosition = null
        // Media3 ignores inferred changes under 1000 ms and stops periodic
        // session position updates while paused. This is not a user Seek.
        if (position != before) acknowledgedPausePosition = position
    }

    private fun observe(snapshot: NativeCallbackSnapshot?) {
        if (released) return
        if (snapshot == null || snapshot.error != 0) {
            // A queued old-route observation cannot cancel fresh explicit intent
            // while its serialized recovery is waiting to start or settle.
            if (outputRecoveryRevision == null) failOutput()
            return
        }
        // Healthy observation alone never resumes an interrupted intent.
        if (outputUnavailable) return
        val activeArrangement = arrangement
        if (activeArrangement != null) {
            if (!selectedLoaded || snapshot.scheduleRevision != activeArrangement.revision) return
            if (!assignmentCurrent()) { intent = false; retireSelection(); playback = Player.STATE_IDLE; invalidateState(); return }
            // Per-instance decode/missing-page failures remain visible in native diagnostics.
            // The shared clock and healthy peers continue; a late binding rejoins its phase.
            if (performanceTransportHeld && desiredSeek == null && snapshot.decks.none { it.scratching || it.syncState != 0 }) performanceTransportHeld = false
            // Build the deck projection before exposing an Applied tempo receipt.
            // Both belong to this same native snapshot, never adjacent polls.
            if (!performanceTransportHeld) publishPerformance(snapshot, activeArrangement, notify = false)
            observeTempo(snapshot)
            if (!performanceTransportHeld) onPerformanceChanged?.invoke()
            acknowledgedPlaying = snapshot.schedulePlaying
            position = snapshot.globalPositionMs
            if (snapshot.scheduleDurationMs > 0) selected()?.let { durations[it.mediaId] = snapshot.scheduleDurationMs }
            val target = desiredSeek
            val acknowledgedTarget = target?.let { if (snapshot.scheduleDurationMs > 0) minOf(it, snapshot.scheduleDurationMs) else it }
            if (target != null && submittedSeek == target && snapshot.scheduleReady && kotlin.math.abs(position-requireNotNull(acknowledgedTarget)) <= 1) {
                desiredSeek = null; submittedSeek = null
                // Small acknowledged seeks may be below SimpleBasePlayer's
                // inferred-discontinuity threshold. Publish the native cursor
                // explicitly so MediaController cannot retain its older position.
                acknowledgedSeekPosition = position
                if (intent) dispatchIntent()
            }
            val wasReady = playback == Player.STATE_READY
            playback = if (snapshot.scheduleEnded) Player.STATE_ENDED else if (snapshot.scheduleReady || snapshot.schedulePlaying) Player.STATE_READY else Player.STATE_BUFFERING
            if (!wasReady && playback == Player.STATE_READY && intent && !acknowledgedPlaying && desiredSeek == null) dispatchIntent()
            acknowledgePausePosition(snapshot.scheduleReady)
            // Synthetic graph completion is not a track-listen event.
            invalidateState()
            return
        }
        if (snapshot.speedMax > snapshot.speedMin && (snapshot.speedMin to snapshot.speedMax) != speedBounds) {
            speedBounds = snapshot.speedMin to snapshot.speedMax; reconcileSpeed = true
            speedPreferenceChanged(); onSpeedChanged?.invoke()
        }
        journal.observe(snapshot,allowNatural=intent&&desiredSeek==null)
        if (observeSuccessor(snapshot)) return
        val deck = snapshot.decks.getOrNull(ordinaryDeck) ?: return
        if (!selectedLoaded || deck.identity != ordinaryIdentity || deck.generation != ordinaryIdentity) return
        if (!assignmentCurrent()) { intent = false; retireSelection(); playback = Player.STATE_IDLE; invalidateState(); return }
        if (deck.error != 0) { fail("Audio format could not be decoded"); return }
        if (deck.sourceRate > 0 && deck.sourceFrames > 0) selected()?.let { durations[it.mediaId] = deck.durationMs }
        acknowledgedPlaying = deck.playing
        observeSpeed(deck)
        val seekTarget = desiredSeek
        // JNI Seek is admission, not cursor ACK. Ignore an older EOF until native cursor arrives.
        if (seekTarget != null && submittedSeek == seekTarget && deck.ready &&
            kotlin.math.abs(deck.positionMs - seekTarget) <= 250) {
            desiredSeek = null
            submittedSeek = null
            acknowledgedSeekPosition = deck.positionMs.coerceAtLeast(0)
            journal.acknowledgeSeek(ordinaryDeck,deck.traversalRevision,deck.positionMs)
            if(intent)dispatchIntent()
            // Backward seeks fence an older EOF. Endpoint seek completion can
            // arrive in this same snapshot and still belongs to queue policy.
            if (seekTarget < deck.durationMs) eofCount = maxOf(eofCount, deck.eofCount)
        }
        if (desiredSeek == null) position = deck.positionMs.coerceAtLeast(0)
        acknowledgeClockSeek(deck.ready && desiredSeek == null,deck.positionMs)
        if (deck.ready && desiredSeek != null) seekNative(requireNotNull(desiredSeek))
        if (playback != Player.STATE_ENDED) playback = if (deck.ready) Player.STATE_READY else Player.STATE_BUFFERING
        val eof = desiredSeek == null && deck.eofCount > eofCount
        eofCount = maxOf(eofCount, deck.eofCount)
        if (eof) {
            val outgoing = selected() ?: return
            val generation = epoch
            val revision = transportRevision
            completions.toList().forEach { callback ->
                if (epoch != generation || transportRevision != revision) return
                callback(outgoing)
            }
            if (epoch != generation || transportRevision != revision) return
            val successor = NativeCallbackTraversal.next(activeOrder(), index, repeat, true)
            if (successor == null) playback = Player.STATE_ENDED
            else if (successor == index) { desiredSeek = 0; seekNative(0,naturalRepeat=true); dispatchIntent() }
            else {
                retireSelection(natural=true); index = successor; position = 0; playback = Player.STATE_IDLE
                handlePrepare()
            }
        }
        acknowledgePausePosition(deck.ready)
        prepareSuccessor()
        invalidateState()
    }

    override fun addCompletionListener(listener: (MediaItem) -> Unit) { completions.add(listener) }
    override fun removeCompletionListener(listener: (MediaItem) -> Unit) { completions.remove(listener) }

    /** Immutable timeline forwarding rows and actual durations, overriding only traversal policy. */
    private class TraversalTimeline(private val source: Timeline, private val order: List<Int>) : Timeline() {
        override fun getWindowCount() = source.windowCount
        override fun getPeriodCount() = source.periodCount
        override fun getWindow(index: Int, window: Window, defaultPositionProjectionUs: Long) = source.getWindow(index, window, defaultPositionProjectionUs)
        override fun getPeriod(index: Int, period: Period, setIds: Boolean) = source.getPeriod(index, period, setIds)
        override fun getIndexOfPeriod(uid: Any) = source.getIndexOfPeriod(uid)
        override fun getUidOfPeriod(periodIndex: Int): Any = source.getUidOfPeriod(periodIndex)
        override fun getFirstWindowIndex(shuffleModeEnabled: Boolean) = if (shuffleModeEnabled) order.firstOrNull() ?: C.INDEX_UNSET else source.getFirstWindowIndex(false)
        override fun getLastWindowIndex(shuffleModeEnabled: Boolean) = if (shuffleModeEnabled) order.lastOrNull() ?: C.INDEX_UNSET else source.getLastWindowIndex(false)
        override fun getNextWindowIndex(windowIndex: Int, repeatMode: Int, shuffleModeEnabled: Boolean): Int =
            if (shuffleModeEnabled) NativeCallbackTraversal.next(order, windowIndex, repeatMode, true) ?: C.INDEX_UNSET else source.getNextWindowIndex(windowIndex, repeatMode, false)
        override fun getPreviousWindowIndex(windowIndex: Int, repeatMode: Int, shuffleModeEnabled: Boolean): Int =
            if (!shuffleModeEnabled) source.getPreviousWindowIndex(windowIndex, repeatMode, false)
            else if (repeatMode == Player.REPEAT_MODE_ONE) windowIndex
            else if (order.firstOrNull() == windowIndex && repeatMode != Player.REPEAT_MODE_ALL) C.INDEX_UNSET
            else NativeCallbackTraversal.previous(order, windowIndex, repeatMode)
        override fun equals(other: Any?) = other is TraversalTimeline && source == other.source && order == other.order
        override fun hashCode() = 31 * source.hashCode() + order.hashCode()
    }
}
