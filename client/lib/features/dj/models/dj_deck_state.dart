import '../../../core/engine/tempo_automation.dart';
import '../../../models/track.dart';
import 'dj_hot_cue.dart';

enum DjDeckId { a, b }

/// Immutable presentation snapshot for one prototype deck.
class DjDeckState {
  const DjDeckState({
    required this.deckId,
    this.queueItemId,
    this.trackRef,
    this.title,
    this.queueTrack,
    this.durationMs = 0,
    this.positionMs = 0,
    this.playing = false,
    this.rate = 1,
    this.pitchMode = pitchModePreserve,
    this.channelGain = 1,
    this.loadedCueMs = 0,
    this.activeLoop,
    this.beatsMs = const [],
  });

  final DjDeckId deckId;
  final String? queueItemId;

  /// Numeric track id / resolver-backed audio source reference.
  final String? trackRef;
  final String? title;

  /// Hydrated metadata and analysis for header/waveform consumers.
  final QueueTrack? queueTrack;
  final int durationMs;
  final int positionMs;
  final bool playing;
  final double rate;
  final String pitchMode;
  final double channelGain;
  final int loadedCueMs;
  final DjLoop? activeLoop;
  final List<int> beatsMs;

  double get ratePercent => (rate - 1) * 100;
  bool get isLoaded => trackRef != null;

  double? get bpm {
    final summary = queueTrack?.analysis?.summary;
    return summary?.bpm?.numericValue?.toDouble() ?? summary?.beatGrid?.bpm;
  }

  String? get musicalKey => queueTrack?.analysis?.summary?.key?.textValue;
  String? get camelot => queueTrack?.analysis?.summary?.camelot?.textValue;

  /// One-based beat in bar. Unknown analysis deliberately remains blank.
  int? get beatPhase {
    final analysis = queueTrack?.analysis;
    if (analysis == null) return null;
    final tempo = ClipTempoMetadata.fromTrackAnalysis(analysis);
    final beatsPerBar = tempo.beatsPerBar;
    if (!tempo.hasReliableDownbeats ||
        beatsPerBar == null ||
        beatsPerBar <= 0 ||
        tempo.beatsMs.isEmpty) {
      return null;
    }

    int? downbeat;
    for (final marker in tempo.downbeatsMs) {
      if (marker > positionMs) break;
      downbeat = marker;
    }
    if (downbeat == null) return null;
    var beatInBar = 1;
    for (final beat in tempo.beatsMs) {
      if (beat <= downbeat) continue;
      if (beat > positionMs) break;
      beatInBar++;
    }
    return (beatInBar - 1) % beatsPerBar + 1;
  }

  DjDeckState copyWith({
    String? queueItemId,
    String? trackRef,
    String? title,
    QueueTrack? queueTrack,
    int? durationMs,
    int? positionMs,
    bool? playing,
    double? rate,
    String? pitchMode,
    double? channelGain,
    int? loadedCueMs,
    DjLoop? activeLoop,
    bool clearLoop = false,
    List<int>? beatsMs,
  }) =>
      DjDeckState(
        deckId: deckId,
        queueItemId: queueItemId ?? this.queueItemId,
        trackRef: trackRef ?? this.trackRef,
        title: title ?? this.title,
        queueTrack: queueTrack ?? this.queueTrack,
        durationMs: durationMs ?? this.durationMs,
        positionMs: positionMs ?? this.positionMs,
        playing: playing ?? this.playing,
        rate: rate ?? this.rate,
        pitchMode: pitchMode ?? this.pitchMode,
        channelGain: channelGain ?? this.channelGain,
        loadedCueMs: loadedCueMs ?? this.loadedCueMs,
        activeLoop: clearLoop ? null : activeLoop ?? this.activeLoop,
        beatsMs: beatsMs ?? this.beatsMs,
      );
}
