import '../../../shared/models/track.dart';

/// One automatic transition between two adjacent tracks in a blended playlist.
///
/// Mirrors the backend's auto-mix response entry:
/// `{ index, outgoingTrackId, incomingTrackId, preset, bars, overlapMs,
///    confidence: { keyMatch, tempoMatched } }`.
class MixTransition {
  final int index;
  final int outgoingTrackId;
  final int incomingTrackId;
  final String preset;
  final int? bars;
  final int overlapMs;
  final bool keyMatch;
  final bool tempoMatched;

  const MixTransition({
    required this.index,
    required this.outgoingTrackId,
    required this.incomingTrackId,
    required this.preset,
    required this.overlapMs,
    this.bars,
    this.keyMatch = false,
    this.tempoMatched = false,
  });

  factory MixTransition.fromJson(Map<String, dynamic> json) {
    final confidence = json['confidence'];
    final confidenceMap =
        confidence is Map<String, dynamic> ? confidence : const <String, dynamic>{};
    return MixTransition(
      index: (json['index'] as num?)?.toInt() ?? 0,
      outgoingTrackId: (json['outgoingTrackId'] as num?)?.toInt() ?? 0,
      incomingTrackId: (json['incomingTrackId'] as num?)?.toInt() ?? 0,
      preset: (json['preset'] as String?)?.trim().isNotEmpty == true
          ? json['preset'] as String
          : 'Fade',
      bars: (json['bars'] as num?)?.toInt(),
      overlapMs: (json['overlapMs'] as num?)?.toInt() ?? 0,
      keyMatch: confidenceMap['keyMatch'] == true,
      tempoMatched: confidenceMap['tempoMatched'] == true,
    );
  }

  /// Confidence semantics shared with the seam connector:
  /// teal for a key match, amber for a tempo shift, gray for a simple fade.
  MixTransitionConfidence get confidence {
    if (keyMatch) return MixTransitionConfidence.keyMatch;
    if (tempoMatched) return MixTransitionConfidence.tempoShift;
    return MixTransitionConfidence.simpleFade;
  }

  /// Human label for the overlap: seconds always, bars when known.
  String overlapLabel() {
    final seconds = (overlapMs / 1000).round();
    final barsValue = bars;
    if (barsValue != null && barsValue > 0) {
      return '${seconds}s · $barsValue bars';
    }
    return '${seconds}s';
  }
}

enum MixTransitionConfidence { keyMatch, tempoShift, simpleFade }

/// Parsed response body of POST /playlists/{id}/auto-mix.
class AutoMixResult {
  /// Transitions keyed by "$outgoingTrackId-$incomingTrackId".
  final Map<String, MixTransition> transitionsByPair;
  final List<MixTransition> transitions;

  const AutoMixResult({
    required this.transitionsByPair,
    required this.transitions,
  });

  factory AutoMixResult.fromJson(Map<String, dynamic> json) {
    final rawTransitions = json['transitions'];
    final transitions = rawTransitions is List
        ? rawTransitions
            .whereType<Map<String, dynamic>>()
            .map(MixTransition.fromJson)
            .toList()
        : <MixTransition>[];
    return AutoMixResult(
      transitions: transitions,
      transitionsByPair: {
        for (final transition in transitions)
          '${transition.outgoingTrackId}-${transition.incomingTrackId}':
              transition,
      },
    );
  }

  MixTransition? between(Track outgoing, Track incoming) =>
      transitionsByPair['${outgoing.id}-${incoming.id}'];
}
