import 'dart:math' as math;

/// Half-open timeline interval `[startMs, endMs)` used by clip overlap math.
class TimelineInterval {
  final int startMs;
  final int endMs;

  const TimelineInterval({required this.startMs, required this.endMs});

  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is TimelineInterval &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);
}

/// Timing-only placement contract for an arranger timeline clip.
///
/// The source selection (`sourceStartMs` → `sourceEndMs`) is intentionally
/// separate from the timeline placement (`timelineStartMs`). `timelineEndMs` is
/// always derived from the selected source duration, so moving a clip cannot
/// mutate its trim points and trimming a clip cannot leave stale placement data.
class TimelineClip {
  final String id;
  final String trackId;
  final int sourceDurationMs;
  final int sourceStartMs;
  final int sourceEndMs;
  final int timelineStartMs;

  /// Keep tiny accidental slivers out of the contract while still allowing
  /// sub-second sources to be represented whole.
  static const int minSelectedMs = 1000;

  const TimelineClip._({
    required this.id,
    required this.trackId,
    required this.sourceDurationMs,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.timelineStartMs,
  });

  factory TimelineClip.clamped({
    required String id,
    required String trackId,
    required int sourceDurationMs,
    required int sourceStartMs,
    required int sourceEndMs,
    required int timelineStartMs,
  }) {
    final duration = math.max(0, sourceDurationMs);
    var start = sourceStartMs.clamp(0, duration);
    var end = sourceEndMs.clamp(0, duration);
    final minSelected = _effectiveMinSelected(duration);

    if (end - start < minSelected) {
      end = start + minSelected;
      if (end > duration) {
        end = duration;
        start = (duration - minSelected).clamp(0, duration);
      }
    }

    return TimelineClip._(
      id: id,
      trackId: trackId,
      sourceDurationMs: duration,
      sourceStartMs: start,
      sourceEndMs: end,
      timelineStartMs: math.max(0, timelineStartMs),
    );
  }

  int get selectedDurationMs => sourceEndMs - sourceStartMs;

  int get timelineEndMs => timelineStartMs + selectedDurationMs;

  TimelineClip withTimelineStartMs(int ms) => TimelineClip.clamped(
        id: id,
        trackId: trackId,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: ms,
      );

  TimelineClip withSourceRange({
    required int sourceStartMs,
    required int sourceEndMs,
  }) =>
      TimelineClip.clamped(
        id: id,
        trackId: trackId,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
      );

  bool overlapsTimelineInterval(int startMs, int endMs) =>
      overlapInterval(startMs, endMs) != null;

  int overlapDurationMs(int startMs, int endMs) =>
      overlapInterval(startMs, endMs)?.durationMs ?? 0;

  TimelineInterval? overlapInterval(int startMs, int endMs) {
    if (endMs <= startMs) return null;

    final overlapStart = math.max(timelineStartMs, startMs);
    final overlapEnd = math.min(timelineEndMs, endMs);
    if (overlapEnd <= overlapStart) return null;

    return TimelineInterval(startMs: overlapStart, endMs: overlapEnd);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'trackId': trackId,
        'sourceDurationMs': sourceDurationMs,
        'sourceStartMs': sourceStartMs,
        'sourceEndMs': sourceEndMs,
        'timelineStartMs': timelineStartMs,
      };

  factory TimelineClip.fromJson(Map<String, dynamic> json) =>
      TimelineClip.clamped(
        id: json['id'] as String,
        trackId: json['trackId'] as String,
        sourceDurationMs: (json['sourceDurationMs'] as num).toInt(),
        sourceStartMs: (json['sourceStartMs'] as num).toInt(),
        sourceEndMs: (json['sourceEndMs'] as num).toInt(),
        timelineStartMs: (json['timelineStartMs'] as num).toInt(),
      );

  static int _effectiveMinSelected(int sourceDurationMs) {
    if (sourceDurationMs <= 0) return 0;
    return sourceDurationMs < minSelectedMs ? sourceDurationMs : minSelectedMs;
  }

  @override
  bool operator ==(Object other) =>
      other is TimelineClip &&
      other.id == id &&
      other.trackId == trackId &&
      other.sourceDurationMs == sourceDurationMs &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceEndMs == sourceEndMs &&
      other.timelineStartMs == timelineStartMs;

  @override
  int get hashCode => Object.hash(
        id,
        trackId,
        sourceDurationMs,
        sourceStartMs,
        sourceEndMs,
        timelineStartMs,
      );
}
