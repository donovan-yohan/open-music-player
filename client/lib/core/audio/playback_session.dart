import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/timeline_clip.dart';
import '../engine/timeline_model.dart';
import 'playback_media_item_source.dart';

class PlaybackCue {
  const PlaybackCue({
    required this.cueId,
    required this.queueIndex,
    required this.trackId,
    required this.mediaItem,
    required this.audioUri,
    required this.sourceStart,
    required this.sourceEnd,
    required this.timelineStart,
  });

  final String cueId;
  final int queueIndex;
  final String trackId;
  final MediaItem mediaItem;
  final Uri audioUri;
  final Duration sourceStart;
  final Duration sourceEnd;
  final Duration timelineStart;

  Duration get selectedDuration {
    final selected = sourceEnd - sourceStart;
    return selected.isNegative ? Duration.zero : selected;
  }

  Duration get timelineEnd => timelineStart + selectedDuration;

  MixClip toMixClip() => MixClip(
        placement: TimelineClip.clamped(
          id: cueId,
          trackId: trackId,
          sourceDurationMs: sourceEnd.inMilliseconds,
          sourceStartMs: sourceStart.inMilliseconds,
          sourceEndMs: sourceEnd.inMilliseconds,
          timelineStartMs: timelineStart.inMilliseconds,
        ),
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
  }) {
    var cursor = Duration.zero;
    final cues = <PlaybackCue>[];
    for (final queueIndex in playOrder) {
      if (queueIndex < 0 || queueIndex >= queue.length) continue;
      final item = queue[queueIndex];
      final duration = item.duration ?? Duration.zero;
      final cue = PlaybackCue(
        cueId: '${sessionId}_queue_$queueIndex',
        queueIndex: queueIndex,
        trackId: item.id,
        mediaItem: item,
        audioUri: audioSourceUriForItem(item),
        sourceStart: Duration.zero,
        sourceEnd: duration,
        timelineStart: cursor,
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
        clips: cues.map((cue) => cue.toMixClip()),
      );

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
    final clamped =
        _clampDuration(localPosition, Duration.zero, cue.selectedDuration);
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

  PlaybackSnapshot copyWith({
    String? sessionId,
    List<PlaybackCue>? cues,
    String? currentCueId,
    int? currentQueueIndex,
    MediaItem? currentMediaItem,
    Duration? localPosition,
    Duration? localDuration,
    Duration? globalPosition,
    Duration? globalDuration,
    bool? playing,
    ProcessingState? processingState,
    int? activeVoiceCount,
  }) =>
      PlaybackSnapshot(
        sessionId: sessionId ?? this.sessionId,
        cues: cues ?? this.cues,
        currentCueId: currentCueId ?? this.currentCueId,
        currentQueueIndex: currentQueueIndex ?? this.currentQueueIndex,
        currentMediaItem: currentMediaItem ?? this.currentMediaItem,
        localPosition: localPosition ?? this.localPosition,
        localDuration: localDuration ?? this.localDuration,
        globalPosition: globalPosition ?? this.globalPosition,
        globalDuration: globalDuration ?? this.globalDuration,
        playing: playing ?? this.playing,
        processingState: processingState ?? this.processingState,
        activeVoiceCount: activeVoiceCount ?? this.activeVoiceCount,
      );
}

Duration _clampDuration(Duration value, Duration min, Duration max) {
  final clampedMs = value.inMilliseconds.clamp(
    min.inMilliseconds,
    math.max(min.inMilliseconds, max.inMilliseconds),
  );
  return Duration(milliseconds: clampedMs.toInt());
}
