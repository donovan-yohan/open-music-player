import 'dart:collection';

import 'timeline_model.dart';

/// Complete editor-owned input for one click-audition lease.
///
/// Beat and downbeat timestamps remain in source time. The engine projects
/// both lists through the selected queue item's [MixClip], so tempo automation
/// cannot drift away from the canonical playback timeline.
class ClickAuditionRequest {
  ClickAuditionRequest({
    required this.queueItemId,
    required Iterable<int> sourceBeatsMs,
    required Iterable<int> sourceDownbeatsMs,
    this.beatClicksEnabled = true,
    this.downbeatAccentsEnabled = true,
    double volume = 0.20,
    this.outputOffsetMs = 0,
  })  : sourceBeatsMs = List<int>.unmodifiable(sourceBeatsMs),
        sourceDownbeatsMs = List<int>.unmodifiable(sourceDownbeatsMs),
        volume = volume.clamp(0.0, 1.0).toDouble();

  final String queueItemId;
  final List<int> sourceBeatsMs;
  final List<int> sourceDownbeatsMs;
  final bool beatClicksEnabled;
  final bool downbeatAccentsEnabled;
  final double volume;

  /// Device-local output calibration applied after timeline projection.
  ///
  /// A negative value renders clicks earlier; a positive value renders them
  /// later. This never changes source beats, downbeats, meter, or phase.
  final int outputOffsetMs;

  bool get hasAudibleClicks =>
      volume > 0 &&
      ((beatClicksEnabled && sourceBeatsMs.isNotEmpty) ||
          (downbeatAccentsEnabled && sourceDownbeatsMs.isNotEmpty));

  /// Whether updating this request can reuse the already-rendered source.
  ///
  /// Volume is intentionally excluded because it is a native player property,
  /// not procedural click-track content.
  bool hasSameAudioContentAs(ClickAuditionRequest other) {
    return queueItemId == other.queueItemId &&
        beatClicksEnabled == other.beatClicksEnabled &&
        downbeatAccentsEnabled == other.downbeatAccentsEnabled &&
        outputOffsetMs == other.outputOffsetMs &&
        _sameInts(sourceBeatsMs, other.sourceBeatsMs) &&
        _sameInts(sourceDownbeatsMs, other.sourceDownbeatsMs);
  }
}

class ProjectedClickMarker {
  const ProjectedClickMarker({
    required this.sourcePositionMs,
    required this.timelinePositionMs,
    required this.outputPositionMs,
    required this.isAccent,
  });

  final int sourcePositionMs;

  /// Canonical projected timestamp before device-local calibration.
  final int timelinePositionMs;

  /// Audible timestamp after applying [ClickAuditionRequest.outputOffsetMs].
  final int outputPositionMs;
  final bool isAccent;

  int localOutputPositionMs(int timelineStartMs) =>
      outputPositionMs - timelineStartMs;
}

class ProjectedClickTrack {
  ProjectedClickTrack({
    required this.queueItemId,
    required this.clipId,
    required this.timelineStartMs,
    required this.timelineEndMs,
    required Iterable<ProjectedClickMarker> markers,
  }) : markers = List<ProjectedClickMarker>.unmodifiable(markers);

  final String queueItemId;
  final String clipId;
  final int timelineStartMs;
  final int timelineEndMs;
  final List<ProjectedClickMarker> markers;

  int get durationMs => timelineEndMs - timelineStartMs;
}

/// Projects explicit source-time beat and downbeat facts through one exact
/// queue-item placement.
///
/// Downbeats are never inferred here. An empty downbeat list therefore produces
/// unaccented beat clicks even if accent audition is enabled.
ProjectedClickTrack? projectClickAudition({
  required TimelineModel model,
  required ClickAuditionRequest request,
}) {
  MixClip? target;
  for (final clip in model.clips) {
    if (clip.queueItemId != request.queueItemId) continue;
    if (target != null) {
      // Queue item identity must be unambiguous. Falling silent is safer than
      // auditioning the wrong occurrence of a repeated track.
      return null;
    }
    target = clip;
  }
  if (target == null) return null;
  final targetClip = target;

  final downbeats = HashSet<int>.from(request.sourceDownbeatsMs);
  final byOutputPosition = <int, ProjectedClickMarker>{};

  void addMarker(int sourceMs, {required bool isAccent}) {
    if (sourceMs < targetClip.placement.sourceStartMs ||
        sourceMs >= targetClip.placement.sourceEndMs) {
      return;
    }
    final timelineMs = targetClip.timelineMsForSourcePosition(sourceMs);
    final outputMs = timelineMs + request.outputOffsetMs;
    if (outputMs < targetClip.timelineStartMs ||
        outputMs >= targetClip.timelineEndMs) {
      return;
    }
    final existing = byOutputPosition[outputMs];
    if (existing != null && (existing.isAccent || !isAccent)) return;
    byOutputPosition[outputMs] = ProjectedClickMarker(
      sourcePositionMs: sourceMs,
      timelinePositionMs: timelineMs,
      outputPositionMs: outputMs,
      isAccent: isAccent,
    );
  }

  if (request.beatClicksEnabled) {
    for (final sourceMs in request.sourceBeatsMs) {
      addMarker(
        sourceMs,
        isAccent:
            request.downbeatAccentsEnabled && downbeats.contains(sourceMs),
      );
    }
  }
  if (request.downbeatAccentsEnabled) {
    for (final sourceMs in downbeats) {
      addMarker(sourceMs, isAccent: true);
    }
  }

  final markers = byOutputPosition.values.toList(growable: false)
    ..sort((a, b) => a.outputPositionMs.compareTo(b.outputPositionMs));
  return ProjectedClickTrack(
    queueItemId: request.queueItemId,
    clipId: targetClip.id,
    timelineStartMs: targetClip.timelineStartMs,
    timelineEndMs: targetClip.timelineEndMs,
    markers: markers,
  );
}

bool _sameInts(List<int> left, List<int> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
