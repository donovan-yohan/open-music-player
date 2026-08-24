import '../../../models/track_analysis.dart';

/// Pure client-side ordering helpers for the mixed playlist view.
///
/// Greedy nearest-neighbor over BPM proximity and Camelot key distance,
/// starting from the current first track (which stays in place).
class MixReorder {
  /// Returns a permutation of [0, analyses.length) ordered by greedy
  /// nearest-neighbor from whichever track is currently first. Unanalyzed
  /// tracks keep their relative order at the end of the permutation.
  static List<int> orderIndices(List<TrackAnalysis?> analyses) {
    final analyzed = <int>[];
    final unanalyzed = <int>[];
    for (var i = 0; i < analyses.length; i++) {
      final summary = analyses[i]?.summary;
      final hasBpm = summary?.bpm?.numericValue != null;
      final hasCamelot = _parseCamelot(summary?.camelot?.textValue) != null;
      if (hasBpm || hasCamelot) {
        analyzed.add(i);
      } else {
        unanalyzed.add(i);
      }
    }
    if (analyzed.length < 2) {
      return List.generate(analyses.length, (index) => index);
    }

    final ordered = <int>[analyzed.first];
    final remaining = analyzed.sublist(1);
    while (remaining.isNotEmpty) {
      final lastIndex = ordered.last;
      var bestSlot = 0;
      var bestCost = double.infinity;
      for (var slot = 0; slot < remaining.length; slot++) {
        final cost =
            _distance(analyses[lastIndex], analyses[remaining[slot]]);
        if (cost < bestCost) {
          bestCost = cost;
          bestSlot = slot;
        }
      }
      ordered.add(remaining.removeAt(bestSlot));
    }

    return [...ordered, ...unanalyzed];
  }

  static double _distance(TrackAnalysis? a, TrackAnalysis? b) {
    final bpmA = a?.summary?.bpm?.numericValue?.toDouble();
    final bpmB = b?.summary?.bpm?.numericValue?.toDouble();
    final bpmDistance = bpmA == null || bpmB == null ? 12.0 : (bpmA - bpmB).abs();
    final keyDistance = camelotDistance(
      a?.summary?.camelot?.textValue,
      b?.summary?.camelot?.textValue,
    );
    // Equal weighting: BPM normalized to ~decade steps, key on wheel hops.
    return bpmDistance / 10 + keyDistance;
  }

  /// Distance on the Camelot wheel: same key = 0, one number step or the same
  /// number across A/B = 1, otherwise the shortest path around the wheel.
  /// Missing analysis on either side returns a neutral penalty of 6.
  static int camelotDistance(String? rawA, String? rawB) {
    final a = _parseCamelot(rawA);
    final b = _parseCamelot(rawB);
    if (a == null || b == null) return 6;
    final direct = (a.$1 - b.$1).abs();
    final wrapped = 12 - direct;
    final letterPenalty = a.$2 != b.$2 ? 1 : 0;
    return (direct <= wrapped ? direct : wrapped) + letterPenalty;
  }

  static (int, String)? _parseCamelot(String? value) {
    final text = value?.trim().toUpperCase();
    if (text == null) return null;
    final match = RegExp(r'^([1-9]|1[0-2])([AB])$').firstMatch(text);
    if (match == null) return null;
    return (int.parse(match.group(1)!), match.group(2)!);
  }
}
