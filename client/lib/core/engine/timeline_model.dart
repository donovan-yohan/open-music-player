import 'dart:math' as math;

import '../../models/mix_plan.dart';
import '../../models/stem_edits.dart';
import '../../models/timeline_clip.dart';
import 'gain_envelope.dart';
import 'tempo_automation.dart';

/// A timeline clip plus playback/source metadata used by the mix engine.
class MixClip {
  static const int _maxProjectedBeatMarkerCacheEntries = 2;

  final TimelineClip placement;
  final GainEnvelope envelope;
  final String audioSourceRef;
  final String? queueItemId;
  final double playbackRate;
  final String pitchMode;
  final TempoPolicy tempoPolicy;
  final ClipTempoMetadata tempo;
  final PlaybackRateAutomation rateAutomation;
  final StemEdits? stemEdits;
  final List<_ProjectedBeatMarkerCacheEntry> _projectedBeatMarkerCache = [];

  MixClip({
    required this.placement,
    this.envelope = const GainEnvelope.flat(),
    String? audioSourceRef,
    this.queueItemId,
    double playbackRate = 1,
    this.pitchMode = 'preserve',
    this.tempoPolicy = TempoPolicy.constantTempoLock,
    this.tempo = ClipTempoMetadata.empty,
    PlaybackRateAutomation? rateAutomation,
    this.stemEdits,
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

  double tempoScaleAt(int timelineMs) =>
      rateAutomation.tempoScaleAt(timelineMs);

  double? effectiveBpmAt(int timelineMs, {double transportRate = 1}) {
    final nativeBpm = tempo.nativeBpm;
    if (nativeBpm == null) return null;
    return effectiveBpmForRate(
      nativeBpm: nativeBpm,
      rate: playbackRateAt(timelineMs) * transportRate,
      tempoScale: tempoScaleAt(timelineMs),
    );
  }

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

  /// Memoizes projections by source-list identity for this immutable clip.
  ///
  /// Placement and automation are fixed for a [MixClip] lifecycle, so a
  /// projection only changes when the source marker list instance changes.
  /// Keeping two entries covers the waveform and analysis lists without a
  /// process-wide cache or unbounded retention.
  List<int> projectTempoSegmentBeatMarkers(List<int> sourceMarkers) {
    for (final entry in _projectedBeatMarkerCache) {
      if (identical(entry.sourceMarkers, sourceMarkers)) {
        return entry.projectedMarkers;
      }
    }

    final projected = projectBeatMarkersForTempoSegments(
      sourceMarkers,
      timelineMsForSourcePosition: timelineMsForSourcePosition,
      tempoScaleAt: tempoScaleAt,
    );
    if (_projectedBeatMarkerCache.length ==
        _maxProjectedBeatMarkerCacheEntries) {
      _projectedBeatMarkerCache.removeAt(0);
    }
    _projectedBeatMarkerCache.add(
      _ProjectedBeatMarkerCacheEntry(sourceMarkers, projected),
    );
    return projected;
  }

  /// Exposes bounded cache instrumentation for regression tests.
  int get projectedBeatMarkerCacheEntryCount =>
      _projectedBeatMarkerCache.length;

  MixClip withRateAutomation(PlaybackRateAutomation automation) => MixClip(
        placement: placement,
        envelope: envelope,
        audioSourceRef: audioSourceRef,
        queueItemId: queueItemId,
        playbackRate: playbackRate,
        pitchMode: pitchMode,
        tempoPolicy: tempoPolicy,
        tempo: tempo,
        rateAutomation: automation,
        stemEdits: stemEdits,
      );

  MixClip withEnvelope(GainEnvelope nextEnvelope) => MixClip(
        placement: placement,
        envelope: nextEnvelope,
        audioSourceRef: audioSourceRef,
        queueItemId: queueItemId,
        playbackRate: playbackRate,
        pitchMode: pitchMode,
        tempoPolicy: tempoPolicy,
        tempo: tempo,
        rateAutomation: rateAutomation,
        stemEdits: stemEdits,
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
      other.tempoPolicy == tempoPolicy &&
      other.tempo == tempo &&
      other.stemEdits == stemEdits &&
      other.rateAutomation == rateAutomation;

  @override
  int get hashCode => Object.hash(
        placement,
        envelope,
        audioSourceRef,
        queueItemId,
        playbackRate,
        pitchMode,
        tempoPolicy,
        tempo,
        rateAutomation,
        stemEdits,
      );
}

class _ProjectedBeatMarkerCacheEntry {
  final List<int> sourceMarkers;
  final List<int> projectedMarkers;

  const _ProjectedBeatMarkerCacheEntry(
      this.sourceMarkers, this.projectedMarkers);
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

  final incomingMarkers = _alignmentMarkersForClip(incoming, snapMode).where(
    (sourceMs) =>
        sourceMs >= incoming.placement.sourceStartMs &&
        sourceMs <= incoming.placement.sourceEndMs,
  );
  if (incomingMarkers.isEmpty) return null;
  final incomingAnchorMs = incoming.timelineMsForSourcePosition(
    incomingMarkers.first,
  );
  final outgoingMarkers = _alignmentMarkersForClip(outgoing, snapMode)
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
        tempoScale: outgoing.tempoScaleAt(nearestOutgoingMs),
      )) {
    return null;
  }
  return nearestOutgoingMs - incomingAnchorMs;
}

List<int> _alignmentMarkersForClip(MixClip clip, BeatSnapMode snapMode) {
  // Individual beats can follow a local octave segment without claiming a
  // grouped origin; 4/16 still need one stable anchored lattice.
  if (snapMode == BeatSnapMode.beat1 && clip.tempo.hasReliableBeatGrid) {
    return clip.projectTempoSegmentBeatMarkers(clip.tempo.beatsMs);
  }
  // A changing octave interpretation has no single ordinal group lattice.
  final scale = clip.tempoScaleAt(clip.timelineStartMs);
  if (clip.rateAutomation.segments
      .any((segment) => segment.tempoScale != scale)) {
    return const [];
  }
  return beatMarkersForSnapMode(clip.tempo, snapMode, tempoScale: scale);
}

/// Pure timeline arrangement model for Phase 1 of the mix engine.
class TimelineModel {
  static const int maxConcurrentVoices = 4;

  final List<MixClip> clips;

  factory TimelineModel({
    Iterable<MixClip> clips = const [],
    bool autoTempoTransitions = true,
  }) {
    final ordered = List<MixClip>.from(clips)..sort(_compareClips);
    final ids = <String>{};
    for (final clip in ordered) {
      if (!ids.add(clip.id)) {
        throw StateError('duplicate timeline clip ID: ${clip.id}');
      }
    }
    if (_exceedsMaxConcurrentVoices(ordered)) {
      throw StateError(
          'timeline would exceed $maxConcurrentVoices concurrent voices');
    }
    final model = TimelineModel._(List.unmodifiable(ordered));
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
    return TimelineModel(
      clips: plan.clips.map((clip) => _mixClipFromPlanClip(
            clip,
            sourceDurationMsFor: sourceDurationMsFor,
          )),
      autoTempoTransitions: false,
    );
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
    BeatSnapMode snapMode = BeatSnapMode.downbeat,
  }) {
    final planClipsByTrack = <String, List<MixPlanClip>>{};
    for (final clip in plan.clips) {
      (planClipsByTrack[clip.trackId] ??= []).add(clip);
    }
    final planClipsForTrack = {
      for (final entry in planClipsByTrack.entries)
        entry.key: entry.value.iterator,
    };
    var cursor = 0;
    final queueClips = <MixClip>[];
    MixClip? previousQueueClip;

    for (var index = 0; index < trackOrder.length; index++) {
      final trackId = trackOrder[index];
      final planClips = planClipsForTrack[trackId];
      final planClip =
          planClips != null && planClips.moveNext() ? planClips.current : null;
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
          snapMode: snapMode,
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
        tempoPolicy: planClip?.tempoPolicy ?? TempoPolicy.volumeOnly,
        stemEdits: planClip?.stemEdits,
        tempo: tempo,
      );
      queueClips.add(mixClip);
      previousQueueClip = mixClip;
      cursor = placement.timelineEndMs;
    }

    return TimelineModel(clips: queueClips, autoTempoTransitions: false);
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
    if (clips
        .any((clip) => clip.id != ignoringClipId && clip.id == candidate.id)) {
      return false;
    }
    final candidates = <MixClip>[
      for (final clip in clips)
        if (clip.id != ignoringClipId) clip,
      candidate,
    ];
    return !_exceedsMaxConcurrentVoices(candidates);
  }

  TimelineModel addClip(MixClip clip) {
    if (clips.any((existing) => existing.id == clip.id)) {
      throw StateError('duplicate timeline clip ID: ${clip.id}');
    }
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
          tempoPolicy: clip.tempoPolicy,
          stemEdits: clip.stemEdits,
        ),
      )
      .toList(growable: false);

  TimelineModel _copyAdding(MixClip clip) {
    final next = [...clips, clip]..sort(_compareClips);
    return TimelineModel._(List.unmodifiable(next));
  }

  TimelineModel _withStandardTempoTransitions() {
    if (clips.length < 2) return this;
    final next = List<MixClip>.from(clips);
    final capacity = _TimelineCapacity(next);
    // Starts and IDs already have deterministic ordering. One reference per
    // connected overlap component, not competing pairwise overlays.
    var first = 0;
    while (first < next.length) {
      var end = next[first].timelineEndMs;
      var last = first + 1;
      while (last < next.length && next[last].timelineStartMs < end) {
        end = math.max(end, next[last].timelineEndMs);
        last++;
      }
      if (last - first > 1) {
        final master = next[first];
        final proposed = <(int, MixClip)>[];
        var accepted = next.sublist(first, last).every((clip) =>
            clip.tempoPolicy == TempoPolicy.constantTempoLock &&
            hasConstantTempoLockGrid(clip.tempo));
        final masterRate = _constantClipRate(master);
        accepted = accepted && masterRate != null;
        if (accepted) {
          for (var i = first + 1; i < last; i++) {
            final incoming = next[i];
            final locked = _constantMasterIncoming(master, incoming);
            if (locked == null ||
                !capacity.tryReplacePair(master, incoming, master, locked)) {
              accepted = false;
              break;
            }
            proposed.add((i, locked));
          }
        }
        // A lock may lengthen a tail into the next independently planned
        // component. Abstain rather than introduce two simultaneous masters.
        if (accepted &&
            last < next.length &&
            proposed.any((entry) =>
                entry.$2.timelineEndMs > next[last].timelineStartMs)) {
          accepted = false;
        }
        if (accepted) {
          for (final (i, clip) in proposed) {
            next[i] = clip;
          }
        } else {
          // Atomic component abstention: never leave a partially locked group.
          for (final (i, clip) in proposed) {
            capacity.tryReplacePair(master, clip, master, next[i]);
          }
        }
      }
      first = last;
    }
    return TimelineModel._(List.unmodifiable(next));
  }

  static int _compareClips(MixClip a, MixClip b) {
    final byStart = a.timelineStartMs.compareTo(b.timelineStartMs);
    return byStart != 0 ? byStart : a.id.compareTo(b.id);
  }

  static bool _exceedsMaxConcurrentVoices(Iterable<MixClip> candidates) {
    final events = <(int, int)>[];
    for (final clip in candidates) {
      // Empty half-open intervals consume no voice, including at their start.
      if (clip.timelineEndMs <= clip.timelineStartMs) continue;
      events.add((clip.timelineStartMs, 1));
      events.add((clip.timelineEndMs, -1));
    }
    events.sort((a, b) {
      final byTime = a.$1.compareTo(b.$1);
      // Releases precede admissions at a butt joint: [start, end).
      return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
    });
    var depth = 0;
    for (final (_, delta) in events) {
      depth += delta;
      if (depth > maxConcurrentVoices) return true;
    }
    return false;
  }
}

/// Range-add/range-max index over fixed clip starts. Overlap depth can only
/// increase at a start, even when tempo automation moves an end. This keeps
/// each proposed pair's full-arrangement capacity check O(log N), not O(N).
class _TimelineCapacity {
  _TimelineCapacity(List<MixClip> clips)
      : _starts = clips.map((clip) => clip.timelineStartMs).toSet().toList()
          ..sort() {
    _max = List.filled(_starts.length * 4, 0);
    _lazy = List.filled(_starts.length * 4, 0);
    for (final clip in clips) {
      _addClip(clip, 1);
    }
  }

  final List<int> _starts;
  late final List<int> _max;
  late final List<int> _lazy;

  bool tryReplacePair(MixClip outgoing, MixClip incoming, MixClip nextOutgoing,
      MixClip nextIncoming) {
    _addClip(outgoing, -1);
    _addClip(incoming, -1);
    _addClip(nextOutgoing, 1);
    _addClip(nextIncoming, 1);
    if (_max[1] <= TimelineModel.maxConcurrentVoices) return true;
    _addClip(nextOutgoing, -1);
    _addClip(nextIncoming, -1);
    _addClip(outgoing, 1);
    _addClip(incoming, 1);
    return false;
  }

  int _lowerBound(int timeMs) {
    var low = 0;
    var high = _starts.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_starts[mid] < timeMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _addClip(MixClip clip, int delta) {
    if (clip.timelineEndMs <= clip.timelineStartMs) return;
    final start = _lowerBound(clip.timelineStartMs);
    final end = _lowerBound(clip.timelineEndMs);
    _add(1, 0, _starts.length, start, end, delta);
  }

  void _add(int node, int left, int right, int start, int end, int delta) {
    if (end <= left || right <= start) return;
    if (start <= left && right <= end) {
      _max[node] += delta;
      _lazy[node] += delta;
      return;
    }
    final mid = (left + right) ~/ 2;
    _add(node * 2, left, mid, start, end, delta);
    _add(node * 2 + 1, mid, right, start, end, delta);
    _max[node] = _lazy[node] + math.max(_max[node * 2], _max[node * 2 + 1]);
  }
}

/// Authored curves are immutable. Only a single constant rate and octave
/// interpretation covering the entire selected window can join an auto lock.
double? _constantClipRate(MixClip clip) {
  final start = clip.timelineStartMs;
  final end = clip.timelineEndMs;
  final rate = clip.playbackRateAt(start);
  final scale = clip.tempoScaleAt(start);
  final cuts = <int>{start, math.max(start, end - 1)};
  for (final segment in clip.rateAutomation.segments) {
    if (segment.endMs <= start || segment.startMs >= end) continue;
    if (segment.startRate != segment.endRate) return null;
    cuts.add(segment.startMs.clamp(start, end - 1));
    cuts.add(segment.endMs.clamp(start, end - 1));
  }
  for (final cut in cuts) {
    if ((clip.playbackRateAt(cut) - rate).abs() > 0.000001 ||
        clip.tempoScaleAt(cut) != scale) {
      return null;
    }
  }
  return rate;
}

MixClip? _constantMasterIncoming(MixClip master, MixClip incoming) {
  final masterRate = _constantClipRate(master);
  if (masterRate == null) return null;
  final pair = resolveTempoTransitionBpmPair(
      outgoingTempo: master.tempo,
      incomingTempo: incoming.tempo,
      outgoingBaseRate: masterRate,
      incomingBaseRate: incoming.rateAutomation.baseRate);
  if (pair == null) return null;
  final scale = master.tempoScaleAt(master.timelineStartMs) *
      pair.incomingTempoScale /
      pair.outgoingTempoScale;
  if (!tempoOctaveScales.contains(scale)) return null;
  final pulse = master.effectiveBpmAt(master.timelineStartMs)!;
  final rate = pulse / (incoming.tempo.nativeBpm! * scale);
  final base = incoming.rateAutomation.baseRate;
  // Technical .5..2 feasibility is not audible-quality admission.
  if (!rate.isFinite ||
      rate < minTempoAutomationRate ||
      rate > maxTempoAutomationRate ||
      (rate / base - 1).abs() > 0.15) {
    return null;
  }
  final existing = _constantClipRate(incoming);
  if (incoming.rateAutomation.segments.isNotEmpty ||
      base != incoming.playbackRate) {
    if (existing == null ||
        (existing - rate).abs() > 0.000001 ||
        incoming.tempoScaleAt(incoming.timelineStartMs) != scale) {
      return null;
    }
    return incoming;
  }
  // Prepare before audibility and hold through EOF. The segment's absolute
  // end bounds even the slowest supported rate; no overlap-end restoration.
  return incoming.withRateAutomation(incoming.rateAutomation.withSegment(
      PlaybackRateSegment(
          startMs: incoming.timelineStartMs,
          endMs: incoming.timelineStartMs +
              (incoming.selectedDurationMs / minTempoAutomationRate).ceil() +
              1,
          startRate: rate,
          endRate: rate,
          tempoScale: scale)));
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
    tempoPolicy: clip.tempoPolicy,
    stemEdits: clip.stemEdits,
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
