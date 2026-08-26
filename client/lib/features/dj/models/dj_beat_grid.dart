import '../../../core/engine/tempo_automation.dart';
import '../../../models/track_analysis.dart';

/// Memoises one ruler per analysis object. Weak keys, so a superseded analysis
/// snapshot is collected with its ruler and no eviction policy is needed.
final Expando<DjBeatRuler> _rulerByAnalysis = Expando<DjBeatRuler>('DjBeatRuler');

/// One position inside the phrase/bar/beat structure (#416).
///
/// [phrase] is 1-based from the first downbeat and is non-positive before it:
/// the grid genuinely extends backwards, but a zero or negative phrase number
/// would be a lie about structure, so callers omit it there.
class DjBeatPosition {
  const DjBeatPosition({
    required this.barInPhrase,
    required this.beatInBar,
    required this.phrase,
  });

  /// 1..phraseLengthBars.
  final int barInPhrase;

  /// 1..beatsPerBar.
  final int beatInBar;

  /// 1-based from the first downbeat; <= 0 before it.
  final int phrase;

  bool get isBeforeAnchor => phrase <= 0;

  /// `2.3 · phrase 5`, or a bare `4.4` before the anchor.
  String get label =>
      '$barInPhrase.$beatInBar${isBeforeAnchor ? '' : ' · phrase $phrase'}';

  @override
  bool operator ==(Object other) =>
      other is DjBeatPosition &&
      other.barInPhrase == barInPhrase &&
      other.beatInBar == beatInBar &&
      other.phrase == phrase;

  @override
  int get hashCode => Object.hash(barInPhrase, beatInBar, phrase);

  @override
  String toString() => 'DjBeatPosition($label)';
}

/// Display-only projection of the effective beat grid (#416).
///
/// Built from [TrackAnalysis.effectiveTiming] — never from the raw summary and
/// never by merging overrides here; `ClipTempoMetadata` remains the only
/// interpreter (docs/AUDIO_ANALYZER_SERVICE.md, docs/dj-deck-spec.md).
///
/// [numbered] is `ClipTempoMetadata.hasReliableDownbeats`, i.e. the tier A/B
/// split in docs/dj-deck-spec.md:82-83: generated meter and phase are
/// compatibility data, so their bars are drawn but never numbered.
class DjBeatRuler {
  DjBeatRuler._({
    required this.beatsMs,
    required this.barStartsMs,
    required this.beatsPerBar,
    required this.phraseLengthBars,
    required this.numbered,
    required this.anchorBeatIndex,
  });

  /// Effective beat grid, strictly increasing.
  final List<int> beatsMs;

  /// Downbeat anchors as analysis reports them. Empty means bars are unknown,
  /// which is the beat-ticks-only case.
  final List<int> barStartsMs;

  /// >= 1.
  final int beatsPerBar;

  /// `effectiveTiming.phraseLengthBars ?? 4`, so a default 4/4 phrase is the
  /// 16 beats #416 asks for.
  final int phraseLengthBars;

  /// True only for manual (or legacy) downbeat authority.
  final bool numbered;

  /// Index into [beatsMs] of the first bar anchor; -1 when there is none.
  final int anchorBeatIndex;

  bool get hasBarAnchor => anchorBeatIndex >= 0;

  List<int>? _barLinesMs;
  List<({int ms, int phrase})>? _phraseMarkers;

  /// Bar lines projected across the whole grid from [anchorBeatIndex].
  ///
  /// The analyzer's `downbeats.positions_ms` often covers only the opening
  /// bars; projecting keeps the ruler continuous and keeps every tick in
  /// agreement with [positionAt], which projects the same way.
  List<int> get barLinesMs {
    final cached = _barLinesMs;
    if (cached != null) return cached;
    if (!hasBarAnchor) return _barLinesMs = const <int>[];
    final lines = <int>[];
    for (var i = anchorBeatIndex % beatsPerBar;
        i < beatsMs.length;
        i += beatsPerBar) {
      lines.add(beatsMs[i]);
    }
    return _barLinesMs = List.unmodifiable(lines);
  }

  /// Phrase markers with their 1-based phrase number.
  ///
  /// Bars before the anchor get a bar line but never a phrase marker: numbering
  /// them would require a non-positive phrase index.
  List<({int ms, int phrase})> get phraseMarkers {
    final cached = _phraseMarkers;
    if (cached != null) return cached;
    if (!hasBarAnchor) return _phraseMarkers = const <({int ms, int phrase})>[];
    final markers = <({int ms, int phrase})>[];
    final beatsPerPhrase = beatsPerBar * phraseLengthBars;
    for (var i = anchorBeatIndex; i < beatsMs.length; i += beatsPerPhrase) {
      markers.add((
        ms: beatsMs[i],
        phrase: (i - anchorBeatIndex) ~/ beatsPerPhrase + 1,
      ));
    }
    return _phraseMarkers = List.unmodifiable(markers);
  }

  /// The ruler for [analysis], or null when there is no effective beat grid.
  static DjBeatRuler? forAnalysis(TrackAnalysis? analysis) {
    if (analysis == null) return null;
    final cached = _rulerByAnalysis[analysis];
    if (cached != null) return cached;
    final timing = analysis.effectiveTiming;
    final beats = _strictlyIncreasing(timing.beatGrid?.beatsMs ?? const <int>[]);
    if (beats.isEmpty) return null;

    final meter = timing.meter?.beatsPerBar;
    final declaredBeatsPerBar = meter != null && meter > 0 ? meter : null;
    final phaseIndex = timing.downbeatPhase?.index;

    final downbeats =
        _strictlyIncreasing(timing.downbeats?.positionsMs ?? const <int>[]);
    List<int> barStarts;
    if (downbeats.isNotEmpty) {
      barStarts = downbeats;
    } else if (declaredBeatsPerBar != null &&
        phaseIndex != null &&
        phaseIndex >= 0 &&
        phaseIndex < declaredBeatsPerBar &&
        phaseIndex < beats.length) {
      barStarts = List.unmodifiable([
        for (var i = phaseIndex; i < beats.length; i += declaredBeatsPerBar)
          beats[i],
      ]);
    } else {
      barStarts = const <int>[];
    }

    var beatsPerBar = declaredBeatsPerBar;
    if (beatsPerBar == null && barStarts.length >= 2) {
      final stride = _nearestBeatIndex(beats, barStarts[1]) -
          _nearestBeatIndex(beats, barStarts[0]);
      if (stride >= 1) beatsPerBar = stride;
    }
    beatsPerBar ??= 4;

    final phraseBars = timing.phraseLengthBars;
    final ruler = DjBeatRuler._(
      beatsMs: beats,
      barStartsMs: barStarts,
      beatsPerBar: beatsPerBar,
      phraseLengthBars: phraseBars != null && phraseBars > 0 ? phraseBars : 4,
      numbered: ClipTempoMetadata.fromTrackAnalysis(analysis)
          .hasReliableDownbeats,
      anchorBeatIndex:
          barStarts.isEmpty ? -1 : _nearestBeatIndex(beats, barStarts.first),
    );
    _rulerByAnalysis[analysis] = ruler;
    return ruler;
  }

  /// Bar/beat/phrase at [positionMs], or null when there is no bar anchor.
  ///
  /// Floor division throughout, so positions before the anchor are exact rather
  /// than clamped to the first bar.
  DjBeatPosition? positionAt(int positionMs) {
    if (!hasBarAnchor) return null;
    final delta = _lastBeatIndexAtOrBefore(beatsMs, positionMs) -
        anchorBeatIndex;
    final bars = _floorDiv(delta, beatsPerBar);
    final phraseIndex = _floorDiv(bars, phraseLengthBars);
    return DjBeatPosition(
      barInPhrase: bars - phraseIndex * phraseLengthBars + 1,
      beatInBar: delta - bars * beatsPerBar + 1,
      phrase: phraseIndex + 1,
    );
  }

  /// Fraction through the current beat, 0..1. Used by the unnumbered pulse.
  ///
  /// Returns null before the grid starts or after its last beat, where there is
  /// no beat to be inside of.
  double? beatFractionAt(int positionMs) {
    final index = _lastBeatIndexAtOrBefore(beatsMs, positionMs);
    if (index < 0 || index >= beatsMs.length - 1) return null;
    final start = beatsMs[index];
    final span = beatsMs[index + 1] - start;
    if (span <= 0) return null;
    return ((positionMs - start) / span).clamp(0.0, 1.0).toDouble();
  }
}

int _floorDiv(int a, int b) => (a - (a % b + b) % b) ~/ b;

/// Index of the last entry <= [value], or -1 when [value] precedes the grid.
int _lastBeatIndexAtOrBefore(List<int> sorted, int value) {
  var low = 0;
  var high = sorted.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (sorted[mid] <= value) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low - 1;
}

int _nearestBeatIndex(List<int> sorted, int value) {
  final before = _lastBeatIndexAtOrBefore(sorted, value);
  if (before < 0) return 0;
  if (before >= sorted.length - 1) return sorted.length - 1;
  final after = before + 1;
  return (value - sorted[before]) <= (sorted[after] - value) ? before : after;
}

/// Analysis marker arrays are contractually sorted; a malformed one is repaired
/// here rather than corrupting every binary search downstream.
List<int> _strictlyIncreasing(List<int> values) {
  if (values.isEmpty) return const <int>[];
  var ordered = true;
  for (var i = 1; i < values.length; i++) {
    if (values[i] <= values[i - 1]) {
      ordered = false;
      break;
    }
  }
  if (ordered) return List.unmodifiable(values);
  final sorted = values.toList()..sort();
  final deduped = <int>[sorted.first];
  for (final value in sorted.skip(1)) {
    if (value != deduped.last) deduped.add(value);
  }
  return List.unmodifiable(deduped);
}
