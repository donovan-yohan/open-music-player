import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../models/timeline_clip.dart';
import '../engine/gain_envelope.dart';
import '../engine/timeline_model.dart';
import 'playback_media_item_source.dart';

const int mixSessionSchemaVersion = 1;

/// Versioned canonical clip/session state for queue, playlist, and timeline
/// playback. Signed URLs stay on [MediaItem]; this carries durable edit data.
class MixSession {
  const MixSession({
    required this.sessionId,
    required this.clips,
    this.schemaVersion = mixSessionSchemaVersion,
    this.nextClipOrdinal = 0,
  });

  factory MixSession.empty({String sessionId = 'session_0'}) => MixSession(
        sessionId: sessionId,
        clips: const [],
      );

  factory MixSession.fromQueue({
    required String sessionId,
    required List<MediaItem> queue,
  }) {
    var cursorMs = 0;
    final clips = <MixSessionClip>[];
    for (var i = 0; i < queue.length; i++) {
      final clip = MixSessionClip.fromMediaItem(
        sessionId: sessionId,
        ordinal: i,
        item: queue[i],
        timelineStartMs: cursorMs,
      );
      clips.add(clip);
      cursorMs = clip.timelineEndMs;
    }
    return MixSession(
      sessionId: sessionId,
      clips: List.unmodifiable(clips),
      nextClipOrdinal: clips.length,
    );
  }

  factory MixSession.fromJson(Map<String, dynamic> json) {
    final rawSessionId = (json['sessionId'] as String?)?.trim();
    final rawClips = json['clips'];
    final clips = <MixSessionClip>[];
    if (rawClips is List) {
      for (final rawClip in rawClips) {
        if (rawClip is Map) {
          final clip = MixSessionClip.tryFromJson(
            Map<String, dynamic>.from(rawClip),
          );
          if (clip != null) clips.add(clip);
        }
      }
    }

    return MixSession(
      sessionId: rawSessionId?.isNotEmpty == true ? rawSessionId! : 'session_0',
      schemaVersion:
          (json['schemaVersion'] as num?)?.toInt() ?? mixSessionSchemaVersion,
      clips: List.unmodifiable(clips),
      nextClipOrdinal: math.max(
        (json['nextClipOrdinal'] as num?)?.toInt() ?? clips.length,
        _nextOrdinalAfter(clips),
      ),
    );
  }

  final int schemaVersion;
  final String sessionId;
  final List<MixSessionClip> clips;
  final int nextClipOrdinal;

  bool get isEmpty => clips.isEmpty;

  MixSession normalizedForQueue(List<MediaItem> queue) {
    var cursorMs = 0;
    var nextOrdinal = nextClipOrdinal;
    final normalized = <MixSessionClip>[];

    for (var i = 0; i < queue.length; i++) {
      final existing = i < clips.length ? clips[i] : null;
      final item = queue[i];
      final clip = existing == null
          ? MixSessionClip.fromMediaItem(
              sessionId: sessionId,
              ordinal: nextOrdinal++,
              item: item,
              timelineStartMs: cursorMs,
            )
          : existing.reconciledWithMediaItem(item);
      normalized.add(clip);
      cursorMs = clip.timelineEndMs;
    }

    return MixSession(
      sessionId: sessionId,
      schemaVersion: schemaVersion,
      clips: List.unmodifiable(normalized),
      nextClipOrdinal: math.max(nextOrdinal, _nextOrdinalAfter(normalized)),
    );
  }

  MixSession insertAt(int index, MediaItem item) {
    final insertIndex = index.clamp(0, clips.length).toInt();
    final nextClips = <MixSessionClip>[];
    final previous = insertIndex > 0 ? clips[insertIndex - 1] : null;
    final next = insertIndex < clips.length ? clips[insertIndex] : null;
    final timelineStartMs =
        previous?.timelineEndMs ?? next?.timelineStartMs ?? 0;
    final inserted = MixSessionClip.fromMediaItem(
      sessionId: sessionId,
      ordinal: nextClipOrdinal,
      item: item,
      timelineStartMs: timelineStartMs,
    );
    for (var i = 0; i < clips.length; i++) {
      if (i == insertIndex) nextClips.add(inserted);
      final clip = clips[i];
      nextClips.add(
        i >= insertIndex ? clip.shiftedBy(inserted.selectedDurationMs) : clip,
      );
    }
    if (insertIndex == clips.length) nextClips.add(inserted);
    return MixSession(
      sessionId: sessionId,
      schemaVersion: schemaVersion,
      clips: List.unmodifiable(nextClips),
      nextClipOrdinal: nextClipOrdinal + 1,
    );
  }

  MixSession removeAt(int index) {
    if (index < 0 || index >= clips.length) return this;
    final removed = clips[index];
    final nextClips = <MixSessionClip>[
      for (var i = 0; i < clips.length; i++)
        if (i != index)
          i > index
              ? clips[i].shiftedBy(-removed.selectedDurationMs)
              : clips[i],
    ];
    return MixSession(
      sessionId: sessionId,
      schemaVersion: schemaVersion,
      clips: List.unmodifiable(nextClips),
      nextClipOrdinal: nextClipOrdinal,
    );
  }

  MixSession reorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return this;
    if (oldIndex < 0 || oldIndex >= clips.length) return this;
    if (newIndex < 0 || newIndex >= clips.length) return this;
    final nextClips = List<MixSessionClip>.from(clips);
    final clip = nextClips.removeAt(oldIndex);
    nextClips.insert(newIndex, clip);
    return MixSession(
      sessionId: sessionId,
      schemaVersion: schemaVersion,
      clips: List.unmodifiable(nextClips),
      nextClipOrdinal: nextClipOrdinal,
    );
  }

  MixSession reflowedByOrder(List<int> playOrder) {
    if (clips.isEmpty) return this;
    var cursorMs = 0;
    final nextClips = List<MixSessionClip>.from(clips);
    final seen = <int>{};

    for (final index in playOrder) {
      if (index < 0 || index >= nextClips.length || !seen.add(index)) {
        continue;
      }
      final clip = nextClips[index];
      nextClips[index] = clip.withPlacement(
        clip.placement.withTimelineStartMs(cursorMs),
      );
      cursorMs = nextClips[index].timelineEndMs;
    }

    for (var index = 0; index < nextClips.length; index++) {
      if (seen.contains(index)) continue;
      final clip = nextClips[index];
      nextClips[index] = clip.withPlacement(
        clip.placement.withTimelineStartMs(cursorMs),
      );
      cursorMs = nextClips[index].timelineEndMs;
    }

    return MixSession(
      sessionId: sessionId,
      schemaVersion: schemaVersion,
      clips: List.unmodifiable(nextClips),
      nextClipOrdinal: nextClipOrdinal,
    );
  }

  MixSession withPlacementAt(int index, TimelineClip placement) {
    if (index < 0 || index >= clips.length) return this;
    final nextClips = List<MixSessionClip>.from(clips)
      ..[index] = clips[index].withPlacement(placement);
    return MixSession(
      sessionId: sessionId,
      schemaVersion: schemaVersion,
      clips: List.unmodifiable(nextClips),
      nextClipOrdinal: nextClipOrdinal,
    );
  }

  MixSessionClip? clipAt(int index) {
    if (index < 0 || index >= clips.length) return null;
    return clips[index];
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'sessionId': sessionId,
        'nextClipOrdinal': nextClipOrdinal,
        'clips': [for (final clip in clips) clip.toJson()],
      };
}

class MixSessionClip {
  const MixSessionClip({
    required this.clipId,
    required this.queueItemId,
    required this.trackId,
    required this.sourceDurationMs,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.timelineStartMs,
    this.gainDb = 0,
    this.fadeInMs,
    this.fadeOutMs,
    this.playbackRate = 1,
    this.pitchMode = 'preserve',
    this.analysisRef,
    this.analysisVersion,
  });

  factory MixSessionClip.fromMediaItem({
    required String sessionId,
    required int ordinal,
    required MediaItem item,
    required int timelineStartMs,
  }) {
    final durationMs = item.duration?.inMilliseconds ?? 0;
    return MixSessionClip(
      clipId: '${sessionId}_clip_$ordinal',
      queueItemId: '${sessionId}_item_$ordinal',
      trackId: item.id,
      sourceDurationMs: durationMs,
      sourceStartMs: 0,
      sourceEndMs: durationMs,
      timelineStartMs: timelineStartMs,
    );
  }

  static MixSessionClip? tryFromJson(Map<String, dynamic> json) {
    final clipId = (json['clipId'] as String?)?.trim();
    final queueItemId = (json['queueItemId'] as String?)?.trim();
    final trackId = json['trackId']?.toString().trim();
    if (clipId == null ||
        clipId.isEmpty ||
        queueItemId == null ||
        queueItemId.isEmpty ||
        trackId == null ||
        trackId.isEmpty) {
      return null;
    }

    final sourceDurationMs =
        math.max(0, (json['sourceDurationMs'] as num?)?.toInt() ?? 0);
    final placement = TimelineClip.clamped(
      id: clipId,
      trackId: trackId,
      sourceDurationMs: sourceDurationMs,
      sourceStartMs: (json['sourceStartMs'] as num?)?.toInt() ?? 0,
      sourceEndMs: (json['sourceEndMs'] as num?)?.toInt() ?? sourceDurationMs,
      timelineStartMs: (json['timelineStartMs'] as num?)?.toInt() ?? 0,
    );

    return MixSessionClip(
      clipId: clipId,
      queueItemId: queueItemId,
      trackId: trackId,
      sourceDurationMs: placement.sourceDurationMs,
      sourceStartMs: placement.sourceStartMs,
      sourceEndMs: placement.sourceEndMs,
      timelineStartMs: placement.timelineStartMs,
      gainDb: (json['gainDb'] as num?)?.toDouble() ?? 0,
      fadeInMs: (json['fadeInMs'] as num?)?.toInt(),
      fadeOutMs: (json['fadeOutMs'] as num?)?.toInt(),
      playbackRate: (json['playbackRate'] as num?)?.toDouble() ?? 1,
      pitchMode: (json['pitchMode'] as String?) ?? 'preserve',
      analysisRef: json['analysisRef'] as String?,
      analysisVersion: json['analysisVersion'] as String?,
    );
  }

  final String clipId;
  final String queueItemId;
  final String trackId;
  final int sourceDurationMs;
  final int sourceStartMs;
  final int sourceEndMs;
  final int timelineStartMs;
  final double gainDb;
  final int? fadeInMs;
  final int? fadeOutMs;
  final double playbackRate;
  final String pitchMode;
  final String? analysisRef;
  final String? analysisVersion;

  int get selectedDurationMs => sourceEndMs - sourceStartMs;
  int get timelineEndMs => timelineStartMs + selectedDurationMs;

  TimelineClip get placement => TimelineClip.clamped(
        id: clipId,
        trackId: trackId,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
      );

  MixSessionClip reconciledWithMediaItem(MediaItem item) {
    final durationMs = item.duration?.inMilliseconds ?? sourceDurationMs;
    final placement = TimelineClip.clamped(
      id: clipId,
      trackId: item.id,
      sourceDurationMs: durationMs,
      sourceStartMs: sourceStartMs,
      sourceEndMs: math.min(sourceEndMs, durationMs),
      timelineStartMs: timelineStartMs,
    );
    return withPlacement(placement);
  }

  MixSessionClip withPlacement(TimelineClip placement) => MixSessionClip(
        clipId: clipId,
        queueItemId: queueItemId,
        trackId: placement.trackId,
        sourceDurationMs: placement.sourceDurationMs,
        sourceStartMs: placement.sourceStartMs,
        sourceEndMs: placement.sourceEndMs,
        timelineStartMs: placement.timelineStartMs,
        gainDb: gainDb,
        fadeInMs: fadeInMs,
        fadeOutMs: fadeOutMs,
        playbackRate: playbackRate,
        pitchMode: pitchMode,
        analysisRef: analysisRef,
        analysisVersion: analysisVersion,
      );

  MixSessionClip shiftedBy(int deltaMs) {
    if (deltaMs == 0) return this;
    return withPlacement(
        placement.withTimelineStartMs(timelineStartMs + deltaMs));
  }

  Map<String, dynamic> toJson() => {
        'clipId': clipId,
        'queueItemId': queueItemId,
        'trackId': trackId,
        'sourceDurationMs': sourceDurationMs,
        'sourceStartMs': sourceStartMs,
        'sourceEndMs': sourceEndMs,
        'timelineStartMs': timelineStartMs,
        'gainDb': gainDb,
        if (fadeInMs != null) 'fadeInMs': fadeInMs,
        if (fadeOutMs != null) 'fadeOutMs': fadeOutMs,
        'playbackRate': playbackRate,
        'pitchMode': pitchMode,
        if (analysisRef != null) 'analysisRef': analysisRef,
        if (analysisVersion != null) 'analysisVersion': analysisVersion,
      };
}

class PlaybackCue {
  const PlaybackCue({
    required this.cueId,
    required this.queueItemId,
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
  final String queueItemId;
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
        queueItemId: queueItemId,
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
  }) =>
      CueTimeline.editedQueue(
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
    var session = MixSession.fromQueue(sessionId: sessionId, queue: queue);
    for (final entry in placements.entries) {
      session = session.withPlacementAt(entry.key, entry.value);
    }
    return CueTimeline.fromSession(
      session: session,
      queue: queue,
      playOrder: playOrder,
    );
  }

  factory CueTimeline.fromSession({
    required MixSession session,
    required List<MediaItem> queue,
    required List<int> playOrder,
  }) {
    var cursor = Duration.zero;
    final cues = <PlaybackCue>[];
    final normalizedSession = session.normalizedForQueue(queue);
    for (final queueIndex in playOrder) {
      if (queueIndex < 0 || queueIndex >= queue.length) continue;
      final item = queue[queueIndex];
      final sessionClip = normalizedSession.clipAt(queueIndex) ??
          MixSessionClip.fromMediaItem(
            sessionId: normalizedSession.sessionId,
            ordinal: normalizedSession.nextClipOrdinal + cues.length,
            item: item,
            timelineStartMs: cursor.inMilliseconds,
          );
      final placement = sessionClip.placement;
      final cue = PlaybackCue(
        cueId: placement.id,
        queueItemId: sessionClip.queueItemId,
        queueIndex: queueIndex,
        trackId: placement.trackId,
        mediaItem: item,
        audioUri: audioSourceUriForItem(item),
        sourceDuration: Duration(milliseconds: placement.sourceDurationMs),
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
        clips: [
          for (final cue in cues) cue.toMixClip(envelope: _envelopeFor(cue))
        ],
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

  PlaybackCue? cueForQueueItemId(String queueItemId) {
    for (final cue in cues) {
      if (cue.queueItemId == queueItemId) return cue;
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

int _nextOrdinalAfter(List<MixSessionClip> clips) {
  var maxOrdinal = -1;
  for (final clip in clips) {
    final marker = RegExp(r'_(?:clip|item)_(\d+)$').firstMatch(clip.clipId);
    final parsed = marker == null ? null : int.tryParse(marker.group(1)!);
    if (parsed != null && parsed > maxOrdinal) maxOrdinal = parsed;
  }
  return maxOrdinal + 1;
}
