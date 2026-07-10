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
            .clamp(minTempoAutomationRate, maxTempoAutomationRate)
            .toDouble(),
        rateAutomation = rateAutomation ??
            PlaybackRateAutomation(
              baseRate: playbackRate
                  .clamp(minTempoAutomationRate, maxTempoAutomationRate)
                  .toDouble(),
              pitchMode: pitchMode,
            );

  String get id => placement.id;
  String get trackId => placement.trackId;
  int get timelineStartMs => placement.timelineStartMs;
  late final int timelineEndMs = rateAutomation.timelineMsForSelectedSource(
    timelineStartMs: timelineStartMs,
    sourceDurationMs: selectedDurationMs,
  );
  late final int timelineDurationMs = timelineEndMs - timelineStartMs;
  int get selectedDurationMs => placement.selectedDurationMs;

  bool isActiveAt(int timelineMs) =>
      timelineMs >= timelineStartMs && timelineMs < timelineEndMs;

  int localOffsetAt(int timelineMs) => timelineMs - timelineStartMs;

  double gainAt(int timelineMs) =>
      envelope.gainAt(localOffsetAt(timelineMs), timelineDurationMs);

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

  MixClip withEnvelope(GainEnvelope nextEnvelope) => MixClip(
        placement: placement,
        envelope: nextEnvelope,
        audioSourceRef: audioSourceRef,
        queueItemId: queueItemId,
        playbackRate: playbackRate,
        pitchMode: pitchMode,
        tempo: tempo,
        rateAutomation: rateAutomation,
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

int? beatAlignmentCorrectionMs({
  required MixClip outgoing,
  required MixClip incoming,
  required BeatSnapMode snapMode,
}) {
  if (snapMode == BeatSnapMode.free) return null;
  final overlapStartMs = math.max(
    outgoing.timelineStartMs,
    incoming.timelineStartMs,
  );
  final overlapEndMs = math.min(
    outgoing.timelineEndMs,
    incoming.timelineEndMs,
  );
  if (overlapEndMs <= overlapStartMs) return null;

  final incomingMarkers = beatMarkersForSnapMode(
    incoming.tempo,
    snapMode,
  ).where(
    (sourceMs) =>
        sourceMs >= incoming.placement.sourceStartMs &&
        sourceMs <= incoming.placement.sourceEndMs,
  );
  if (incomingMarkers.isEmpty) return null;
  final incomingAnchorMs = incoming.timelineMsForSourcePosition(
    incomingMarkers.first,
  );
  final outgoingMarkers = beatMarkersForSnapMode(
    outgoing.tempo,
    snapMode,
  )
      .where(
        (sourceMs) =>
            sourceMs >= outgoing.placement.sourceStartMs &&
            sourceMs <= outgoing.placement.sourceEndMs,
      )
      .map(outgoing.timelineMsForSourcePosition)
      .toList(growable: false);
  if (outgoingMarkers.isEmpty) return null;

  var nearestOutgoingMs = outgoingMarkers.first;
  var nearestDistance = (nearestOutgoingMs - incomingAnchorMs).abs();
  for (final markerMs in outgoingMarkers.skip(1)) {
    final distance = (markerMs - incomingAnchorMs).abs();
    if (distance < nearestDistance) {
      nearestOutgoingMs = markerMs;
      nearestDistance = distance;
    }
  }
  if (nearestDistance >
      downbeatSnapToleranceMs(
        outgoing.tempo,
        snapMode: snapMode,
        baseRate: outgoing.playbackRate,
      )) {
    return null;
  }
  return nearestOutgoingMs - incomingAnchorMs;
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
      if (model.canPlaceClip(clip)) {
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
      if (model.canPlaceClip(mixClip)) {
        model = model._copyAdding(mixClip);
      }
    }
    return model;
  }

  factory TimelineModel.fromQueuePlan(
    MixPlan plan, {
    required List<String> trackOrder,
    int Function(String trackId)? sourceDurationMsFor,
    ClipTempoMetadata Function(String trackId)? tempoMetadataFor,
    ClipTempoMetadata Function(String trackId, int index)?
        tempoMetadataForEntry,
    String Function(String trackId, int index)? clipIdFor,
    String Function(String trackId, int index)? queueItemIdFor,
    bool useTempoDefaultStarts = false,
  }) {
    final remainingPlanClips = List<MixPlanClip>.from(plan.clips);
    var cursor = 0;
    var model = const TimelineModel._([]);
    MixClip? previousQueueClip;

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

      final tempo = tempoMetadataForEntry?.call(trackId, index) ??
          tempoMetadataFor?.call(trackId) ??
          ClipTempoMetadata.empty;
      final baselineTimelineStartMs = cursor;
      var timelineStartMs = baselineTimelineStartMs;
      if (planClip != null && planClip.timelineStartMs != 0) {
        timelineStartMs = planClip.timelineStartMs;
      } else if (useTempoDefaultStarts && previousQueueClip != null) {
        timelineStartMs = defaultDownbeatLockedTransitionStartMs(
          outgoingTimelineStartMs: previousQueueClip.timelineStartMs,
          outgoingTimelineEndMs: previousQueueClip.timelineEndMs,
          outgoingSourceStartMs: previousQueueClip.placement.sourceStartMs,
          outgoingSelectedDurationMs: previousQueueClip.selectedDurationMs,
          outgoingTempo: previousQueueClip.tempo,
          incomingSourceStartMs: sourceStartMs,
          incomingSelectedDurationMs: sourceEndMs - sourceStartMs,
          incomingTempo: tempo,
          fallbackStartMs: baselineTimelineStartMs,
        );
      }

      final placement = TimelineClip.clamped(
        id: planClip?.clipId ??
            clipIdFor?.call(trackId, index) ??
            'clip_${index}_$trackId',
        trackId: trackId,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
      );
      final mixClip = MixClip(
        placement: placement,
        envelope: _envelopeFromPlanClip(planClip),
        queueItemId:
            planClip?.queueItemId ?? queueItemIdFor?.call(trackId, index),
        pitchMode: planClip?.pitchMode ?? pitchModePreserve,
        tempo: tempo,
      );
      if (model.canPlaceClip(mixClip)) {
        model = model._copyAdding(mixClip);
        previousQueueClip = mixClip;
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
    return canPlaceClip(
      MixClip(placement: placement),
      ignoringClipId: ignoringClipId,
    );
  }

  bool canPlaceClip(MixClip candidate, {String? ignoringClipId}) {
    final candidates = <MixClip>[
      for (final clip in clips)
        if (clip.id != ignoringClipId) clip,
      candidate,
    ];
    return !_exceedsMaxConcurrentVoices(candidates);
  }

  TimelineModel addClip(MixClip clip) {
    if (!canPlaceClip(clip)) {
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
          pitchMode: clip.rateAutomation.pitchMode,
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
        final transition = _tempoMatchedPair(
          outgoing: outgoing,
          incoming: incoming,
          overlapStartMs: overlapStart,
          initialOverlapEndMs: overlapEnd,
        );
        if (transition == null) continue;

        final proposedOutgoing = transition.outgoing;
        final proposedIncoming = transition.incoming;
        final proposed = List<MixClip>.from(next)
          ..[outgoingIndex] = proposedOutgoing
          ..[incomingIndex] = proposedIncoming;
        if (_exceedsMaxConcurrentVoices(proposed)) continue;

        next[outgoingIndex] = proposedOutgoing;
        next[incomingIndex] = proposedIncoming;
      }
    }

    return TimelineModel._(List.unmodifiable(next));
  }

  static bool _exceedsMaxConcurrentVoices(Iterable<MixClip> candidates) {
    final clips = candidates.toList(growable: false);
    final probeTimes = clips
        .map((clip) => clip.timelineStartMs)
        .toSet()
        .toList(growable: false)
      ..sort();

    for (final time in probeTimes) {
      final depth = clips.where((clip) => clip.isActiveAt(time)).length;
      if (depth > maxConcurrentVoices) return true;
    }
    return false;
  }
}

_TempoMatchedPair? _tempoMatchedPair({
  required MixClip outgoing,
  required MixClip incoming,
  required int overlapStartMs,
  required int initialOverlapEndMs,
}) {
  final initialOverlapMs = initialOverlapEndMs - overlapStartMs;
  if (initialOverlapMs <= 0) return null;

  var transitionEndMs = initialOverlapEndMs;
  MixClip? proposedOutgoing;
  MixClip? proposedIncoming;
  var converged = false;

  for (var attempt = 0; attempt < 12; attempt++) {
    final ratePlan = planTempoMatchedTransition(
      overlapStartMs: overlapStartMs,
      overlapEndMs: transitionEndMs,
      outgoingTempo: outgoing.tempo,
      incomingTempo: incoming.tempo,
      outgoingBaseRate: outgoing.rateAutomation.baseRate,
      incomingBaseRate: incoming.rateAutomation.baseRate,
    );
    if (ratePlan == null) return null;

    proposedOutgoing = outgoing.withRateAutomation(
      ratePlan.applyToOutgoing(outgoing.rateAutomation),
    );
    proposedIncoming = incoming.withRateAutomation(
      ratePlan.applyToIncoming(incoming.rateAutomation),
    );
    final actualOverlapEndMs = math.min(
      proposedOutgoing.timelineEndMs,
      proposedIncoming.timelineEndMs,
    );
    if (actualOverlapEndMs <= overlapStartMs) return null;
    if ((actualOverlapEndMs - transitionEndMs).abs() <= 1) {
      transitionEndMs = actualOverlapEndMs;
      converged = true;
      break;
    }
    transitionEndMs = actualOverlapEndMs;
  }

  if (!converged || proposedOutgoing == null || proposedIncoming == null) {
    return null;
  }

  final transitionMs = transitionEndMs - overlapStartMs;
  if (outgoing.envelope.fadeOutMs == initialOverlapMs) {
    proposedOutgoing = proposedOutgoing.withEnvelope(
      outgoing.envelope.withFadeOutMs(transitionMs),
    );
  }
  if (incoming.envelope.fadeInMs == initialOverlapMs) {
    proposedIncoming = proposedIncoming.withEnvelope(
      incoming.envelope.withFadeInMs(transitionMs),
    );
  }

  return _TempoMatchedPair(proposedOutgoing, proposedIncoming);
}

class _TempoMatchedPair {
  const _TempoMatchedPair(this.outgoing, this.incoming);

  final MixClip outgoing;
  final MixClip incoming;
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
    pitchMode: clip.pitchMode,
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
