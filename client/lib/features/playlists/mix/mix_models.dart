import '../../../models/mix_plan.dart';
import '../../../shared/models/track.dart';

/// One automatic transition between two adjacent tracks in a blended playlist.
///
/// Mirrors the backend's auto-mix response entry:
/// `{ index, outgoingTrackId, incomingTrackId, preset, bars, overlapMs,
///    confidence: { keyMatch, tempoMatched, tempoShift, simpleFade } }`.
class MixTransition {
  final int index;
  final int outgoingTrackId;
  final int incomingTrackId;
  final String preset;
  final int? bars;
  final int overlapMs;
  final bool keyMatch;
  final bool tempoMatched;
  final bool tempoShift;
  final bool simpleFade;

  const MixTransition({
    required this.index,
    required this.outgoingTrackId,
    required this.incomingTrackId,
    required this.preset,
    required this.overlapMs,
    this.bars,
    this.keyMatch = false,
    this.tempoMatched = false,
    this.tempoShift = false,
    this.simpleFade = false,
  });

  factory MixTransition.fromJson(Map<String, dynamic> json) {
    final confidence = json['confidence'];
    final confidenceMap = confidence is Map<String, dynamic>
        ? confidence
        : const <String, dynamic>{};
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
      tempoShift: confidenceMap['tempoShift'] == true,
      simpleFade: confidenceMap['simpleFade'] == true,
    );
  }

  /// Confidence semantics shared with the seam connector:
  /// teal for a key match, amber for tempo-only alignment or a tempo shift,
  /// gray for a simple fade.
  MixTransitionConfidence get confidence {
    // Render the actual fallback first, then the more conservative tempo
    // signal. Key compatibility alone must not make a shortened Fade look like
    // a full-confidence Blend.
    if (simpleFade) return MixTransitionConfidence.simpleFade;
    if (tempoShift) return MixTransitionConfidence.tempoShift;
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
  final MixPlan? mixPlan;

  const AutoMixResult({
    required this.transitionsByPair,
    required this.transitions,
    this.mixPlan,
  });

  factory AutoMixResult.fromJson(Map<String, dynamic> json) {
    final rawTransitions = json['transitions'];
    final transitions = rawTransitions is List
        ? rawTransitions
            .whereType<Map<String, dynamic>>()
            .map(MixTransition.fromJson)
            .toList()
        : <MixTransition>[];
    MixPlan? mixPlan;
    final rawMixPlan = json['mixPlan'];
    if (rawMixPlan is Map) {
      try {
        mixPlan = MixPlan.fromJson(Map<String, dynamic>.from(rawMixPlan));
      } on Object {
        // Transition rendering remains tolerant of older or partial servers.
        // Playback only takes the canonical-plan path when this parsed cleanly.
      }
    }
    return AutoMixResult(
      transitions: transitions,
      mixPlan: mixPlan,
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
