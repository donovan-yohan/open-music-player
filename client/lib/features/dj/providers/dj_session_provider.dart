import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/engine/engine_audio_source_resolver.dart';
import '../../../core/engine/gain_envelope.dart';
import '../../../core/engine/tempo_automation.dart';
import '../../../core/engine/voice.dart';
import '../../../core/cache/playback_cache_manager.dart';
import '../../../core/stems/stem_channel_source.dart';
import '../../../models/track.dart';
import '../../dj/engine/deck_controller.dart';
import '../engine/deck_sync.dart';
import '../models/dj_deck_state.dart';
import '../models/dj_hot_cue.dart';
import '../models/dj_musical_grid.dart';

typedef DjFilePicker = Future<DjDeckLoad?> Function();

/// Monotonic wall-clock source, in milliseconds, for the sync correction
/// throttle.
///
/// Injectable so the convergence tests can step a deterministic clock instead
/// of sleeping on real time: the throttle is the one part of the correction
/// loop whose contract is stated in wall milliseconds rather than in ticks.
typedef DjSyncClock = int Function();

/// The only mutable screen state authority for the direct-Voice prototype.
///
/// TODO(dj-production): project QueueTimelineController instead; see
/// docs/adr/0001-playback-timeline-source-of-truth.md.
class DjSessionProvider extends ChangeNotifier {
  DjSessionProvider({
    required DeckController deckA,
    required DeckController deckB,
    StemChannelSource? stems,
    DjSyncClock? clock,
  })  : _decks = {DjDeckId.a: deckA, DjDeckId.b: deckB},
        _clock = clock ?? _elapsedWallMs,
        stems = stems ?? const UnavailableStemChannelSource() {
    _snapshotTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _refreshSnapshots();
    });
  }

  /// Process-wide monotonic source. Deliberately not `DateTime.now()`: the
  /// throttle measures an interval, and a wall-clock step (NTP, timezone) must
  /// not be able to stall or flood the correction loop.
  static final Stopwatch _wall = Stopwatch()..start();
  static int _elapsedWallMs() => _wall.elapsedMilliseconds;

  factory DjSessionProvider.prototype({
    VoiceFactory? voiceFactory,
    EngineAudioSourceResolver? resolver,
    PlaybackCacheManager? cacheManager,
    StemChannelSource? stems,
    DjSyncClock? clock,
  }) {
    final makeVoice = voiceFactory ?? () => JustAudioVoice(debugId: 'dj-voice');
    final sourceResolver = resolver ??
        DefaultEngineAudioSourceResolver(cacheManager: cacheManager);
    return DjSessionProvider(
      deckA: DeckController.empty(
        deckId: DjDeckId.a,
        voice: makeVoice(),
        resolver: sourceResolver,
      ),
      deckB: DeckController.empty(
        deckId: DjDeckId.b,
        voice: makeVoice(),
        resolver: sourceResolver,
      ),
      stems: stems,
      clock: clock,
    );
  }

  final Map<DjDeckId, DeckController> _decks;
  final StemChannelSource stems;
  final Map<DjDeckId, Map<int, DjHotCue>> _hotCues = {
    DjDeckId.a: {},
    DjDeckId.b: {},
  };
  final Map<DjDeckId, bool> _cueWasPlaying = {};
  final Map<DjDeckId, int> _pendingLoopInMs = {};
  final Map<DjDeckId, double> _preNudgeRates = {};
  final Set<DjDeckId> _loopWrapsInFlight = {};

  /// The deck that sets the tempo. Null until sync is first engaged.
  DjDeckId? _syncMaster;

  /// The decks currently following [_syncMaster]. With two decks this holds at
  /// most one entry; the master is never a member.
  final Set<DjDeckId> _syncEngaged = {};

  /// The matched tempo each engaged follower was put on, before any correction.
  /// The correction is an offset around this, exactly like `_preNudgeRates`
  /// holds the rate a pitch bend returns to.
  final Map<DjDeckId, double> _syncBaseRates = {};

  /// The correction offset currently applied to each engaged follower.
  final Map<DjDeckId, double> _syncOffsets = {};

  /// When each deck last had a rate command issued to it by sync.
  final Map<DjDeckId, int> _syncCommandAtMs = {};

  /// Decks whose `setRate` has not returned yet. The 33Hz pass is far faster
  /// than a `setSpeed` round trip, so without this a slow backend would collect
  /// a queue of stale corrections.
  final Set<DjDeckId> _syncCommandsInFlight = {};

  /// Throttles the debug-only alignment trace to the command interval.
  int? _syncTraceAtMs;

  final DjSyncClock _clock;
  late final Timer _snapshotTimer;
  bool _disposed = false;
  double _crossfader = .5;

  DjDeckState get deckA => stateFor(DjDeckId.a);
  DjDeckState get deckB => stateFor(DjDeckId.b);
  double get crossfader => _crossfader;
  DjDeckState stateFor(DjDeckId deck) => _decks[deck]!.state;

  /// The deck that currently sets the tempo, or null if sync is idle.
  DjDeckId? get syncMaster => _syncMaster;
  bool syncEngagedOn(DjDeckId deck) => _syncEngaged.contains(deck);
  bool isSyncMaster(DjDeckId deck) => _syncMaster == deck;

  static DjDeckId _otherDeck(DjDeckId deck) =>
      deck == DjDeckId.a ? DjDeckId.b : DjDeckId.a;

  /// Pure preview of what [pressSync] would do to [deck], for gating the
  /// button and rendering its reason. Applies nothing.
  ///
  /// The would-be leader is always the *other* deck: with no master yet the
  /// other deck becomes master, pressing the master swaps to the other deck,
  /// and a follower's master already is the other deck.
  DjSyncMatch syncMatchFor(DjDeckId deck) => djSyncTempoMatch(
        leader: stateFor(_otherDeck(deck)),
        follower: stateFor(deck),
      );

  /// One SYNC press on [deck].
  ///
  /// * idle, or [deck] is the master: the other deck becomes master and [deck]
  ///   follows it. Pressing the master is therefore the master swap.
  /// * [deck] is an engaged follower: it disengages and **keeps its matched
  ///   tempo**. Snapping back to 1.0 would be an audible tempo jump mid-blend;
  ///   only the transient alignment offset is unwound.
  /// * refused: nothing is applied, no state moves, and no notification is
  ///   sent. The refusal is returned and rendered as the disabled reason.
  ///
  /// The master's own rate is never written (issue #413, AC 8).
  Future<DjSyncMatch> pressSync(DjDeckId deck) async {
    if (_disposed) {
      return const DjSyncMatch.refused(DjSyncRefusal.noLeader);
    }
    final other = _otherDeck(deck);
    if (_syncEngaged.contains(deck) && _syncMaster != deck) {
      _syncEngaged.remove(deck);
      // A deliberate disengage hands the deck back at the tempo it was matched
      // to, not at whatever the correction loop was holding at that instant.
      await _restoreSyncBaseRate(deck);
      _clearMasterWithoutFollowers();
      _notify();
      // Nothing else was applied; this describes the match a re-engage uses.
      return syncMatchFor(deck);
    }
    // A swap deposes the current follower. Unwind its correction offset first,
    // so both the tempo the new match is computed against and the tempo the new
    // master keeps are the matched base rate rather than a mid-correction one.
    var restored = false;
    if (_syncMaster == deck && _syncEngaged.contains(other)) {
      restored = await _restoreSyncBaseRate(other);
    }
    final match = djSyncTempoMatch(
      leader: stateFor(other),
      follower: stateFor(deck),
    );
    if (!match.isMatched) {
      if (restored) _notify();
      return match;
    }
    // Every engaged case resolves to the same shape: the other deck leads and
    // this deck is the only follower. A two-deck session has no third state.
    _syncMaster = other;
    for (final released in _syncEngaged) {
      _forgetSyncCorrection(released);
    }
    _syncEngaged
      ..clear()
      ..add(deck);
    await _decks[deck]!.setRate(match.targetRate);
    _syncBaseRates[deck] = match.targetRate;
    _syncOffsets[deck] = 0;
    // The match itself is a rate command, so it starts the throttle window.
    _syncCommandAtMs[deck] = _clock();
    await _seekPausedFollowerIntoPulse(deck, other);
    _notify();
    return match;
  }

  /// Puts a paused follower exactly on the leader's pulse before it starts.
  ///
  /// A playing deck is never seeked: a buffered ExoPlayer seek is 50-200ms and
  /// audible (docs/dj-deck-spec.md:314). A paused one is silent, so it can be
  /// placed exactly rather than spending the whole convergence window closing
  /// an error it never needed to have.
  Future<void> _seekPausedFollowerIntoPulse(
    DjDeckId deck,
    DjDeckId master,
  ) async {
    final follower = stateFor(deck);
    if (follower.playing) return;
    final leader = stateFor(master);
    if (!djSyncPhaseCorrectionAllowed(leader: leader, follower: follower)) {
      return;
    }
    final reading = djSyncPhaseReading(leader: leader, follower: follower);
    if (reading == null) return;
    // The error is wall time; the deck seeks in media time.
    final shiftMs = (reading.errorMs * follower.rate).round();
    if (shiftMs == 0) return;
    final target = follower.positionMs - shiftMs;
    // Clamping would land the deck off the pulse while reporting success, so a
    // shift that leaves the track is simply not taken.
    if (target < 0 || target > follower.durationMs) return;
    await _decks[deck]!.seek(target);
  }

  /// Returns [deck] to its matched tempo and forgets its correction state.
  ///
  /// Returns true when a rate command was actually issued.
  Future<bool> _restoreSyncBaseRate(DjDeckId deck) async {
    final base = _syncBaseRates.remove(deck);
    final offset = _syncOffsets.remove(deck) ?? 0;
    _syncCommandAtMs.remove(deck);
    if (base == null || offset == 0) return false;
    await _decks[deck]!.setRate(base);
    return true;
  }

  void _forgetSyncCorrection(DjDeckId deck) {
    _syncBaseRates.remove(deck);
    _syncOffsets.remove(deck);
    _syncCommandAtMs.remove(deck);
  }

  /// D4b: the master mark only means something while somebody follows it.
  ///
  /// The ex-master used to keep its glyph and its "this deck sets the tempo"
  /// tooltip after the last follower left, which claimed a relationship that no
  /// longer existed. With two decks the engaged set holds at most one follower,
  /// so this fires on every disengage; the rule is written against the set
  /// rather than against that count so a third deck would keep the master
  /// marked while any follower remains.
  void _clearMasterWithoutFollowers() {
    if (_syncEngaged.isEmpty) _syncMaster = null;
  }

  /// Takes [deck] out of whatever sync role it held.
  ///
  /// Two callers, one rule. A manual tempo change hands that deck's rate back
  /// to the user, and a deck that took new audio or lost it can neither lead
  /// nor follow. Either way, if [deck] was the *master* the whole session
  /// returns to idle: every follower's match was against a tempo that has now
  /// moved, and leaving a follower marked as matched would be a lie.
  ///
  /// The phase-correction slice is where these two callers stop agreeing: a
  /// deliberate disengage has to restore the follower's base rate once, while a
  /// deck that lost its audio has no rate to restore.
  void _releaseSyncRole(DjDeckId deck) {
    if (_syncMaster == deck) {
      _syncMaster = null;
      for (final follower in _syncEngaged) {
        _forgetSyncCorrection(follower);
      }
      _syncEngaged.clear();
      return;
    }
    if (!_syncEngaged.remove(deck)) return;
    // No restore here, deliberately: `setPitchPercent` writes the deck's rate
    // itself on the next line, and a deck that lost its audio has no rate left
    // to restore. Only the bookkeeping is dropped.
    _forgetSyncCorrection(deck);
    _clearMasterWithoutFollowers();
  }
  List<DjHotCue> hotCuesFor(DjDeckId deck) =>
      _hotCues[deck]!.values.toList()..sort((a, b) => a.slot.compareTo(b.slot));

  /// Adapter kept separate from widget construction so tests and a future
  /// QueueTimeline projection can seed both decks without depending on UI.
  static List<DjDeckLoad> queueSeeds(QueueTrack? current, QueueTrack? next) => [
        if (current != null) _seedForTrack(current),
        if (next != null) _seedForTrack(next),
      ];

  /// The resolver-backed audio source key for [track]: the first candidate that
  /// parses to a positive integer, matching QueueProvider._analysisTrackId
  /// (queue_provider.dart:2079) and the downloads store key
  /// (download_service.dart:301). Queue item UUIDs are never a downloads key.
  static String? djDeckTrackRef(QueueTrack track) {
    for (final candidate in [track.playbackTrackId, track.id]) {
      if (candidate == null) continue;
      final parsed = int.tryParse(candidate);
      if (parsed != null && parsed > 0) return parsed.toString();
    }
    return null;
  }

  static DjDeckLoad _seedForTrack(QueueTrack track) {
    // The fallback preserves today's identity for a row with no numeric id;
    // such a deck now surfaces a load failure instead of throwing (#409).
    final ref = djDeckTrackRef(track) ?? track.playbackTrackId ?? track.id;
    // Retained deliberately: the on-device miss behind #409 defect 3 is NOT yet
    // root-caused. The row that was QA'd already had a numeric playbackTrackId,
    // so this key resolution was a no-op for it and the original refusal of a
    // downloaded track (a DownloadService._validateCompleted downgrade is the
    // remaining suspect) can still recur. These two lines are the trail for
    // that follow-up.
    if (kDebugMode) {
      debugPrint('OMP DJ deck seed candidates '
          'playbackTrackId=${track.playbackTrackId} id=${track.id} -> $ref');
    }
    final analysis = track.analysis;
    return DjDeckLoad(
      trackRef: ref,
      queueItemId: track.queueItemId,
      title: track.title,
      queueTrack: track,
      // QueueTrack.duration is whole seconds (track.dart:286) — #412.
      durationMs: track.durationMs,
      // The track-analysis model is the only timing-override interpreter; the
      // deck reads the same effective grid as DjDeckState.beatPhase (#412).
      beatsMs: analysis == null
          ? const <int>[]
          : ClipTempoMetadata.fromTrackAnalysis(analysis).beatsMs,
      // The effective timing projection carries no intro range.
      initialCueMs: analysis?.summary?.intro?.startMs ?? 0,
    );
  }

  /// Pushes freshly hydrated queue analysis onto whichever decks it belongs to.
  ///
  /// Returns true if any deck changed. Never loads audio (#410): the deck's
  /// waveform peaks only exist on the per-track analysis endpoint, so they
  /// arrive long after the seed and have to reach deck state without a second
  /// Voice.load.
  ///
  /// Matching is by queue item first, then by the resolver-backed track ref, so
  /// a re-queued row still finds its deck.
  bool applyAnalysisUpdate(Iterable<QueueTrack> tracks) {
    if (_disposed) return false;
    var changed = false;
    for (final track in tracks) {
      final trackRef = djDeckTrackRef(track);
      for (final controller in _decks.values) {
        final state = controller.state;
        final queueItemId = state.queueItemId;
        final matches = (queueItemId != null &&
                queueItemId == track.queueItemId) ||
            (trackRef != null && state.trackRef == trackRef);
        if (!matches) continue;
        if (controller.updateQueueTrack(track)) changed = true;
      }
    }
    // One notify for the whole batch, and none at all when nothing moved: this
    // runs off a QueueProvider notification, not off the 33 Hz snapshot loop.
    if (changed) _notify();
    return changed;
  }

  /// Loads current/next queue seeds. If neither is available the caller may
  /// provide a local-file picker seam (no file_picker dependency in the spike).
  Future<void> seed({
    QueueTrack? current,
    QueueTrack? next,
    DjFilePicker? filePicker,
  }) async {
    if (_disposed) return;
    final seeds = queueSeeds(current, next);
    if (seeds.isEmpty && filePicker != null) {
      final picked = await filePicker();
      if (picked != null) seeds.add(picked);
    }
    // Deck A is still awaited before deck B: the prototype's two voices share
    // one audio session, so their loads must not overlap.
    if (seeds.isNotEmpty) await _seedDeck(DjDeckId.a, seeds.first);
    if (seeds.length > 1) await _seedDeck(DjDeckId.b, seeds[1]);
  }

  /// Loads one deck without letting its outcome decide the other's (#409).
  Future<void> _seedDeck(DjDeckId deck, DjDeckLoad seed) async {
    if (_disposed) return;
    try {
      await load(deck, seed);
    } catch (error) {
      // DeckController.load is total for a refusable source, so this catch is
      // belt-and-braces: an unforeseen throw must still leave the other deck
      // free to load, and this deck explaining itself in its lane. Refusing
      // through the controller (rather than a bare state write) also releases a
      // voice that an unforeseen throw may have left holding audio.
      _releaseSyncRole(deck);
      await _decks[deck]!.refuseLoad(seed, detail: '$error');
      _applyDeckGains();
      _notify();
    }
  }

  Future<void> load(DjDeckId deck, DjDeckLoad seed) async {
    if (_disposed) return;
    // A deck taking new audio drops whatever sync role it held: the match was
    // against a track it no longer holds.
    _releaseSyncRole(deck);
    await _decks[deck]!.load(seed);
    _applyDeckGains();
    _notify();
  }

  Future<void> togglePlay(DjDeckId deck) async {
    if (_disposed) return;
    final controller = _decks[deck]!;
    if (controller.state.playing) {
      await controller.pause();
    } else {
      await controller.play();
    }
    _notify();
  }

  Future<void> seek(DjDeckId deck, int positionMs) async {
    if (_disposed) return;
    await _decks[deck]!.seek(positionMs);
    _notify();
  }

  Future<void> cuePress(DjDeckId deck) async {
    if (_disposed) return;
    final controller = _decks[deck]!;
    final state = controller.state;
    _cueWasPlaying[deck] = state.playing;
    await controller.seek(state.loadedCueMs);
    if (!state.playing) {
      await controller.play();
    }
    _notify();
  }

  Future<void> cueRelease(DjDeckId deck) async {
    if (_disposed) return;
    final controller = _decks[deck]!;
    if (_cueWasPlaying.remove(deck) == false) {
      await controller.pause();
      await controller.seek(controller.state.loadedCueMs);
    }
    _notify();
  }

  Future<void> setPitchPercent(DjDeckId deck, double percent) async {
    if (_disposed) return;
    // Two authorities must never fight over one rate: moving the fader by hand
    // is the user taking this deck's tempo back from sync.
    _releaseSyncRole(deck);
    await _decks[deck]!.setRate(1 + percent.clamp(-25.0, 25.0) / 100);
    _notify();
  }

  Future<void> nudgePitchStart(DjDeckId deck, double deltaPercent) async {
    if (_disposed) return;
    _preNudgeRates.putIfAbsent(deck, () => stateFor(deck).rate);
    final base = _preNudgeRates[deck]!;
    await _decks[deck]!
        .setRate(base * (1 + deltaPercent.clamp(-2.0, 2.0) / 100));
    _notify();
  }

  Future<void> nudgePitchEnd(DjDeckId deck) async {
    if (_disposed) return;
    final rate = _preNudgeRates.remove(deck);
    if (rate == null) return;
    await _decks[deck]!.setRate(rate);
    _notify();
  }

  Future<void> setChannelGain(DjDeckId deck, double gain) async {
    if (_disposed) return;
    final controller = _decks[deck]!;
    controller.setChannelGain(gain);
    _applyDeckGains();
    _notify();
  }

  Future<void> setCrossfader(double value) async {
    if (_disposed) return;
    _crossfader = value.clamp(0.0, 1.0).toDouble();
    _applyDeckGains();
    _notify();
  }

  void _applyDeckGains() {
    final gains = equalPowerCrossfadeGains(_crossfader);
    unawaited(
      _decks[DjDeckId.a]!.setOutputVolume(deckA.channelGain * gains.left),
    );
    unawaited(
      _decks[DjDeckId.b]!.setOutputVolume(deckB.channelGain * gains.right),
    );
  }

  Future<void> setHotCue(DjDeckId deck, int slot) async {
    if (_disposed) return;
    if (slot < 1 || slot > 4) throw RangeError.range(slot, 1, 4, 'slot');
    final state = stateFor(deck);
    _hotCues[deck]![slot] = DjHotCue(
      slot: slot,
      positionMs: snapDjPositionToNearestBeat(state.positionMs, state.beatsMs),
    );
    _notify();
  }

  Future<void> triggerHotCue(DjDeckId deck, int slot) async {
    if (_disposed) return;
    final cue = _hotCues[deck]![slot];
    if (cue == null) return;
    await _decks[deck]!.seek(cue.positionMs);
    _notify();
  }

  Future<void> setAutoLoop(DjDeckId deck, int beats) async {
    if (_disposed) return;
    final state = stateFor(deck);
    final span = djLoopSpanAt(
      positionMs: state.positionMs,
      beats: beats,
      beatsMs: state.beatsMs,
    );
    if (span == null) return;
    // The 30 Hz snapshot loop owns the guarded wrap seek for this state.
    final loop = DjLoop(startMs: span.startMs, endMs: span.endMs, beats: beats);
    _decks[deck]!.setActiveLoop(loop);
    _loops[deck] = loop;
    _notify();
  }

  final Map<DjDeckId, DjLoop> _loops = {};

  void _refreshSnapshots() => unawaited(debugTick());

  /// One pass of the 33ms loop: refresh both deck snapshots, service any loop
  /// wrap, run the sync correction, notify.
  ///
  /// Exposed so the correction tests can step the loop against a fake clock.
  /// [_tickSync] takes its whole decision synchronously before its first await,
  /// so notifying ahead of the awaited rate command is not a race: the command
  /// was computed from the snapshot this pass just refreshed.
  @visibleForTesting
  Future<void> debugTick() async {
    if (_disposed) return;
    for (final controller in _decks.values) {
      controller.refreshSnapshot();
    }
    for (final entry in _loops.entries) {
      _requestLoopWrap(entry.key, entry.value);
    }
    final correcting = _tickSync();
    _notify();
    await correcting;
  }

  /// The beat-alignment correction, riding this pass rather than a timer of its
  /// own.
  ///
  /// docs/dj-deck-spec.md:312 asks DeckSync for "its own tighter loop" only to
  /// escape VoicePool's 150ms drift window; 33ms is already 4.5x tighter than
  /// that, and a second timer would be a third authority writing one deck's
  /// rate. The command throttle, not the sample rate, is what keeps the stream
  /// honest.
  Future<void> _tickSync() async {
    if (_disposed || _syncEngaged.isEmpty) return;
    final master = _syncMaster;
    if (master == null) return;
    final leader = stateFor(master);
    for (final deck in _syncEngaged.toList()) {
      await _correctSyncedDeck(deck, leader);
    }
  }

  Future<void> _correctSyncedDeck(DjDeckId deck, DjDeckState leader) async {
    final base = _syncBaseRates[deck];
    if (base == null) return;
    final follower = stateFor(deck);
    DjSyncPhaseReading? reading;
    var target = 0.0;
    // Two gates, not one. The tempo match only needs a trustworthy BPM; moving
    // a deck's rate to chase an untrustworthy grid pushes it off the beat.
    if (djSyncPhaseCorrectionAllowed(leader: leader, follower: follower)) {
      reading = djSyncPhaseReading(leader: leader, follower: follower);
      if (reading != null) {
        target = djSyncRateOffset(
          errorMs: reading.errorMs,
          pulseMs: reading.pulseMs,
          baseRate: base,
        );
      }
    }
    _traceSyncCorrection(deck, reading, target);
    final applied = _syncOffsets[deck] ?? 0;
    if ((target - applied).abs() <= kDjSyncRateEpsilon) return;
    final now = _clock();
    final last = _syncCommandAtMs[deck];
    if (last != null && now - last < kDjSyncCorrectionIntervalMs) return;
    if (!_syncCommandsInFlight.add(deck)) return;
    _syncCommandAtMs[deck] = now;
    _syncOffsets[deck] = target;
    try {
      await _decks[deck]!.setRate(base * (1 + target));
    } finally {
      _syncCommandsInFlight.remove(deck);
    }
  }

  /// Debug-only alignment trace, throttled to the command interval.
  ///
  /// Kept in the shipped source on purpose: the emulator has no way to read the
  /// beat error off the screen - the header clock and the waveform both lie on
  /// an API-seeded deck (#425) - so this line is the only device-side evidence
  /// that the loop converges rather than merely looking settled.
  void _traceSyncCorrection(
    DjDeckId deck,
    DjSyncPhaseReading? reading,
    double offset,
  ) {
    if (!kDebugMode) return;
    final now = _clock();
    final last = _syncTraceAtMs;
    if (last != null && now - last < kDjSyncCorrectionIntervalMs) return;
    _syncTraceAtMs = now;
    final error = reading == null
        ? 'unavailable'
        : '${reading.errorMs.toStringAsFixed(1)}ms';
    debugPrint(
      'OMP DJ sync deck=${deck.name} beat error=$error '
      'offset=${offset.toStringAsFixed(4)} '
      'rate=${stateFor(deck).rate.toStringAsFixed(6)}',
    );
  }

  void _requestLoopWrap(DjDeckId deck, DjLoop loop) {
    final state = stateFor(deck);
    if (!state.playing || state.positionMs < loop.endMs) return;
    if (!_loopWrapsInFlight.add(deck)) return;
    unawaited(_wrapLoop(deck, loop));
  }

  Future<void> _wrapLoop(DjDeckId deck, DjLoop loop) async {
    try {
      // A loop edit/exit that wins while a prior seek is pending must not be
      // followed by an obsolete wrap.
      if (identical(_loops[deck], loop)) {
        await _decks[deck]!.seek(loop.startMs);
      }
    } finally {
      _loopWrapsInFlight.remove(deck);
    }
  }

  DjLoop? activeLoopFor(DjDeckId deck) => _loops[deck];
  void clearLoop(DjDeckId deck) {
    if (_disposed) return;
    _loops.remove(deck);
    _decks[deck]!.setActiveLoop(null);
    _notify();
  }

  void setManualLoop(DjDeckId deck,
      {required int startMs, required int endMs}) {
    if (_disposed) return;
    if (endMs <= startMs) return;
    final loop = DjLoop(startMs: startMs, endMs: endMs, beats: 0);
    _loops[deck] = loop;
    _decks[deck]!.setActiveLoop(loop);
    _notify();
  }

  void setLoopIn(DjDeckId deck) {
    if (_disposed) return;
    final state = stateFor(deck);
    _pendingLoopInMs[deck] =
        snapDjPositionToNearestBeat(state.positionMs, state.beatsMs);
    _notify();
  }

  void setLoopOut(DjDeckId deck) {
    if (_disposed) return;
    final start = _pendingLoopInMs.remove(deck);
    if (start == null) return;
    final state = stateFor(deck);
    final end = snapDjPositionToNearestBeat(state.positionMs, state.beatsMs);
    setManualLoop(deck, startMs: start, endMs: end);
  }

  Future<void> stopAll() async {
    if (_disposed) return;
    _syncMaster = null;
    for (final follower in _syncEngaged) {
      _forgetSyncCorrection(follower);
    }
    _syncEngaged.clear();
    await Future.wait([for (final deck in _decks.values) deck.release()]);
    _notify();
  }

  /// Notifies unless this provider is already disposed.
  ///
  /// Every mutator here awaits the engine before it notifies, and the DJ route
  /// can pop mid-await: the continuation then resumes against a provider
  /// [dispose] has already torn down, and `notifyListeners` throws on a
  /// disposed `ChangeNotifier` with nothing to catch it. The 33 Hz snapshot
  /// loop had its own guard; the deck callbacks did not, so a play/pause tap
  /// raced against a back-navigation crashed the zone (#414).
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _snapshotTimer.cancel();
    for (final deck in _decks.values) {
      unawaited(deck.dispose());
    }
    super.dispose();
  }
}
