import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/engine/engine_audio_source_resolver.dart';
import '../../../core/engine/gain_envelope.dart';
import '../../../core/engine/voice.dart';
import '../../../core/cache/playback_cache_manager.dart';
import '../../../core/stems/stem_channel_source.dart';
import '../../../models/track.dart';
import '../../dj/engine/deck_controller.dart';
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
  late final Timer _snapshotTimer;
  bool _disposed = false;
  double _crossfader = .5;

  DjDeckState get deckA => stateFor(DjDeckId.a);
  DjDeckState get deckB => stateFor(DjDeckId.b);
  double get crossfader => _crossfader;
  DjDeckState stateFor(DjDeckId deck) => _decks[deck]!.state;
  List<DjHotCue> hotCuesFor(DjDeckId deck) =>
      _hotCues[deck]!.values.toList()..sort((a, b) => a.slot.compareTo(b.slot));

  /// Adapter kept separate from widget construction so tests and a future
  /// QueueTimeline projection can seed both decks without depending on UI.
  static List<DjDeckLoad> queueSeeds(QueueTrack? current, QueueTrack? next) => [
        if (current != null) _seedForTrack(current),
        if (next != null) _seedForTrack(next),
      ];

  static DjDeckLoad _seedForTrack(QueueTrack track) => DjDeckLoad(
        trackRef: track.playbackTrackId ?? track.id,
        queueItemId: track.queueItemId,
        title: track.title,
        queueTrack: track,
        durationMs: track.duration,
        beatsMs: track.analysis?.summary?.beatGrid?.beatsMs ?? const [],
        initialCueMs: track.analysis?.summary?.intro?.startMs ?? 0,
      );

  /// Loads current/next queue seeds. If neither is available the caller may
  /// provide a local-file picker seam (no file_picker dependency in the spike).
  Future<void> seed({
    QueueTrack? current,
    QueueTrack? next,
    DjFilePicker? filePicker,
  }) async {
    final seeds = queueSeeds(current, next);
    if (seeds.isEmpty && filePicker != null) {
      final picked = await filePicker();
      if (picked != null) seeds.add(picked);
    }
    if (seeds.isNotEmpty) await load(DjDeckId.a, seeds.first);
    if (seeds.length > 1) await load(DjDeckId.b, seeds[1]);
  }

  Future<void> load(DjDeckId deck, DjDeckLoad seed) async {
    await _decks[deck]!.load(seed);
    _applyDeckGains();
    notifyListeners();
  }

  Future<void> togglePlay(DjDeckId deck) async {
    final controller = _decks[deck]!;
    if (controller.state.playing) {
      await controller.pause();
    } else {
      await controller.play();
    }
    notifyListeners();
  }

  Future<void> seek(DjDeckId deck, int positionMs) async {
    await _decks[deck]!.seek(positionMs);
    notifyListeners();
  }

  Future<void> cuePress(DjDeckId deck) async {
    final controller = _decks[deck]!;
    final state = controller.state;
    _cueWasPlaying[deck] = state.playing;
    await controller.seek(state.loadedCueMs);
    if (!state.playing) {
      await controller.play();
    }
    notifyListeners();
  }

  Future<void> cueRelease(DjDeckId deck) async {
    final controller = _decks[deck]!;
    if (_cueWasPlaying.remove(deck) == false) {
      await controller.pause();
      await controller.seek(controller.state.loadedCueMs);
    }
    notifyListeners();
  }

  Future<void> setPitchPercent(DjDeckId deck, double percent) async {
    await _decks[deck]!.setRate(1 + percent.clamp(-25.0, 25.0) / 100);
    notifyListeners();
  }

  Future<void> nudgePitchStart(DjDeckId deck, double deltaPercent) async {
    _preNudgeRates.putIfAbsent(deck, () => stateFor(deck).rate);
    final base = _preNudgeRates[deck]!;
    await _decks[deck]!
        .setRate(base * (1 + deltaPercent.clamp(-2.0, 2.0) / 100));
    notifyListeners();
  }

  Future<void> nudgePitchEnd(DjDeckId deck) async {
    final rate = _preNudgeRates.remove(deck);
    if (rate == null) return;
    await _decks[deck]!.setRate(rate);
    notifyListeners();
  }

  Future<void> setChannelGain(DjDeckId deck, double gain) async {
    final controller = _decks[deck]!;
    controller.setChannelGain(gain);
    _applyDeckGains();
    notifyListeners();
  }

  Future<void> setCrossfader(double value) async {
    _crossfader = value.clamp(0.0, 1.0).toDouble();
    _applyDeckGains();
    notifyListeners();
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
    if (slot < 1 || slot > 4) throw RangeError.range(slot, 1, 4, 'slot');
    final state = stateFor(deck);
    _hotCues[deck]![slot] = DjHotCue(
      slot: slot,
      positionMs: snapDjPositionToNearestBeat(state.positionMs, state.beatsMs),
    );
    notifyListeners();
  }

  Future<void> triggerHotCue(DjDeckId deck, int slot) async {
    final cue = _hotCues[deck]![slot];
    if (cue == null) return;
    await _decks[deck]!.seek(cue.positionMs);
    notifyListeners();
  }

  Future<void> setAutoLoop(DjDeckId deck, int beats) async {
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
    notifyListeners();
  }

  final Map<DjDeckId, DjLoop> _loops = {};

  void _refreshSnapshots() {
    for (final controller in _decks.values) {
      controller.refreshSnapshot();
    }
    for (final entry in _loops.entries) {
      _requestLoopWrap(entry.key, entry.value);
    }
    if (!_disposed) notifyListeners();
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
    _loops.remove(deck);
    _decks[deck]!.setActiveLoop(null);
    notifyListeners();
  }

  void setManualLoop(DjDeckId deck,
      {required int startMs, required int endMs}) {
    if (endMs <= startMs) return;
    final loop = DjLoop(startMs: startMs, endMs: endMs, beats: 0);
    _loops[deck] = loop;
    _decks[deck]!.setActiveLoop(loop);
    notifyListeners();
  }

  void setLoopIn(DjDeckId deck) {
    final state = stateFor(deck);
    _pendingLoopInMs[deck] =
        snapDjPositionToNearestBeat(state.positionMs, state.beatsMs);
    notifyListeners();
  }

  void setLoopOut(DjDeckId deck) {
    final start = _pendingLoopInMs.remove(deck);
    if (start == null) return;
    final state = stateFor(deck);
    final end = snapDjPositionToNearestBeat(state.positionMs, state.beatsMs);
    setManualLoop(deck, startMs: start, endMs: end);
  }

  Future<void> stopAll() async {
    await Future.wait([for (final deck in _decks.values) deck.release()]);
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
