/// Inline trim selection for a queued track.
///
/// Holds separate entry ([startOffsetMs]) and exit ([endOffsetMs]) points as
/// integer milliseconds, plus the owning track's [trackDurationMs]. All values
/// are kept valid by construction:
///   * entry >= 0
///   * exit <= track duration
///   * entry + effective minimum <= exit, where the effective minimum is
///     [minPlayableMs] capped to the track duration for sub-second tracks
/// Offsets snap to the [snapMs] grid so drag interactions feel stable.
class TrimRange {
  final int startOffsetMs;
  final int endOffsetMs;
  final int trackDurationMs;

  /// Shortest playable segment we allow between entry and exit.
  static const int minPlayableMs = 1000;

  /// Offsets snap to this grid (ms) for stable, predictable trimming.
  static const int snapMs = 100;

  const TrimRange._(
    this.startOffsetMs,
    this.endOffsetMs,
    this.trackDurationMs,
  );

  /// The whole track selected — nothing skipped, nothing cut.
  factory TrimRange.full(int trackDurationMs) =>
      TrimRange._(0, trackDurationMs, trackDurationMs);

  /// Build a valid range from arbitrary (possibly invalid) offsets.
  factory TrimRange.clamped({
    required int trackDurationMs,
    required int startOffsetMs,
    required int endOffsetMs,
  }) {
    final dur = trackDurationMs < 0 ? 0 : trackDurationMs;
    var start = _clamp(_snap(startOffsetMs), 0, dur);
    var end = _clamp(_snap(endOffsetMs), 0, dur);

    final minPlayable = _effectiveMinPlayable(dur);

    // Guarantee the effective minimum playable segment: push the exit out
    // first, and if that runs past the track end, pull the entry back instead.
    if (end - start < minPlayable) {
      end = start + minPlayable;
      if (end > dur) {
        end = dur;
        start = _clamp(dur - minPlayable, 0, dur);
      }
    }
    return TrimRange._(start, end, dur);
  }

  /// New range with the entry point moved to [ms] (clamped + snapped).
  TrimRange withStart(int ms) {
    final minPlayable = _effectiveMinPlayable(trackDurationMs);
    final start = _clamp(_snap(ms), 0, endOffsetMs - minPlayable);
    return TrimRange._(start, endOffsetMs, trackDurationMs);
  }

  /// New range with the exit point moved to [ms] (clamped + snapped).
  TrimRange withEnd(int ms) {
    final minPlayable = _effectiveMinPlayable(trackDurationMs);
    final end = _clamp(_snap(ms), startOffsetMs + minPlayable, trackDurationMs);
    return TrimRange._(startOffsetMs, end, trackDurationMs);
  }

  int get selectedDurationMs => endOffsetMs - startOffsetMs;
  int get skippedIntroMs => startOffsetMs;
  int get cutTailMs => trackDurationMs - endOffsetMs;

  bool get isFullTrack => startOffsetMs == 0 && endOffsetMs == trackDurationMs;

  /// Fraction [0,1] of the track where the entry point sits.
  double get startFraction =>
      trackDurationMs <= 0 ? 0 : startOffsetMs / trackDurationMs;

  /// Fraction [0,1] of the track where the exit point sits.
  double get endFraction =>
      trackDurationMs <= 0 ? 1 : endOffsetMs / trackDurationMs;

  Map<String, dynamic> toJson() => {
        'startOffsetMs': startOffsetMs,
        'endOffsetMs': endOffsetMs,
        'trackDurationMs': trackDurationMs,
      };

  factory TrimRange.fromJson(Map<String, dynamic> json) => TrimRange.clamped(
        trackDurationMs: (json['trackDurationMs'] as num).toInt(),
        startOffsetMs: (json['startOffsetMs'] as num).toInt(),
        endOffsetMs: (json['endOffsetMs'] as num).toInt(),
      );

  static int _snap(int ms) => ((ms / snapMs).round()) * snapMs;

  static int _effectiveMinPlayable(int trackDurationMs) {
    if (trackDurationMs <= 0) return 0;
    return trackDurationMs < minPlayableMs ? trackDurationMs : minPlayableMs;
  }

  static int _clamp(int v, int lo, int hi) {
    if (hi < lo) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
  }

  @override
  bool operator ==(Object other) =>
      other is TrimRange &&
      other.startOffsetMs == startOffsetMs &&
      other.endOffsetMs == endOffsetMs &&
      other.trackDurationMs == trackDurationMs;

  @override
  int get hashCode => Object.hash(startOffsetMs, endOffsetMs, trackDurationMs);
}
