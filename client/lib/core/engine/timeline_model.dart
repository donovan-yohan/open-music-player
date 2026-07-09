import 'dart:math' as math;

import '../../models/mix_plan.dart';
import '../../models/timeline_clip.dart';
import 'gain_envelope.dart';
import 'tempo_automation.dart';

/// A timeline clip plus playback/source metadata used by the mix engine.
class MixClip {
  final TimelineClip placement;
  final GainEnvelope envelope;
  final String audioSourceRef;
  final String? queueItemId;
  final double playbackRate;
  final String pitchMode;
  final ClipTempoMetadata tempo;
  final PlaybackRateAutomation rateAutomation;

  MixClip({
    required this.placement,
    this.envelope = const GainEnvelope.flat(),
    String? audioSourceRef,
    this.queueItemId,
    double playbackRate = 1,
    this.pitchMode = 'preserve',
    this.tempo = ClipTempoMetadata.empty,
    PlaybackRateAutomation? rateAutomation,
  })  : audioSourceRef = audioSourceRef ?? placement.trackId,
        playbackRate = playbackRate
            .clamp(
              minTempoAutomationRate,
              maxTempoAutomationRate,
            )
            .toDouble(),
        rateAutomation = rateAutomation ??
            PlaybackRateAutomation(
              baseRate: playbackRate
                  .clamp(
                    minTempoAutomationRate,
                    maxTempoAutomationRate,
                  )
                  .toDouble(),
              pitchMode: pitchMode,
            );

  String get id => placement.id;
  String get trackId => placement.trackId;
  int get timelineStartMs => placement.timelineStartMs;
  int get timelineEndMs => placement.timelineEndMs;
  int get selectedDurationMs => placement.selectedDurationMs;

  bool isActiveAt(int timelineMs) =>
      timelineMs >= timelineStartMs && timelineMs < timelineEndMs;

  int localOffsetAt(int timelineMs) => timelineMs - timelineStartMs;

  double gainAt(int timelineMs) =>
      envelope.gainAt(localOffsetAt(timelineMs), selectedDurationMs);

  double playbackRateAt(int timelineMs) => rateAutomation.rateAt(timelineMs);

  int sourcePositionAt(int timelineMs) {
    final elapsed = rateAutomation.sourceElapsedMs(
      timelineStartMs: timelineStartMs,
      timelineMs: timelineMs,
    );
    return (placement.sourceStartMs + elapsed)
        .clamp(placement.sourceStartMs, placement.sourceEndMs)
        .toInt();
  }

  int timelineMsForSourcePosition(int sourcePositionMs) {
    final targetElapsed = sourcePositionMs
            .clamp(placement.sourceStartMs, placement.sourceEndMs)
            .toInt() -
        placement.sourceStartMs;
    return rateAutomation.timelineMsForSourceElapsed(
      timelineStartMs: timelineStartMs,
      sourceElapsedMs: targetElapsed,
      maxTimelineMs: timelineEndMs,
    );
  }

  MixClip withRateAutomation(PlaybackRateAutomation automation) => MixClip(
        placement: placement,
        envelope: envelope,
        audioSourceRef: audioSourceRef,
        queueItemId: queueItemId,
        playbackRate: playbackRate,
        pitchMode: pitchMode,
        tempo: tempo,
        rateAutomation: automation,
      );

  @override
  bool operator ==(Object other) =>
      other is MixClip &&
      other.placement == placement &&
      other.envelope == envelope &&
      other.audioSourceRef == audioSourceRef &&
      other.queueItemId == queueItemId &&
      other.playbackRate == playbackRate &&
      other.pitchMode == pitchMode &&
      other.tempo == tempo &&
      other.rateAutomation == rateAutomation;

  @override
  int get hashCode => Object.hash(
        placement,
        envelope,
        audioSourceRef,
        queueItemId,
        playbackRate,
        pitchMode,
        tempo,
        rateAutomation,
      );
}

/// Pure timeline arrangement model for Phase 1 of the mix engine.
class TimelineModel {
  static const int maxConcurrentVoices = 4;

  final List<MixClip> clips;

  factory TimelineModel({
    Iterable<MixClip> clips = const [],
    bool autoTempoTransitions = true,
  }) {
    var model = const TimelineModel._([]);
    for (final clip in clips) {
      if (model.canPlace(clip.placement)) {
        model = model._copyAdding(clip);
      }
    }
    return autoTempoTransitions ? model._withStandardTempoTransitions() : model;
  }

  const TimelineModel._(this.clips);

  factory TimelineModel.sequential(
    Iterable<String> trackIds, {
    required int Function(String trackId) sourceDurationMsFor,
    int Function(String trackId, int index)? sourceDurationMsForEntry,
    String Function(String trackId, int index)? audioSourceRefFor,
    String Function(String trackId, int index)? queueItemIdFor,
    String Function(String trackId, int index)? clipIdFor,
    int startAtMs = 0,
    GainEnvelope envelope = const GainEnvelope.flat(),
  }) {
    var cursor = math.max(0, startAtMs);
    final clips = <MixClip>[];
    var index = 0;
    for (final trackId in trackIds) {
      final durationMs = math.max(
        0,
        sourceDurationMsForEntry?.call(trackId, index) ??
            sourceDurationMsFor(trackId),
      );
      final placement = TimelineClip.clamped(
        id: clipIdFor?.call(trackId, index) ?? 'clip_${index}_$trackId',
        trackId: trackId,
        sourceDurationMs: durationMs,
        sourceStartMs: 0,
        sourceEndMs: durationMs,
        timelineStartMs: cursor,
      );
      clips.add(
        MixClip(
          placement: placement,
          envelope: envelope,
          audioSourceRef: audioSourceRefFor?.call(trackId, index),
          queueItemId: queueItemIdFor?.call(trackId, index),
        ),
      );
      cursor = placement.timelineEndMs;
      index++;
    }
    return TimelineModel(clips: clips);
  }

  factory TimelineModel.fromMixPlan(
    MixPlan plan, {
    int Function(String trackId)? sourceDurationMsFor,
  }) {
    var model = const TimelineModel._([]);
    for (final clip in plan.clips) {
      final mixClip = _mixClipFromPlanClip(
        clip,
        sourceDurationMsFor: sourceDurationMsFor,
      );
      if (model.canPlace(mixClip.placement)) {
        model = model._copyAdding(mixClip);
      }
    }
    return model;
  }

  factory TimelineModel.fromQueuePlan(
    MixPlan plan, {
    required List<String> trackOrder,
    int Function(String trackId)? sourceDurationMsFor,
  }) {
    final remainingPlanClips = List<MixPlanClip>.from(plan.clips);
    var cursor = 0;
    var model = const TimelineModel._([]);

    for (var index = 0; index < trackOrder.length; index++) {
      final trackId = trackOrder[index];
      final planClip = _takeFirstForTrack(remainingPlanClips, trackId);
      final sourceDurationMs = _sourceDurationFor(
        trackId,
        planClip,
        sourceDurationMsFor,
      );

      var sourceStartMs = 0;
      var sourceEndMs = sourceDurationMs;
      if (planClip != null &&
          (planClip.sourceStartMs != 0 ||
              planClip.sourceEndMs != sourceDurationMs)) {
        sourceStartMs = planClip.sourceStartMs;
        sourceEndMs = planClip.sourceEndMs;
      }

      final baselineTimelineStartMs = cursor;
      var timelineStartMs = baselineTimelineStartMs;
      if (planClip != null &&
          planClip.timelineStartMs != 0 &&
          planClip.timelineStartMs != baselineTimelineStartMs) {
        timelineStartMs = planClip.timelineStartMs;
      }

      final placement = TimelineClip.clamped(
        id: planClip?.clipId ?? 'clip_${index}_$trackId',
        trackId: trackId,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
      );
      final mixClip = MixClip(
        placement: placement,
        envelope: _envelopeFromPlanClip(planClip),
        queueItemId: planClip?.queueItemId,
      );
      if (model.canPlace(mixClip.placement)) {
        model = model._copyAdding(mixClip);
      }
      cursor = placement.timelineEndMs;
    }

    return model;
  }

  int get durationMs => clips.fold<int>(
        0,
        (maxEnd, clip) => math.max(maxEnd, clip.timelineEndMs),
      );

  bool get isSingleClip => clips.length == 1;

  List<MixClip> activeClipsAt(int timelineMs) => clips
      .where((clip) => clip.isActiveAt(timelineMs))
      .toList(growable: false);

  int overlapDepthAt(int timelineMs) => activeClipsAt(timelineMs).length;

  MixClip? dominantClipAt(int timelineMs) {
    final active = activeClipsAt(timelineMs);
    if (active.isEmpty) return null;

    return active.reduce((current, candidate) {
      final currentGain = current.gainAt(timelineMs);
      final candidateGain = candidate.gainAt(timelineMs);
      if (candidateGain > currentGain) return candidate;
      if (candidateGain < currentGain) return current;
      if (candidate.timelineStartMs >= current.timelineStartMs) {
        return candidate;
      }
      return current;
    });
  }

  bool canPlace(TimelineClip placement, {String? ignoringClipId}) {
    final candidates = <TimelineClip>[
      for (final clip in clips)
        if (clip.id != ignoringClipId) clip.placement,
      placement,
    ];
    final probeTimes = candidates
        .map((clip) => clip.timelineStartMs)
        .toSet()
        .toList(growable: false)
      ..sort();

    for (final time in probeTimes) {
      final depth = candidates
          .where(
            (clip) => time >= clip.timelineStartMs && time < clip.timelineEndMs,
          )
          .length;
      if (depth > maxConcurrentVoices) return false;
    }
    return true;
  }

  TimelineModel addClip(MixClip clip) {
    if (!canPlace(clip.placement)) {
      throw StateError(
        'clip would exceed $maxConcurrentVoices concurrent voices',
      );
    }
    return _copyAdding(clip);
  }

  TimelineModel removeClip(String clipId) => TimelineModel._(
        List.unmodifiable(clips.where((clip) => clip.id != clipId)),
      );

  Map<String, dynamic> toMixPlanPayload({String name = 'Untitled mix'}) => {
        'schemaVersion': 1,
        'name': name,
        'clips': toMixPlanClips().map((clip) => clip.toJson()).toList(),
      };

  List<MixPlanClip> toMixPlanClips() => clips
      .map(
        (clip) => MixPlanClip(
          clipId: clip.placement.id,
          queueItemId: clip.queueItemId ?? clip.placement.id,
          trackId: clip.placement.trackId,
          sourceStartMs: clip.placement.sourceStartMs,
          sourceEndMs: clip.placement.sourceEndMs,
          timelineStartMs: clip.placement.timelineStartMs,
          gainDb: clip.envelope.baseGainDb,
          fadeInMs: clip.envelope.fadeInMs == 0 ? null : clip.envelope.fadeInMs,
          fadeOutMs:
              clip.envelope.fadeOutMs == 0 ? null : clip.envelope.fadeOutMs,
        ),
      )
      .toList(growable: false);

  TimelineModel _copyAdding(MixClip clip) {
    final next = [...clips, clip]..sort((a, b) {
        final byStart = a.timelineStartMs.compareTo(b.timelineStartMs);
        if (byStart != 0) return byStart;
        return a.id.compareTo(b.id);
      });
    return TimelineModel._(List.unmodifiable(next));
  }

  TimelineModel _withStandardTempoTransitions() {
    if (clips.length < 2) return this;

    final next = List<MixClip>.from(clips);
    for (var i = 0; i < next.length; i++) {
      for (var j = i + 1; j < next.length; j++) {
        final first = next[i];
        final second = next[j];
        final overlapStart = math.max(
          first.timelineStartMs,
          second.timelineStartMs,
        );
        final overlapEnd = math.min(first.timelineEndMs, second.timelineEndMs);
        if (overlapEnd <= overlapStart) continue;

        final firstIsOutgoing = first.timelineStartMs <= second.timelineStartMs;
        final outgoingIndex = firstIsOutgoing ? i : j;
        final incomingIndex = firstIsOutgoing ? j : i;
        final outgoing = next[outgoingIndex];
        final incoming = next[incomingIndex];
        if (outgoing.timelineStartMs == incoming.timelineStartMs) continue;
        if (!outgoing.tempo.hasReliableBpm || !incoming.tempo.hasReliableBpm) {
          continue;
        }

        final outgoingBpm = outgoing.tempo.nativeBpm!;
        final incomingBpm = incoming.tempo.nativeBpm!;
        final outgoingStartRate = _rateForTempo(outgoing, outgoingBpm);
        final outgoingEndRate = _rateForTempo(outgoing, incomingBpm);
        final incomingStartRate = _rateForTempo(incoming, outgoingBpm);
        final incomingEndRate = _rateForTempo(incoming, incomingBpm);

        next[outgoingIndex] = outgoing.withRateAutomation(
          outgoing.rateAutomation.withSegment(
            PlaybackRateSegment(
              startMs: overlapStart,
              endMs: overlapEnd,
              startRate: outgoingStartRate,
              endRate: outgoingEndRate,
            ),
          ),
        );
        next[incomingIndex] = incoming.withRateAutomation(
          incoming.rateAutomation.withSegment(
            PlaybackRateSegment(
              startMs: overlapStart,
              endMs: overlapEnd,
              startRate: incomingStartRate,
              endRate: incomingEndRate,
            ),
          ),
        );
      }
    }

    return TimelineModel._(List.unmodifiable(next));
  }
}

double _rateForTempo(MixClip clip, double targetBpm) {
  final nativeBpm = clip.tempo.nativeBpm;
  if (nativeBpm == null || nativeBpm <= 0) return clip.playbackRate;
  return (clip.playbackRate * targetBpm / nativeBpm)
      .clamp(minTempoAutomationRate, maxTempoAutomationRate)
      .toDouble();
}

MixClip _mixClipFromPlanClip(
  MixPlanClip clip, {
  int Function(String trackId)? sourceDurationMsFor,
}) {
  final sourceDurationMs = _sourceDurationFor(
    clip.trackId,
    clip,
    sourceDurationMsFor,
  );
  return MixClip(
    placement: TimelineClip.clamped(
      id: clip.clipId,
      trackId: clip.trackId,
      sourceDurationMs: sourceDurationMs,
      sourceStartMs: clip.sourceStartMs,
      sourceEndMs: clip.sourceEndMs,
      timelineStartMs: clip.timelineStartMs,
    ),
    envelope: _envelopeFromPlanClip(clip),
    queueItemId: clip.queueItemId,
  );
}

GainEnvelope _envelopeFromPlanClip(MixPlanClip? clip) {
  if (clip == null) return const GainEnvelope.flat();
  return GainEnvelope(
    baseGainDb: math.min(0, clip.gainDb),
    fadeInMs: clip.fadeInMs ?? 0,
    fadeOutMs: clip.fadeOutMs ?? 0,
  );
}

int _sourceDurationFor(
  String trackId,
  MixPlanClip? clip,
  int Function(String trackId)? sourceDurationMsFor,
) {
  final provided = sourceDurationMsFor?.call(trackId);
  final minimum = clip?.sourceEndMs ?? 0;
  if (provided == null) return minimum;
  return math.max(provided, minimum);
}

MixPlanClip? _takeFirstForTrack(List<MixPlanClip> clips, String trackId) {
  final index = clips.indexWhere((clip) => clip.trackId == trackId);
  if (index == -1) return null;
  return clips.removeAt(index);
}
