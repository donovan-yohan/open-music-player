import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/timeline_clip.dart';
import '../engine/gain_envelope.dart';
import '../engine/timeline_model.dart';
import 'playback_media_item_source.dart';

class PlaybackCue {
  const PlaybackCue({
    required this.cueId,
    required this.queueIndex,
    required this.trackId,
    required this.mediaItem,
    required this.audioUri,
    required this.sourceDuration,
    required this.sourceStart,
    required this.sourceEnd,
    required this.timelineStart,
  });

  final String cueId;
  final int queueIndex;
  final String trackId;
  final MediaItem mediaItem;
  final Uri audioUri;
  final Duration sourceDuration;
  final Duration sourceStart;
  final Duration sourceEnd;
  final Duration timelineStart;

  Duration get selectedDuration {
    final selected = sourceEnd - sourceStart;
    return selected.isNegative ? Duration.zero : selected;
  }

  Duration get timelineEnd => timelineStart + selectedDuration;

  TimelineClip get placement => TimelineClip.clamped(
    id: cueId,
    trackId: trackId,
    sourceDurationMs: sourceDuration.inMilliseconds,
    sourceStartMs: sourceStart.inMilliseconds,
    sourceEndMs: sourceEnd.inMilliseconds,
    timelineStartMs: timelineStart.inMilliseconds,
  );

  MixClip toMixClip({GainEnvelope envelope = const GainEnvelope.flat()}) =>
      MixClip(
        placement: placement,
        envelope: envelope,
        audioSourceRef: audioUri.toString(),
        queueItemId: queueIndex.toString(),
      );
}

class CueTimeline {
  const CueTimeline._(this.cues);

  factory CueTimeline({Iterable<PlaybackCue> cues = const []}) =>
      CueTimeline._(List.unmodifiable(cues));

  factory CueTimeline.contiguousQueue({
    required String sessionId,
    required List<MediaItem> queue,
    required List<int> playOrder,
  }) => CueTimeline.editedQueue(
    sessionId: sessionId,
    queue: queue,
    playOrder: playOrder,
  );

  factory CueTimeline.editedQueue({
    required String sessionId,
    required List<MediaItem> queue,
    required List<int> playOrder,
    Map<int, TimelineClip> placements = const {},
  }) {
    var cursor = Duration.zero;
    final cues = <PlaybackCue>[];
    for (final queueIndex in playOrder) {
      if (queueIndex < 0 || queueIndex >= queue.length) continue;
      final item = queue[queueIndex];
      final duration = item.duration ?? Duration.zero;
      final durationMs = duration.inMilliseconds;
      final placement = TimelineClip.clamped(
        id: '${sessionId}_queue_$queueIndex',
        trackId: item.id,
        sourceDurationMs: durationMs,
        sourceStartMs: placements[queueIndex]?.sourceStartMs ?? 0,
        sourceEndMs: placements[queueIndex]?.sourceEndMs ?? durationMs,
        timelineStartMs:
            placements[queueIndex]?.timelineStartMs ?? cursor.inMilliseconds,
      );
      final cue = PlaybackCue(
        cueId: placement.id,
        queueIndex: queueIndex,
        trackId: placement.trackId,
        mediaItem: item,
        audioUri: audioSourceUriForItem(item),
        sourceDuration: duration,
        sourceStart: Duration(milliseconds: placement.sourceStartMs),
        sourceEnd: Duration(milliseconds: placement.sourceEndMs),
        timelineStart: Duration(milliseconds: placement.timelineStartMs),
      );
      cues.add(cue);
      cursor = cue.timelineEnd;
    }
    return CueTimeline(cues: cues);
  }

  static const empty = CueTimeline._([]);

  final List<PlaybackCue> cues;

  Duration get duration => cues.fold<Duration>(
    Duration.zero,
    (maxEnd, cue) => cue.timelineEnd > maxEnd ? cue.timelineEnd : maxEnd,
  );

  TimelineModel toTimelineModel() => TimelineModel(
    clips: [for (final cue in cues) cue.toMixClip(envelope: _envelopeFor(cue))],
  );

  GainEnvelope _envelopeFor(PlaybackCue cue) {
    var fadeInMs = 0;
    var fadeOutMs = 0;
    for (final other in cues) {
      if (identical(other, cue)) continue;
      final overlapStart = math.max(
        cue.timelineStart.inMilliseconds,
        other.timelineStart.inMilliseconds,
      );
      final overlapEnd = math.min(
        cue.timelineEnd.inMilliseconds,
        other.timelineEnd.inMilliseconds,
      );
      if (overlapEnd <= overlapStart) continue;

      final overlapMs = overlapEnd - overlapStart;
      if (other.timelineStart < cue.timelineStart) {
        fadeInMs = math.max(fadeInMs, overlapMs);
      } else if (other.timelineStart > cue.timelineStart) {
        fadeOutMs = math.max(fadeOutMs, overlapMs);
      } else if (other.queueIndex < cue.queueIndex) {
        fadeInMs = math.max(fadeInMs, overlapMs);
      } else {
        fadeOutMs = math.max(fadeOutMs, overlapMs);
      }
    }
    return GainEnvelope(fadeInMs: fadeInMs, fadeOutMs: fadeOutMs);
  }

  PlaybackCue? cueForQueueIndex(int queueIndex) {
    for (final cue in cues) {
      if (cue.queueIndex == queueIndex) return cue;
    }
    return null;
  }

  PlaybackCue? currentCueAt(Duration globalPosition) {
    if (cues.isEmpty) return null;
    for (final cue in cues) {
      if (globalPosition >= cue.timelineStart &&
          globalPosition < cue.timelineEnd) {
        return cue;
      }
    }
    if (globalPosition >= duration) return cues.last;
    return cues.first;
  }

  Duration globalFor(PlaybackCue cue, Duration localPosition) {
    final clamped = _clampDuration(
      localPosition,
      Duration.zero,
      cue.selectedDuration,
    );
    return cue.timelineStart + clamped;
  }

  Duration localFor(PlaybackCue cue, Duration globalPosition) {
    final local = globalPosition - cue.timelineStart;
    return _clampDuration(local, Duration.zero, cue.selectedDuration);
  }
}

class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.sessionId,
    required this.cues,
    required this.currentCueId,
    required this.currentQueueIndex,
    required this.currentMediaItem,
    required this.localPosition,
    required this.localDuration,
    required this.globalPosition,
    required this.globalDuration,
    required this.playing,
    required this.processingState,
    required this.activeVoiceCount,
  });

  factory PlaybackSnapshot.empty({String sessionId = 'session_0'}) =>
      PlaybackSnapshot(
        sessionId: sessionId,
        cues: const [],
        currentCueId: null,
        currentQueueIndex: null,
        currentMediaItem: null,
        localPosition: Duration.zero,
        localDuration: Duration.zero,
        globalPosition: Duration.zero,
        globalDuration: Duration.zero,
        playing: false,
        processingState: ProcessingState.idle,
        activeVoiceCount: 0,
      );

  final String sessionId;
  final List<PlaybackCue> cues;
  final String? currentCueId;
  final int? currentQueueIndex;
  final MediaItem? currentMediaItem;
  final Duration localPosition;
  final Duration localDuration;
  final Duration globalPosition;
  final Duration globalDuration;
  final bool playing;
  final ProcessingState processingState;
  final int activeVoiceCount;
}

Duration _clampDuration(Duration value, Duration min, Duration max) {
  final clampedMs = value.inMilliseconds.clamp(
    min.inMilliseconds,
    math.max(min.inMilliseconds, max.inMilliseconds),
  );
  return Duration(milliseconds: clampedMs.toInt());
}
