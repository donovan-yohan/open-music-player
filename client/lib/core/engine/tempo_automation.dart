import 'dart:math' as math;

import '../../models/track_analysis.dart';

const double minTempoAutomationRate = 0.5;
const double maxTempoAutomationRate = 2.0;
const double reliableBpmConfidenceFloor = 0.55;
const double reliableDownbeatConfidenceFloor = 0.55;
const int minReliableBeatGridMarkers = 4;
const double minReliableBeatIntervalMedianRatio = 0.45;
const double maxReliableBeatIntervalMedianRatio = 1.8;
const int defaultTransitionPhraseBeats = 16;
const int minDefaultTransitionOverlapMs = 4000;
const int maxDefaultTransitionOverlapMs = 12000;
const List<double> tempoOctaveScales = [0.5, 1, 2];
const double _preferredTransitionBpm = 128;
const String manualTempoProvenance = 'manual_override';
const String pitchModePreserve = 'preserve';
const String pitchModeFollowTempo = 'followTempo';

enum BeatSnapMode { free, downbeat, beat1, beat4, beat16 }

BeatSnapMode parseBeatSnapMode(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'free' => BeatSnapMode.free,
    'beat1' || '1' => BeatSnapMode.beat1,
    'beat4' || '4' => BeatSnapMode.beat4,
    'beat16' || '16' => BeatSnapMode.beat16,
    _ => BeatSnapMode.downbeat,
  };
}

class ClipTempoMetadata {
  final double? nativeBpm;
  final double? bpmConfidence;
  final int? beatGridOffsetMs;

  /// Canonical manual-grid anchor. This is deliberately distinct from a
  /// derived list of beat timestamps so phase edits never rewrite the grid.
  final int? beatAnchorMs;
  final int? beatsPerBar;
  final int? downbeatPhaseIndex;
  final double? meterConfidence;
  final String? meterProvenance;
  final double? downbeatPhaseConfidence;
  final String? downbeatPhaseProvenance;
  final int? phraseLengthBars;
  final int? overrideRevision;
  final List<int> beatsMs;
  final List<int> downbeatsMs;
  final double? downbeatConfidence;

  /// Generated marker arrays whose meter/phase is explicitly unknown remain
  /// display data, not automatic playback-lock authority.
  final bool generatedTimingUnknown;
  final String? bpmProvenance;
  final String? beatGridProvenance;
  final String? downbeatProvenance;
  final String? musicalKey;
  final String? camelot;

  const ClipTempoMetadata({
    this.nativeBpm,
    this.bpmConfidence,
    this.beatGridOffsetMs,
    this.beatAnchorMs,
    this.beatsPerBar,
    this.downbeatPhaseIndex,
    this.meterConfidence,
    this.meterProvenance,
    this.downbeatPhaseConfidence,
    this.downbeatPhaseProvenance,
    this.phraseLengthBars,
    this.overrideRevision,
    this.beatsMs = const [],
    this.downbeatsMs = const [],
    this.downbeatConfidence,
    this.generatedTimingUnknown = false,
    this.bpmProvenance,
    this.beatGridProvenance,
    this.downbeatProvenance,
    this.musicalKey,
    this.camelot,
  });

  static const empty = ClipTempoMetadata();

  bool get hasReliableBpm {
    final bpm = nativeBpm;
    if (bpm == null || !bpm.isFinite || bpm <= 0) return false;
    final confidence = bpmConfidence;
    return confidence == null || confidence >= reliableBpmConfidenceFloor;
  }

  /// Raw analyzer ordinals can establish phase only when their timing is locally
  /// coherent. BPM octave ambiguity and gradual tempo changes are valid; nearby
  /// duplicates, missing cells, and abrupt interval jumps are not.
  bool get hasReliableBeatGrid {
    if (beatsMs.length < minReliableBeatGridMarkers ||
        !_isStrictlyIncreasingNonNegative(beatsMs)) {
      return false;
    }

    final explicitlyManual = _isManualBeatGridProvenance(beatGridProvenance);
    if (explicitlyManual) return true;
    final confidence = bpmConfidence;
    if (confidence != null &&
        (!confidence.isFinite || confidence < reliableBpmConfidenceFloor)) {
      return false;
    }
    return _hasStructurallyReliableBeatIntervals(beatsMs);
  }

  bool get hasDownbeatMarkers => downbeatsMs.isNotEmpty;

  bool get hasReliableDownbeats {
    if (!hasDownbeatMarkers || !_isStrictlyIncreasingNonNegative(downbeatsMs)) {
      return false;
    }
    if (generatedTimingUnknown) return false;
    final meter = beatsPerBar;
    final phase = downbeatPhaseIndex;
    final canonicalManualAuthority = meter != null &&
        meter > 0 &&
        phase != null &&
        phase >= 0 &&
        phase < meter &&
        meterConfidence == 1.0 &&
        downbeatPhaseConfidence == 1.0 &&
        meterProvenance == manualTempoProvenance &&
        downbeatPhaseProvenance == manualTempoProvenance;
    final legacyCompatibilityAuthority = meter == null &&
        phase == null &&
        meterConfidence == null &&
        downbeatPhaseConfidence == null &&
        meterProvenance == null &&
        downbeatPhaseProvenance == null;
    if (!canonicalManualAuthority && !legacyCompatibilityAuthority) {
      // Generated meter/phase remain automation-ineligible until #312
      // introduces a calibrated eligibility signal. Marker arrays alone are
      // compatibility data, not authority.
      return false;
    }
    if (beatsMs.isNotEmpty) {
      if (!_isStrictlyIncreasingNonNegative(beatsMs)) return false;
      if (!_downbeatsFollowBeatGrid(beatsMs, downbeatsMs)) {
        return false;
      }
    }
    final confidence = downbeatConfidence;
    return confidence == null ||
        (confidence.isFinite && confidence >= reliableDownbeatConfidenceFloor);
  }

  /// Preserves the existing auto-lock contract for callers that use this name.
  bool get hasDownbeats => hasReliableDownbeats;

  bool get hasLowConfidenceDownbeats {
    final confidence = downbeatConfidence;
    return hasDownbeatMarkers &&
        (!hasReliableDownbeats ||
            confidence == null ||
            confidence < reliableDownbeatConfidenceFloor);
  }

  Map<String, dynamic> toJson() => {
        if (nativeBpm != null) 'nativeBpm': nativeBpm,
        if (bpmConfidence != null) 'bpmConfidence': bpmConfidence,
        if (beatGridOffsetMs != null) 'beatGridOffsetMs': beatGridOffsetMs,
        if (beatAnchorMs != null) 'beatAnchorMs': beatAnchorMs,
        if (beatsPerBar != null) 'beatsPerBar': beatsPerBar,
        if (downbeatPhaseIndex != null)
          'downbeatPhaseIndex': downbeatPhaseIndex,
        if (meterConfidence != null) 'meterConfidence': meterConfidence,
        if (meterProvenance != null) 'meterProvenance': meterProvenance,
        if (downbeatPhaseConfidence != null)
          'downbeatPhaseConfidence': downbeatPhaseConfidence,
        if (downbeatPhaseProvenance != null)
          'downbeatPhaseProvenance': downbeatPhaseProvenance,
        if (phraseLengthBars != null) 'phraseLengthBars': phraseLengthBars,
        if (overrideRevision != null) 'overrideRevision': overrideRevision,
        if (beatsMs.isNotEmpty) 'beatGridMs': beatsMs,
        if (downbeatsMs.isNotEmpty) 'downbeatsMs': downbeatsMs,
        if (downbeatConfidence != null)
          'downbeatConfidence': downbeatConfidence,
        if (generatedTimingUnknown) 'generatedTimingUnknown': true,
        if (bpmProvenance != null) 'bpmProvenance': bpmProvenance,
        if (beatGridProvenance != null)
          'beatGridProvenance': beatGridProvenance,
        if (downbeatProvenance != null)
          'downbeatProvenance': downbeatProvenance,
        if (musicalKey != null) 'musicalKey': musicalKey,
        if (camelot != null) 'camelot': camelot,
      };

  factory ClipTempoMetadata.fromSessionJson(Map<String, dynamic> json) {
    return ClipTempoMetadata(
      nativeBpm: _readDouble(json['nativeBpm'] ?? json['bpm']),
      bpmConfidence: _readDouble(json['bpmConfidence']),
      beatGridOffsetMs: _readInt(json['beatGridOffsetMs'] ?? json['offsetMs']),
      beatAnchorMs: _readInt(json['beatAnchorMs'] ?? json['beat_anchor_ms']),
      beatsPerBar: _readInt(json['beatsPerBar'] ?? json['beats_per_bar']),
      downbeatPhaseIndex: _readInt(
        json['downbeatPhaseIndex'] ?? json['downbeat_phase_index'],
      ),
      meterConfidence: _readDouble(json['meterConfidence']),
      meterProvenance: _readString(json['meterProvenance']),
      downbeatPhaseConfidence: _readDouble(json['downbeatPhaseConfidence']),
      downbeatPhaseProvenance: _readString(json['downbeatPhaseProvenance']),
      phraseLengthBars: _readInt(
        json['phraseLengthBars'] ?? json['phrase_length_bars'],
      ),
      overrideRevision: _readInt(
        json['overrideRevision'] ?? json['override_revision'],
      ),
      beatsMs: _readIntList(json['beatGridMs'] ?? json['beatsMs']),
      downbeatsMs: _readIntList(json['downbeatsMs']),
      downbeatConfidence: _readDouble(json['downbeatConfidence']),
      generatedTimingUnknown: json['generatedTimingUnknown'] == true,
      bpmProvenance: _readString(json['bpmProvenance']),
      beatGridProvenance: _readString(json['beatGridProvenance']),
      downbeatProvenance: _readString(json['downbeatProvenance']),
      musicalKey: _readString(json['musicalKey'] ?? json['key']),
      camelot: _readString(json['camelot']),
    );
  }

  factory ClipTempoMetadata.fromAnalysisSummary(
    Object? summary, {
    Object? overrides,
  }) {
    final map = _readMap(summary);
    final embeddedOverrides = map == null
        ? null
        : map['analysisOverrides'] ??
            map['analysis_overrides'] ??
            map['overrides'];
    return ClipTempoMetadata.fromTrackAnalysis(
      TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: summary,
        overrides: overrides ?? embeddedOverrides,
        overridesPresent: overrides != null || embeddedOverrides != null,
      ),
    );
  }

  /// The track-analysis model is the only timing-override interpreter. Every
  /// playback consumer receives its effective grid/downbeats from this adapter
  /// instead of maintaining a parallel legacy override merge.
  factory ClipTempoMetadata.fromTrackAnalysis(TrackAnalysis analysis) {
    final summary = analysis.summary;
    final timing = analysis.effectiveTiming;
    final beatGrid = timing.beatGrid;
    final meter = timing.meter;
    final phase = timing.downbeatPhase;
    final downbeats = timing.downbeats;
    final canonicalManualDownbeats = timing.hasManualDownbeatAuthority;
    final legacyManualDownbeats = analysis.overrides?.downbeatsMs != null;
    final trustedDownbeats = canonicalManualDownbeats || legacyManualDownbeats;
    return ClipTempoMetadata(
      nativeBpm: timing.bpm?.numericValue?.toDouble() ??
          beatGrid?.bpm ??
          analysis.overrides?.manualTiming?.bpm,
      bpmConfidence: timing.bpm?.confidence ?? beatGrid?.confidence,
      beatGridOffsetMs: beatGrid?.offsetMs,
      beatAnchorMs: analysis.overrides?.manualTiming?.beatAnchorMs,
      beatsPerBar: meter?.beatsPerBar,
      downbeatPhaseIndex: phase?.index,
      meterConfidence: meter?.confidence,
      meterProvenance: meter?.provenance,
      downbeatPhaseConfidence: phase?.confidence,
      downbeatPhaseProvenance: phase?.provenance,
      phraseLengthBars: timing.phraseLengthBars,
      overrideRevision: timing.overrideRevision,
      beatsMs: beatGrid?.beatsMs ?? const [],
      // Generated marker arrays without manual timing authority remain visible
      // in analysis, but cannot become playback snap authority by omission.
      // Explicit legacy manual markers keep their pre-v2 compatibility path.
      downbeatsMs: downbeats?.positionsMs ?? const [],
      downbeatConfidence: downbeats?.confidence,
      generatedTimingUnknown: downbeats != null && !trustedDownbeats,
      bpmProvenance: timing.bpm?.provenance ?? beatGrid?.provenance,
      beatGridProvenance: beatGrid?.provenance,
      downbeatProvenance: downbeats?.provenance,
      musicalKey: summary?.key?.textValue,
      camelot: summary?.camelot?.textValue,
    );
  }

  bool get isEmpty =>
      nativeBpm == null &&
      bpmConfidence == null &&
      beatGridOffsetMs == null &&
      beatAnchorMs == null &&
      beatsPerBar == null &&
      downbeatPhaseIndex == null &&
      meterConfidence == null &&
      meterProvenance == null &&
      downbeatPhaseConfidence == null &&
      downbeatPhaseProvenance == null &&
      phraseLengthBars == null &&
      overrideRevision == null &&
      beatsMs.isEmpty &&
      downbeatsMs.isEmpty &&
      downbeatConfidence == null &&
      !generatedTimingUnknown &&
      bpmProvenance == null &&
      beatGridProvenance == null &&
      downbeatProvenance == null &&
      musicalKey == null &&
      camelot == null;

  @override
  bool operator ==(Object other) =>
      other is ClipTempoMetadata &&
      other.nativeBpm == nativeBpm &&
      other.bpmConfidence == bpmConfidence &&
      other.beatGridOffsetMs == beatGridOffsetMs &&
      other.beatAnchorMs == beatAnchorMs &&
      other.beatsPerBar == beatsPerBar &&
      other.downbeatPhaseIndex == downbeatPhaseIndex &&
      other.meterConfidence == meterConfidence &&
      other.meterProvenance == meterProvenance &&
      other.downbeatPhaseConfidence == downbeatPhaseConfidence &&
      other.downbeatPhaseProvenance == downbeatPhaseProvenance &&
      other.phraseLengthBars == phraseLengthBars &&
      other.overrideRevision == overrideRevision &&
      _sameInts(other.beatsMs, beatsMs) &&
      _sameInts(other.downbeatsMs, downbeatsMs) &&
      other.downbeatConfidence == downbeatConfidence &&
      other.generatedTimingUnknown == generatedTimingUnknown &&
      other.bpmProvenance == bpmProvenance &&
      other.beatGridProvenance == beatGridProvenance &&
      other.downbeatProvenance == downbeatProvenance &&
      other.musicalKey == musicalKey &&
      other.camelot == camelot;

  @override
  int get hashCode => Object.hashAll([
        nativeBpm,
        bpmConfidence,
        beatGridOffsetMs,
        beatAnchorMs,
        beatsPerBar,
        downbeatPhaseIndex,
        meterConfidence,
        meterProvenance,
        downbeatPhaseConfidence,
        downbeatPhaseProvenance,
        phraseLengthBars,
        overrideRevision,
        Object.hashAll(beatsMs),
        Object.hashAll(downbeatsMs),
        downbeatConfidence,
        generatedTimingUnknown,
        bpmProvenance,
        beatGridProvenance,
        downbeatProvenance,
        musicalKey,
        camelot,
      ]);
}

class PlaybackRateSegment {
  final int startMs;
  final int endMs;
  final double startRate;
  final double endRate;

  /// Octave interpretation selected for this transition. This never rewrites
  /// analyzer/manual BPM metadata or its source marker timestamps.
  final double tempoScale;

  const PlaybackRateSegment({
    required this.startMs,
    required this.endMs,
    required this.startRate,
    required this.endRate,
    this.tempoScale = 1,
  });

  int get durationMs => endMs - startMs;

  bool contains(int timelineMs) =>
      timelineMs >= startMs && timelineMs <= endMs && durationMs > 0;

  double rateAt(int timelineMs) {
    if (durationMs <= 0) return endRate;
    final t = ((timelineMs - startMs) / durationMs).clamp(0.0, 1.0).toDouble();
    return _lerp(
      startRate,
      endRate,
      t,
    ).clamp(minTempoAutomationRate, maxTempoAutomationRate).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackRateSegment &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.startRate == startRate &&
      other.endRate == endRate &&
      other.tempoScale == tempoScale;

  @override
  int get hashCode =>
      Object.hash(startMs, endMs, startRate, endRate, tempoScale);
}

class PlaybackRateAutomation {
  final double baseRate;
  final String pitchMode;
  final List<PlaybackRateSegment> segments;

  const PlaybackRateAutomation({
    this.baseRate = 1,
    this.pitchMode = 'preserve',
    this.segments = const [],
  });

  PlaybackRateAutomation withSegment(PlaybackRateSegment segment) {
    if (segment.endMs <= segment.startMs) return this;
    final next = [...segments, segment]..sort((a, b) {
        final byStart = a.startMs.compareTo(b.startMs);
        if (byStart != 0) return byStart;
        return a.endMs.compareTo(b.endMs);
      });
    return PlaybackRateAutomation(
      baseRate: baseRate,
      pitchMode: pitchMode,
      segments: List.unmodifiable(next),
    );
  }

  /// Rate segments use absolute mix time, so they follow a moved placement.
  PlaybackRateAutomation shiftedTimelineMs(int deltaMs) {
    if (deltaMs == 0 || segments.isEmpty) return this;
    return PlaybackRateAutomation(
      baseRate: baseRate,
      pitchMode: pitchMode,
      segments: List.unmodifiable([
        for (final segment in segments)
          PlaybackRateSegment(
            startMs: segment.startMs + deltaMs,
            endMs: segment.endMs + deltaMs,
            startRate: segment.startRate,
            endRate: segment.endRate,
            tempoScale: segment.tempoScale,
          ),
      ]),
    );
  }

  double rateAt(int timelineMs) {
    for (final segment in segments.reversed) {
      if (segment.contains(timelineMs)) return segment.rateAt(timelineMs);
    }
    return baseRate
        .clamp(minTempoAutomationRate, maxTempoAutomationRate)
        .toDouble();
  }

  double tempoScaleAt(int timelineMs) {
    for (final segment in segments.reversed) {
      if (segment.contains(timelineMs)) return segment.tempoScale;
    }
    return 1;
  }

  int sourceElapsedMs({required int timelineStartMs, required int timelineMs}) {
    if (timelineMs <= timelineStartMs) return 0;
    if (segments.isEmpty) {
      final rate = baseRate
          .clamp(minTempoAutomationRate, maxTempoAutomationRate)
          .toDouble();
      return ((timelineMs - timelineStartMs) * rate).round();
    }

    final breakpoints = <int>{timelineStartMs, timelineMs};
    for (final segment in segments) {
      if (segment.endMs <= timelineStartMs || segment.startMs >= timelineMs) {
        continue;
      }
      breakpoints
        ..add(segment.startMs.clamp(timelineStartMs, timelineMs))
        ..add(segment.endMs.clamp(timelineStartMs, timelineMs));
    }

    final points = breakpoints.toList()..sort();
    var elapsed = 0.0;
    for (var i = 0; i + 1 < points.length; i++) {
      final start = points[i];
      final end = points[i + 1];
      if (end <= start) continue;
      final startRate = rateAt(start);
      final endRate = rateAt(end);
      elapsed += (end - start) * ((startRate + endRate) / 2);
    }
    return elapsed.round();
  }

  int timelineMsForSourceElapsed({
    required int timelineStartMs,
    required int sourceElapsedMs,
    required int maxTimelineMs,
  }) {
    if (sourceElapsedMs <= 0) return timelineStartMs;
    var low = timelineStartMs;
    var high = math.max(timelineStartMs, maxTimelineMs);
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      final elapsed = this.sourceElapsedMs(
        timelineStartMs: timelineStartMs,
        timelineMs: mid,
      );
      if (elapsed >= sourceElapsedMs) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return low;
  }

  int timelineMsForSelectedSource({
    required int timelineStartMs,
    required int sourceDurationMs,
  }) {
    if (sourceDurationMs <= 0) return timelineStartMs;

    if (segments.isEmpty) {
      final rate = baseRate
          .clamp(minTempoAutomationRate, maxTempoAutomationRate)
          .toDouble();
      return timelineStartMs + (sourceDurationMs / rate).ceil();
    }

    var high = timelineStartMs + sourceDurationMs;
    final maxHigh = timelineStartMs +
        (sourceDurationMs / minTempoAutomationRate).ceil() +
        1;
    while (high < maxHigh &&
        sourceElapsedMs(timelineStartMs: timelineStartMs, timelineMs: high) <
            sourceDurationMs) {
      high = math.min(maxHigh, high + math.max(1, sourceDurationMs ~/ 4));
    }

    return timelineMsForSourceElapsed(
      timelineStartMs: timelineStartMs,
      sourceElapsedMs: sourceDurationMs,
      maxTimelineMs: high,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackRateAutomation &&
      other.baseRate == baseRate &&
      other.pitchMode == pitchMode &&
      _sameSegments(other.segments, segments);

  @override
  int get hashCode =>
      Object.hash(baseRate, pitchMode, Object.hashAll(segments));
}

class ClipTempoRuntimeState {
  final String clipId;
  final double effectiveSpeed;
  final double? nativeBpm;
  final double? effectiveBpm;
  final String pitchMode;
  final bool pitchFallback;

  const ClipTempoRuntimeState({
    required this.clipId,
    required this.effectiveSpeed,
    required this.nativeBpm,
    required this.effectiveBpm,
    required this.pitchMode,
    this.pitchFallback = false,
  });

  @override
  bool operator ==(Object other) =>
      other is ClipTempoRuntimeState &&
      other.clipId == clipId &&
      other.effectiveSpeed == effectiveSpeed &&
      other.nativeBpm == nativeBpm &&
      other.effectiveBpm == effectiveBpm &&
      other.pitchMode == pitchMode &&
      other.pitchFallback == pitchFallback;

  @override
  int get hashCode => Object.hash(
        clipId,
        effectiveSpeed,
        nativeBpm,
        effectiveBpm,
        pitchMode,
        pitchFallback,
      );
}

class TempoTransitionBpmPair {
  /// BPM values after selecting the octave interpretation. Raw analyzer/manual
  /// metadata remains on [ClipTempoMetadata].
  final double outgoingBpm;
  final double incomingBpm;
  final double outgoingTempoScale;
  final double incomingTempoScale;

  const TempoTransitionBpmPair({
    required this.outgoingBpm,
    required this.incomingBpm,
    required this.outgoingTempoScale,
    required this.incomingTempoScale,
  });

  double get outgoingEffectiveBpm => outgoingBpm;
  double get incomingEffectiveBpm => incomingBpm;
}

class TempoTransitionRatePlan {
  final PlaybackRateSegment outgoingSegment;
  final PlaybackRateSegment incomingSegment;
  final double outgoingTempoScale;
  final double incomingTempoScale;

  const TempoTransitionRatePlan({
    required this.outgoingSegment,
    required this.incomingSegment,
    required this.outgoingTempoScale,
    required this.incomingTempoScale,
  });

  PlaybackRateAutomation applyToOutgoing(PlaybackRateAutomation automation) =>
      automation.withSegment(outgoingSegment);

  PlaybackRateAutomation applyToIncoming(PlaybackRateAutomation automation) =>
      automation.withSegment(incomingSegment);
}

TempoTransitionBpmPair? resolveTempoTransitionBpmPair({
  required ClipTempoMetadata outgoingTempo,
  required ClipTempoMetadata incomingTempo,
  double outgoingBaseRate = 1,
  double incomingBaseRate = 1,
}) {
  final outgoingRawBpm = outgoingTempo.nativeBpm;
  final incomingRawBpm = incomingTempo.nativeBpm;
  if (outgoingRawBpm == null ||
      !outgoingRawBpm.isFinite ||
      outgoingRawBpm <= 0 ||
      incomingRawBpm == null ||
      !incomingRawBpm.isFinite ||
      incomingRawBpm <= 0) {
    return null;
  }

  TempoTransitionBpmPair? best;
  var bestRateAdjustment = double.infinity;
  var bestPulseDistance = double.infinity;
  var bestScaleDistance = double.infinity;
  const epsilon = 0.000001;
  final safeOutgoingBaseRate = _safeBaseRate(outgoingBaseRate);
  final safeIncomingBaseRate = _safeBaseRate(incomingBaseRate);

  for (final outgoingScale in tempoOctaveScales) {
    final outgoingBpm = outgoingRawBpm * outgoingScale;
    for (final incomingScale in tempoOctaveScales) {
      final incomingBpm = incomingRawBpm * incomingScale;
      final outgoingEndRate = incomingBpm * safeIncomingBaseRate / outgoingBpm;
      final incomingStartRate =
          outgoingBpm * safeOutgoingBaseRate / incomingBpm;
      if (!_isSafeTempoRate(outgoingEndRate) ||
          !_isSafeTempoRate(incomingStartRate)) {
        continue;
      }

      final rateAdjustment = (outgoingEndRate - safeOutgoingBaseRate).abs() +
          (incomingStartRate - safeIncomingBaseRate).abs();
      // Equivalent rate pulls are resolved into the DJ-usable pulse range,
      // before preferring interpretations closest to raw 1x values.
      final pulseDistance = (outgoingBpm - _preferredTransitionBpm).abs() +
          (incomingBpm - _preferredTransitionBpm).abs();
      final scaleDistance =
          (outgoingScale - 1).abs() + (incomingScale - 1).abs();
      final isBetter = rateAdjustment < bestRateAdjustment - epsilon ||
          ((rateAdjustment - bestRateAdjustment).abs() <= epsilon &&
              (pulseDistance < bestPulseDistance - epsilon ||
                  ((pulseDistance - bestPulseDistance).abs() <= epsilon &&
                      scaleDistance < bestScaleDistance - epsilon)));
      if (!isBetter) continue;

      best = TempoTransitionBpmPair(
        outgoingTempoScale: outgoingScale,
        incomingTempoScale: incomingScale,
        outgoingBpm: outgoingBpm,
        incomingBpm: incomingBpm,
      );
      bestRateAdjustment = rateAdjustment;
      bestPulseDistance = pulseDistance;
      bestScaleDistance = scaleDistance;
    }
  }
  return best;
}

TempoTransitionRatePlan? planTempoMatchedTransition({
  required int overlapStartMs,
  required int overlapEndMs,
  required ClipTempoMetadata outgoingTempo,
  required ClipTempoMetadata incomingTempo,
  double outgoingBaseRate = 1,
  double incomingBaseRate = 1,
}) {
  if (overlapEndMs <= overlapStartMs) return null;
  if (!outgoingTempo.hasReliableBpm || !incomingTempo.hasReliableBpm) {
    return null;
  }

  final bpmPair = resolveTempoTransitionBpmPair(
    outgoingTempo: outgoingTempo,
    incomingTempo: incomingTempo,
    outgoingBaseRate: outgoingBaseRate,
    incomingBaseRate: incomingBaseRate,
  );
  if (bpmPair == null) return null;

  final transitionStartBpm = effectiveBpmForRate(
    nativeBpm: bpmPair.outgoingBpm,
    rate: outgoingBaseRate,
  );
  final transitionEndBpm = effectiveBpmForRate(
    nativeBpm: bpmPair.incomingBpm,
    rate: incomingBaseRate,
  );

  final outgoingStartRate = playbackRateForTargetBpm(
    baseRate: outgoingBaseRate,
    nativeBpm: bpmPair.outgoingBpm,
    targetBpm: transitionStartBpm,
  );
  final outgoingEndRate = playbackRateForTargetBpm(
    baseRate: outgoingBaseRate,
    nativeBpm: bpmPair.outgoingBpm,
    targetBpm: transitionEndBpm,
  );
  final incomingStartRate = playbackRateForTargetBpm(
    baseRate: incomingBaseRate,
    nativeBpm: bpmPair.incomingBpm,
    targetBpm: transitionStartBpm,
  );
  final incomingEndRate = playbackRateForTargetBpm(
    baseRate: incomingBaseRate,
    nativeBpm: bpmPair.incomingBpm,
    targetBpm: transitionEndBpm,
  );

  return TempoTransitionRatePlan(
    outgoingSegment: PlaybackRateSegment(
      startMs: overlapStartMs,
      endMs: overlapEndMs,
      startRate: outgoingStartRate,
      endRate: outgoingEndRate,
      tempoScale: bpmPair.outgoingTempoScale,
    ),
    incomingSegment: PlaybackRateSegment(
      startMs: overlapStartMs,
      endMs: overlapEndMs,
      startRate: incomingStartRate,
      endRate: incomingEndRate,
      tempoScale: bpmPair.incomingTempoScale,
    ),
    outgoingTempoScale: bpmPair.outgoingTempoScale,
    incomingTempoScale: bpmPair.incomingTempoScale,
  );
}

bool tempoTransitionTargetsAreAchievable({
  required ClipTempoMetadata outgoingTempo,
  required ClipTempoMetadata incomingTempo,
  double outgoingBaseRate = 1,
  double incomingBaseRate = 1,
}) {
  return resolveTempoTransitionBpmPair(
        outgoingTempo: outgoingTempo,
        incomingTempo: incomingTempo,
        outgoingBaseRate: outgoingBaseRate,
        incomingBaseRate: incomingBaseRate,
      ) !=
      null;
}

double effectiveBpmForRate({
  required double nativeBpm,
  required double rate,
  double tempoScale = 1,
}) {
  if (!nativeBpm.isFinite || nativeBpm <= 0) return 0;
  return nativeBpm * tempoScale * _safeBaseRate(rate);
}

bool _isSafeTempoRate(double rate) =>
    rate >= minTempoAutomationRate && rate <= maxTempoAutomationRate;

bool playbackRateCanReachTargetBpm({
  required double baseRate,
  required double nativeBpm,
  required double targetBpm,
}) {
  if (!nativeBpm.isFinite ||
      nativeBpm <= 0 ||
      !targetBpm.isFinite ||
      targetBpm <= 0) {
    return false;
  }
  final rate = rawPlaybackRateForTargetBpm(
    baseRate: baseRate,
    nativeBpm: nativeBpm,
    targetBpm: targetBpm,
  );
  const epsilon = 0.000001;
  return rate >= minTempoAutomationRate - epsilon &&
      rate <= maxTempoAutomationRate + epsilon;
}

double rawPlaybackRateForTargetBpm({
  required double baseRate,
  required double nativeBpm,
  required double targetBpm,
}) {
  if (!nativeBpm.isFinite ||
      nativeBpm <= 0 ||
      !targetBpm.isFinite ||
      targetBpm <= 0) {
    return _safeBaseRate(baseRate);
  }
  return targetBpm / nativeBpm;
}

double playbackRateForTargetBpm({
  required double baseRate,
  required double nativeBpm,
  required double targetBpm,
}) {
  if (!nativeBpm.isFinite || nativeBpm <= 0) {
    return baseRate
        .clamp(minTempoAutomationRate, maxTempoAutomationRate)
        .toDouble();
  }
  return rawPlaybackRateForTargetBpm(
    baseRate: baseRate,
    nativeBpm: nativeBpm,
    targetBpm: targetBpm,
  ).clamp(minTempoAutomationRate, maxTempoAutomationRate).toDouble();
}

double _safeBaseRate(double baseRate) {
  if (!baseRate.isFinite || baseRate <= 0) return 1;
  return baseRate
      .clamp(minTempoAutomationRate, maxTempoAutomationRate)
      .toDouble();
}

double pitchFactorForRate({required double rate, required String pitchMode}) {
  final safeRate =
      rate.clamp(minTempoAutomationRate, maxTempoAutomationRate).toDouble();
  return pitchModeFollowsTempo(pitchMode) ? safeRate : 1;
}

String normalizePitchMode(String pitchMode) {
  final normalized = pitchMode.trim().toLowerCase().replaceAll(
        RegExp(r'[\s_-]+'),
        '',
      );

  switch (normalized) {
    case 'followtempo':
    case 'followrate':
    case 'follow':
    case 'vinyl':
    case 'resample':
      return pitchModeFollowTempo;
    case 'preserve':
    case 'preservepitch':
    case 'keylock':
    case 'keepkey':
    default:
      return pitchModePreserve;
  }
}

bool pitchModeFollowsTempo(String pitchMode) =>
    normalizePitchMode(pitchMode) == pitchModeFollowTempo;

int? snapIncomingStartToNearestDownbeat({
  required int requestedStartMs,
  required int incomingSourceStartMs,
  required ClipTempoMetadata incomingTempo,
  required int outgoingTimelineStartMs,
  required int outgoingSourceStartMs,
  required ClipTempoMetadata outgoingTempo,
  double outgoingBaseRate = 1,
  double incomingBaseRate = 1,
  BeatSnapMode snapMode = BeatSnapMode.downbeat,
  int toleranceMs = 900,
}) {
  if (snapMode == BeatSnapMode.free) return null;

  final incomingMarkers = beatMarkersForSnapMode(incomingTempo, snapMode);
  final outgoingMarkers = beatMarkersForSnapMode(outgoingTempo, snapMode);
  if (incomingMarkers.isEmpty || outgoingMarkers.isEmpty) return null;

  final incomingAnchor = _firstMarkerAtOrAfter(
    incomingMarkers,
    incomingSourceStartMs,
  );
  if (incomingAnchor == null) return null;
  final outgoingRate = _safeBaseRate(outgoingBaseRate);
  final outgoingGlobals = outgoingMarkers
      .map(
        (ms) =>
            outgoingTimelineStartMs +
            ((ms - outgoingSourceStartMs) / outgoingRate).round(),
      )
      .where((ms) => ms >= 0)
      .toList(growable: false);
  if (outgoingGlobals.isEmpty) return null;

  var nearest = outgoingGlobals.first;
  var nearestDistance = (nearest - requestedStartMs).abs();
  for (final candidate in outgoingGlobals.skip(1)) {
    final distance = (candidate - requestedStartMs).abs();
    if (distance < nearestDistance) {
      nearest = candidate;
      nearestDistance = distance;
    }
  }
  if (nearestDistance > toleranceMs) return null;

  final anchorOffsetMs = _incomingDownbeatTimelineOffsetMs(
    sourceDeltaMs: incomingAnchor - incomingSourceStartMs,
    incomingTempo: incomingTempo,
    outgoingTempo: outgoingTempo,
    outgoingBaseRate: outgoingBaseRate,
    incomingBaseRate: incomingBaseRate,
  );
  final snapped = nearest - anchorOffsetMs;
  return math.max(0, snapped);
}

List<int> beatMarkersForSnapMode(ClipTempoMetadata tempo, BeatSnapMode snapMode,
    {double tempoScale = 1}) {
  final beats = tempo.hasReliableBeatGrid
      ? normalizedBeatMarkersForTempo(tempo, tempoScale: tempoScale)
      : const <int>[];
  final downbeats = tempo.hasDownbeats
      ? _sortedUniqueNonNegative(tempo.downbeatsMs)
      : const <int>[];

  return switch (snapMode) {
    BeatSnapMode.free => const [],
    BeatSnapMode.downbeat => downbeats,
    BeatSnapMode.beat1 => beats.isNotEmpty ? beats : downbeats,
    BeatSnapMode.beat4 =>
      downbeats.isNotEmpty ? downbeats : _strideMarkers(beats, 4),
    BeatSnapMode.beat16 => downbeats.isNotEmpty
        ? _strideMarkers(downbeats, 4)
        : _strideMarkers(beats, 16),
  };
}

/// Projects a reliable raw beat grid into the selected octave interpretation.
/// Source timestamps are not stored back into [ClipTempoMetadata], and phrase
/// downbeats remain raw anchors rather than interpolated beats.
List<int> normalizedBeatMarkersForTempo(
  ClipTempoMetadata tempo, {
  double tempoScale = 1,
}) {
  return normalizeBeatMarkerTimestamps(tempo.beatsMs, tempoScale: tempoScale);
}

List<int> normalizeBeatMarkerTimestamps(
  List<int> sourceMarkers, {
  double tempoScale = 1,
}) {
  final raw = _sortedUniqueNonNegative(sourceMarkers);
  if (raw.length < 2 || tempoScale == 1) return raw;
  if (tempoScale >= 1.5) {
    final markers = <int>[];
    for (var index = 0; index + 1 < raw.length; index++) {
      final current = raw[index];
      final next = raw[index + 1];
      markers
        ..add(current)
        ..add(current + ((next - current) / 2).round());
    }
    markers.add(raw.last);
    return markers;
  }
  if (tempoScale <= 0.75) return _strideMarkers(raw, 2);
  return raw;
}

/// Projects raw beat markers only where a tempo-scale segment is active.
///
/// The callbacks keep this helper independent from timeline placement while
/// ensuring marker decisions use their actual global timeline positions.
List<int> projectBeatMarkersForTempoSegments(
  List<int> sourceMarkers, {
  required int Function(int sourcePositionMs) timelineMsForSourcePosition,
  required double Function(int timelineMs) tempoScaleAt,
}) {
  final raw = _sortedUniqueNonNegative(sourceMarkers);
  if (raw.length < 2) return raw;

  final projected = <int>[];
  var halfTimeRunIndex = 0;
  var wasHalfTime = false;
  for (final marker in raw) {
    final scale = tempoScaleAt(timelineMsForSourcePosition(marker));
    final isHalfTime = scale <= 0.75;
    if (!isHalfTime) {
      projected.add(marker);
      wasHalfTime = false;
      continue;
    }

    if (!wasHalfTime) halfTimeRunIndex = 0;
    if (halfTimeRunIndex.isEven) projected.add(marker);
    halfTimeRunIndex++;
    wasHalfTime = true;
  }

  for (var index = 0; index + 1 < raw.length; index++) {
    final current = raw[index];
    final next = raw[index + 1];
    final midpoint = current + ((next - current) / 2).round();
    if (midpoint <= current || midpoint >= next) continue;
    if (tempoScaleAt(timelineMsForSourcePosition(midpoint)) >= 1.5) {
      projected.add(midpoint);
    }
  }

  return _sortedUniqueNonNegative(projected);
}

List<int> _sortedUniqueNonNegative(List<int> values) {
  final sorted = values.where((value) => value >= 0).toSet().toList()..sort();
  return sorted;
}

bool _isStrictlyIncreasingNonNegative(List<int> values) {
  if (values.isEmpty || values.first < 0) return false;
  for (var index = 1; index < values.length; index++) {
    if (values[index] <= values[index - 1]) return false;
  }
  return true;
}

bool _downbeatsFollowBeatGrid(List<int> beats, List<int> downbeats) {
  final beatSet = beats.toSet();
  for (final downbeat in downbeats) {
    if (downbeat >= beats.first && downbeat <= beats.last) {
      if (!beatSet.contains(downbeat)) return false;
      continue;
    }
    if (beats.length < 2) return false;
    final beforeGrid = downbeat < beats.first;
    final anchor = beforeGrid ? beats.first : beats.last;
    final interval = beforeGrid
        ? beats[1] - beats.first
        : beats.last - beats[beats.length - 2];
    if (interval <= 0 || (downbeat - anchor).abs() % interval != 0) {
      return false;
    }
  }
  return true;
}

bool _isManualBeatGridProvenance(String? provenance) =>
    provenance?.trim().toLowerCase() == manualTempoProvenance;

bool _hasStructurallyReliableBeatIntervals(List<int> sortedBeats) {
  if (sortedBeats.length < 2) return false;
  final intervals = <int>[
    for (var index = 1; index < sortedBeats.length; index++)
      sortedBeats[index] - sortedBeats[index - 1],
  ];
  final median = _medianInt(intervals);
  if (median <= 0) return false;
  for (final interval in intervals) {
    if (interval < median * minReliableBeatIntervalMedianRatio ||
        interval > median * maxReliableBeatIntervalMedianRatio) {
      return false;
    }
  }
  return true;
}

int _medianInt(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

List<int> _strideMarkers(List<int> markers, int stride) {
  if (markers.isEmpty) return const [];
  if (stride <= 1) return markers;
  return [
    for (var index = 0; index < markers.length; index += stride) markers[index]
  ];
}

int? _firstMarkerAtOrAfter(List<int> markers, int sourceMs) {
  int? first;
  for (final marker in markers) {
    if (marker < sourceMs) continue;
    if (first == null || marker < first) first = marker;
  }
  return first;
}

int _incomingDownbeatTimelineOffsetMs({
  required int sourceDeltaMs,
  required ClipTempoMetadata incomingTempo,
  required ClipTempoMetadata outgoingTempo,
  required double outgoingBaseRate,
  required double incomingBaseRate,
}) {
  final safeSourceDeltaMs = math.max(0, sourceDeltaMs);
  if (safeSourceDeltaMs == 0) return 0;

  final bpmPair = incomingTempo.hasReliableBpm && outgoingTempo.hasReliableBpm
      ? resolveTempoTransitionBpmPair(
          outgoingTempo: outgoingTempo,
          incomingTempo: incomingTempo,
          outgoingBaseRate: outgoingBaseRate,
          incomingBaseRate: incomingBaseRate,
        )
      : null;
  if (bpmPair != null) {
    final outgoingEffectiveBpm = effectiveBpmForRate(
      nativeBpm: bpmPair.outgoingBpm,
      rate: outgoingBaseRate,
    );
    final incomingStartRate = playbackRateForTargetBpm(
      baseRate: incomingBaseRate,
      nativeBpm: bpmPair.incomingBpm,
      targetBpm: outgoingEffectiveBpm,
    );
    if (incomingStartRate > 0) {
      return (safeSourceDeltaMs / incomingStartRate).round();
    }
  }

  return safeSourceDeltaMs;
}

int defaultTransitionOverlapMsForTempo({
  required int outgoingSelectedDurationMs,
  required ClipTempoMetadata outgoingTempo,
  required int incomingSelectedDurationMs,
  required ClipTempoMetadata incomingTempo,
  int phraseBeats = defaultTransitionPhraseBeats,
  int minOverlapMs = minDefaultTransitionOverlapMs,
  int maxOverlapMs = maxDefaultTransitionOverlapMs,
}) {
  if (!outgoingTempo.hasReliableBpm ||
      !incomingTempo.hasReliableBpm ||
      !outgoingTempo.hasDownbeats ||
      !incomingTempo.hasDownbeats) {
    return 0;
  }

  if (phraseBeats <= 0) return 0;
  final bpmPair = resolveTempoTransitionBpmPair(
    outgoingTempo: outgoingTempo,
    incomingTempo: incomingTempo,
  );
  if (bpmPair == null) return 0;

  final beatMs = 60000 / bpmPair.outgoingBpm;
  final phraseMs = (beatMs * phraseBeats).round();
  final safeMinOverlapMs = math.max(0, minOverlapMs);
  final safeMaxOverlapMs = math.max(
    safeMinOverlapMs,
    math.max(0, maxOverlapMs),
  );
  final boundedPhraseMs =
      phraseMs.clamp(safeMinOverlapMs, safeMaxOverlapMs).toInt();
  final maxSafeOverlap = math.min(
    math.max(0, outgoingSelectedDurationMs) ~/ 2,
    math.max(0, incomingSelectedDurationMs) ~/ 2,
  );
  final overlapMs = math.min(boundedPhraseMs, maxSafeOverlap);
  return overlapMs < 1000 ? 0 : overlapMs;
}

int downbeatSnapToleranceMs(
  ClipTempoMetadata tempo, {
  BeatSnapMode snapMode = BeatSnapMode.downbeat,
  double baseRate = 1,
  double tempoScale = 1,
}) {
  final bpm = tempo.nativeBpm;
  if (bpm == null || bpm <= 0) return 900;
  final effectiveBpm = effectiveBpmForRate(
    nativeBpm: bpm,
    rate: baseRate,
    tempoScale: tempoScale,
  );
  final beatStride = switch (snapMode) {
    BeatSnapMode.free => 1,
    BeatSnapMode.downbeat || BeatSnapMode.beat4 => 4,
    BeatSnapMode.beat1 => 1,
    BeatSnapMode.beat16 => 16,
  };
  return math.max(
    900,
    (60000 / effectiveBpm * beatStride / 2).round(),
  );
}

int defaultDownbeatLockedTransitionStartMs({
  required int outgoingTimelineStartMs,
  required int outgoingTimelineEndMs,
  required int outgoingSourceStartMs,
  required int outgoingSelectedDurationMs,
  required ClipTempoMetadata outgoingTempo,
  required int incomingSourceStartMs,
  required int incomingSelectedDurationMs,
  required ClipTempoMetadata incomingTempo,
  double outgoingBaseRate = 1,
  double incomingBaseRate = 1,
  BeatSnapMode snapMode = BeatSnapMode.downbeat,
  int? fallbackStartMs,
}) {
  final fallback = math.max(0, fallbackStartMs ?? outgoingTimelineEndMs);
  if (snapMode == BeatSnapMode.free) return fallback;
  final overlapMs = defaultTransitionOverlapMsForTempo(
    outgoingSelectedDurationMs: outgoingSelectedDurationMs,
    outgoingTempo: outgoingTempo,
    incomingSelectedDurationMs: incomingSelectedDurationMs,
    incomingTempo: incomingTempo,
  );
  if (overlapMs <= 0) return fallback;

  final requestedStartMs = math.max(0, outgoingTimelineEndMs - overlapMs);
  final snapped = snapIncomingStartToNearestDownbeat(
    requestedStartMs: requestedStartMs,
    incomingSourceStartMs: incomingSourceStartMs,
    incomingTempo: incomingTempo,
    outgoingTimelineStartMs: outgoingTimelineStartMs,
    outgoingSourceStartMs: outgoingSourceStartMs,
    outgoingTempo: outgoingTempo,
    outgoingBaseRate: outgoingBaseRate,
    incomingBaseRate: incomingBaseRate,
    snapMode: snapMode,
    toleranceMs: downbeatSnapToleranceMs(
      outgoingTempo,
      snapMode: snapMode,
      baseRate: outgoingBaseRate,
    ),
  );

  if (snapped == null) return fallback;

  final actualOverlapMs = outgoingTimelineEndMs - snapped;
  final maxSafeOverlapMs = math.min(
    math.max(0, outgoingSelectedDurationMs) ~/ 2,
    math.max(0, incomingSelectedDurationMs) ~/ 2,
  );
  if (snapped < math.max(0, outgoingTimelineStartMs) ||
      actualOverlapMs < 1000 ||
      actualOverlapMs > maxSafeOverlapMs) {
    return fallback;
  }

  return snapped;
}

Map<String, dynamic>? _readMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

double? _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _readString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

List<int> _readIntList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((entry) {
        if (entry is int) return entry;
        if (entry is num) return entry.round();
        if (entry is String) return int.tryParse(entry);
        return null;
      })
      .whereType<int>()
      .where((entry) => entry >= 0)
      .toList(growable: false);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

bool _sameSegments(List<PlaybackRateSegment> a, List<PlaybackRateSegment> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameInts(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
