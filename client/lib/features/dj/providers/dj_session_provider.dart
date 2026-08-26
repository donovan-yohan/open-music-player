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

/// The only mutable screen state authority for the direct-Voice prototype.
///
/// TODO(dj-production): project QueueTimelineController instead; see
/// docs/adr/0001-playback-timeline-source-of-truth.md.
class DjSessionProvider extends ChangeNotifier {
  DjSessionProvider({
    required DeckController deckA,
    required DeckController deckB,
    StemChannelSource? stems,
  })  : _decks = {DjDeckId.a: deckA, DjDeckId.b: deckB},
        stems = stems ?? const UnavailableStemChannelSource() {
    _snapshotTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _refreshSnapshots();
    });
  }

  factory DjSessionProvider.prototype({
    VoiceFactory? voiceFactory,
    EngineAudioSourceResolver? resolver,
    PlaybackCacheManager? cacheManager,
    StemChannelSource? stems,
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
  /// * [deck] is an engaged follower: it disengages and **keeps its current
  ///   rate**. Snapping back to 1.0 would be an audible tempo jump mid-blend.
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
      _notify();
      // Nothing was applied; this describes the match a re-engage would use.
      return syncMatchFor(deck);
    }
    final match = djSyncTempoMatch(
      leader: stateFor(other),
      follower: stateFor(deck),
    );
    if (!match.isMatched) return match;
    // Every engaged case resolves to the same shape: the other deck leads and
    // this deck is the only follower. A two-deck session has no third state.
    _syncMaster = other;
    _syncEngaged
      ..clear()
      ..add(deck);
    await _decks[deck]!.setRate(match.targetRate);
    _notify();
    return match;
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
      _syncEngaged.clear();
      return;
    }
    _syncEngaged.remove(deck);
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

  void _refreshSnapshots() {
    for (final controller in _decks.values) {
      controller.refreshSnapshot();
    }
    for (final entry in _loops.entries) {
      _requestLoopWrap(entry.key, entry.value);
    }
    _notify();
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
