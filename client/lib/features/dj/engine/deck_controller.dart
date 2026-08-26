import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/engine/engine_audio_source_resolver.dart';
import '../../../core/engine/tempo_automation.dart';
import '../../../core/engine/timeline_model.dart';
import '../../../core/engine/voice.dart';
import '../../../models/timeline_clip.dart';
import '../../../models/track.dart';
import '../models/dj_deck_load_failure.dart';
import '../models/dj_deck_state.dart';
import '../models/dj_hot_cue.dart';

class DjDeckLoad {
  const DjDeckLoad({
    required this.trackRef,
    this.queueItemId,
    this.title,
    this.queueTrack,
    this.localUri,
    this.initialCueMs = 0,
    this.durationMs = 0,
    this.beatsMs = const [],
  });

  final String trackRef;
  final String? queueItemId;
  final String? title;
  final QueueTrack? queueTrack;

  /// Picker fallback. The prototype refuses every non-file URI.
  final Uri? localUri;
  final int initialCueMs;
  final int durationMs;
  final List<int> beatsMs;
}

/// Direct Voice adapter used only by the exploration branch.
///
/// TODO(dj-production): replace this dual-Voice path with a projection through
/// QueueTimelineController, per docs/adr/0001-playback-timeline-source-of-truth.md.
class DeckController {
  DeckController({
    required this.deckId,
    required Voice voice,
    required EngineAudioSourceResolver resolver,
    this.slew = const Duration(milliseconds: 15),
  })  : _voice = voice,
        _resolver = resolver,
        _state = DjDeckState(deckId: deckId);

  final DjDeckId deckId;
  final Voice _voice;
  final EngineAudioSourceResolver _resolver;
  final Duration slew;
  DjDeckState _state;
  Timer? _volumeSlew;
  double? _pendingVolume;
  Completer<void>? _volumeCompletion;

  DjDeckState get state => _state;
  Voice get voice => _voice;

  // Initialized here instead of a late initializer to retain a stable snapshot
  // before a deck has a queue seed.
  DeckController._withState({
    required this.deckId,
    required Voice voice,
    required EngineAudioSourceResolver resolver,
    required DjDeckState state,
    this.slew = const Duration(milliseconds: 15),
  })  : _voice = voice,
        _resolver = resolver,
        _state = state;

  factory DeckController.empty({
    required DjDeckId deckId,
    required Voice voice,
    required EngineAudioSourceResolver resolver,
    Duration slew = const Duration(milliseconds: 15),
  }) =>
      DeckController._withState(
        deckId: deckId,
        voice: voice,
        resolver: resolver,
        slew: slew,
        state: DjDeckState(deckId: deckId),
      );

  /// Loads [load], or records why it was refused.
  ///
  /// Total for every refusable input: the local/cache-only policy is unchanged
  /// (docs/dj-deck-spec.md:117) but a refusal is now [DjDeckState.loadFailure]
  /// rather than a thrown [StateError] escaping into `dj_screen.dart`'s
  /// post-frame callback (#409).
  Future<void> load(DjDeckLoad load) async {
    final localUri = load.localUri;
    if (localUri != null && localUri.scheme != 'file') {
      await _refuse(load, DjDeckLoadFailureKind.pickerNotLocal);
      return;
    }
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'dj-${deckId.name}-${load.trackRef}',
        trackId: load.trackRef,
        sourceDurationMs: load.durationMs <= 0 ? 1000 : load.durationMs,
        sourceStartMs: 0,
        sourceEndMs: load.durationMs <= 0 ? 1000 : load.durationMs,
        timelineStartMs: 0,
      ),
      audioSourceRef: load.trackRef,
      queueItemId: load.queueItemId,
    );
    // The two catches below are the only broad catches on the deck path: a deck
    // seed must not escape into dj_screen.dart's un-awaited post-frame callback.
    ResolvedAudioSource? resolved;
    try {
      resolved = localUri == null ? await _resolver.resolve(clip) : null;
    } catch (error) {
      await _refuse(
        load,
        DjDeckLoadFailureKind.sourceUnavailable,
        detail: '$error',
      );
      return;
    }
    if (kDebugMode) {
      debugPrint(
        'OMP DJ deck ${deckId.name} seed trackRef=${load.trackRef} '
        "resolved=${resolved?.isLocal == true ? 'local' : 'remote'}",
      );
    }
    if (resolved != null && !resolved.isLocal) {
      await _refuse(load, DjDeckLoadFailureKind.unavailableOffline);
      return;
    }
    try {
      await _voice.load(localUri ?? resolved!.uri);
    } catch (error) {
      await _refuse(
        load,
        DjDeckLoadFailureKind.sourceUnavailable,
        detail: '$error',
      );
      return;
    }
    // A freshly built success state carries loadFailure == null, so a recovered
    // deck needs no explicit clearing.
    _state = DjDeckState(
      deckId: deckId,
      queueItemId: load.queueItemId,
      trackRef: load.trackRef,
      title: load.title,
      queueTrack: load.queueTrack,
      durationMs: load.durationMs,
      loadedCueMs: load.initialCueMs.clamp(0, load.durationMs).toInt(),
      beatsMs: List.unmodifiable(load.beatsMs),
    );
  }

  /// Records a refusal for [load] without touching the voice.
  ///
  /// The provider's belt-and-braces seed guard uses this so a deck refusal is
  /// always set through its controller rather than by mutating shared state.
  void markLoadFailure(
    DjDeckLoad load, {
    DjDeckLoadFailureKind kind = DjDeckLoadFailureKind.sourceUnavailable,
    String? detail,
  }) {
    _state = DjDeckState(
      deckId: deckId,
      title: load.title,
      queueTrack: load.queueTrack,
      loadFailure: DjDeckLoadFailure(
        kind: kind,
        trackRef: load.trackRef,
        title: load.title,
        detail: detail,
      ),
    );
  }

  Future<void> _refuse(
    DjDeckLoad load,
    DjDeckLoadFailureKind kind, {
    String? detail,
  }) async {
    // A deck that already held a track must not keep its voice loaded for a
    // track the lane no longer shows.
    if (_state.trackRef != null) await _voice.release();
    markLoadFailure(load, kind: kind, detail: detail);
  }

  Future<void> play() async {
    await _voice.play();
    _state = _state.copyWith(playing: true);
  }

  Future<void> pause() async {
    await _voice.pause();
    _state = _state.copyWith(playing: false);
  }

  Future<void> seek(int positionMs) async {
    final safe = positionMs.clamp(0, _state.durationMs).toInt();
    await _voice.seekLocal(safe);
    _state = _state.copyWith(positionMs: safe);
  }

  Future<void> setRate(
    double rate, {
    String pitchMode = pitchModePreserve,
  }) async {
    final safe = rate.clamp(0.75, 1.25).toDouble();
    await _voice.setSpeed(safe);
    await _voice.setPitch(pitchFactorForRate(rate: safe, pitchMode: pitchMode));
    _state = _state.copyWith(rate: safe, pitchMode: pitchMode);
  }

  /// Applies a live output multiplier without changing the channel fader's
  /// logical value in the immutable deck snapshot.
  Future<void> setOutputVolume(double gain) {
    final target = gain.clamp(0.0, 1.0).toDouble();
    _pendingVolume = target;
    _volumeSlew?.cancel();
    _volumeCompletion?.complete();
    final completer = Completer<void>();
    _volumeCompletion = completer;
    _volumeSlew = Timer(slew, () async {
      final next = _pendingVolume;
      _pendingVolume = null;
      if (next != null) await _voice.setVolume(next);
      if (!completer.isCompleted) completer.complete();
      if (identical(_volumeCompletion, completer)) _volumeCompletion = null;
    });
    return completer.future;
  }

  void setChannelGain(double gain) {
    _state = _state.copyWith(channelGain: gain.clamp(0.0, 1.0).toDouble());
  }

  void setActiveLoop(DjLoop? loop) {
    _state = _state.copyWith(activeLoop: loop, clearLoop: loop == null);
  }

  void refreshSnapshot() {
    _state = _state.copyWith(
      positionMs: (_voice.currentLocalPositionMs ?? _state.positionMs)
          .clamp(0, _state.durationMs)
          .toInt(),
      playing: _voice.isPlaying,
    );
  }

  Future<void> dispose() async {
    _cancelPendingVolume();
    await _voice.release();
    await _voice.dispose();
  }

  Future<void> release() async {
    _cancelPendingVolume();
    await _voice.release();
    _state = _state.copyWith(playing: false);
  }

  void _cancelPendingVolume() {
    _volumeSlew?.cancel();
    _volumeSlew = null;
    final completion = _volumeCompletion;
    _volumeCompletion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }
}
