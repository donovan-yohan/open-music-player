import 'dart:math' as math;

const double minTempoAutomationRate = 0.5;
const double maxTempoAutomationRate = 2.0;
const double reliableBpmConfidenceFloor = 0.55;
const int defaultTransitionPhraseBeats = 16;
const int minDefaultTransitionOverlapMs = 4000;
const int maxDefaultTransitionOverlapMs = 12000;
const String pitchModePreserve = 'preserve';
const String pitchModeFollowTempo = 'followTempo';

class ClipTempoMetadata {
  final double? nativeBpm;
  final double? bpmConfidence;
  final List<int> beatsMs;
  final List<int> downbeatsMs;
  final String? musicalKey;
  final String? camelot;

  const ClipTempoMetadata({
    this.nativeBpm,
    this.bpmConfidence,
    this.beatsMs = const [],
    this.downbeatsMs = const [],
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

  bool get hasDownbeats => downbeatsMs.isNotEmpty;

  Map<String, dynamic> toJson() => {
        if (nativeBpm != null) 'nativeBpm': nativeBpm,
        if (bpmConfidence != null) 'bpmConfidence': bpmConfidence,
        if (beatsMs.isNotEmpty) 'beatGridMs': beatsMs,
        if (downbeatsMs.isNotEmpty) 'downbeatsMs': downbeatsMs,
        if (musicalKey != null) 'musicalKey': musicalKey,
        if (camelot != null) 'camelot': camelot,
      };

  factory ClipTempoMetadata.fromSessionJson(Map<String, dynamic> json) {
    return ClipTempoMetadata(
      nativeBpm: _readDouble(json['nativeBpm'] ?? json['bpm']),
      bpmConfidence: _readDouble(json['bpmConfidence']),
      beatsMs: _readIntList(json['beatGridMs'] ?? json['beatsMs']),
      downbeatsMs: _readIntList(json['downbeatsMs']),
      musicalKey: _readString(json['musicalKey'] ?? json['key']),
      camelot: _readString(json['camelot']),
    );
  }

  factory ClipTempoMetadata.fromAnalysisSummary(
    Object? summary, {
    Object? overrides,
  }) {
    final map = _readMap(summary);
    final base = map == null || map.isEmpty
        ? ClipTempoMetadata.empty
        : ClipTempoMetadata._fromAnalysisMap(map);

    final embeddedOverrides = map == null
        ? null
        : map['analysisOverrides'] ??
            map['analysis_overrides'] ??
            map['overrides'];
    final parsedOverrides = _ClipTempoOverrides.fromJson(
      overrides ?? embeddedOverrides,
    );
    return parsedOverrides == null ? base : parsedOverrides.applyTo(base);
  }

  factory ClipTempoMetadata._fromAnalysisMap(Map<String, dynamic> map) {
    final bpmValue = _readAnalysisValue(map['bpm']);
    final bpmMap = _readMap(map['bpm']);
    final beatGrid = _readMap(map['beat_grid'] ?? map['beatGrid']);
    final downbeats = _readMap(map['downbeats']);
    final keyValue = _readAnalysisText(map['key']);
    final camelotValue = _readAnalysisText(map['camelot']);

    return ClipTempoMetadata(
      nativeBpm: bpmValue ?? _readDouble(beatGrid?['bpm']),
      bpmConfidence: _readDouble(bpmMap?['confidence']) ??
          _readDouble(beatGrid?['confidence']),
      beatsMs: _readIntList(beatGrid?['beats_ms'] ?? beatGrid?['beatsMs']),
      downbeatsMs: _readIntList(
        downbeats?['positions_ms'] ?? downbeats?['positionsMs'],
      ),
      musicalKey: keyValue,
      camelot: camelotValue,
    );
  }

  bool get isEmpty =>
      nativeBpm == null &&
      bpmConfidence == null &&
      beatsMs.isEmpty &&
      downbeatsMs.isEmpty &&
      musicalKey == null &&
      camelot == null;

  @override
  bool operator ==(Object other) =>
      other is ClipTempoMetadata &&
      other.nativeBpm == nativeBpm &&
      other.bpmConfidence == bpmConfidence &&
      _sameInts(other.beatsMs, beatsMs) &&
      _sameInts(other.downbeatsMs, downbeatsMs) &&
      other.musicalKey == musicalKey &&
      other.camelot == camelot;

  @override
  int get hashCode => Object.hash(
        nativeBpm,
        bpmConfidence,
        Object.hashAll(beatsMs),
        Object.hashAll(downbeatsMs),
        musicalKey,
        camelot,
      );
}

class _ClipTempoOverrides {
  final double? nativeBpm;
  final double? bpmConfidence;
  final List<int>? beatsMs;
  final List<int>? downbeatsMs;
  final String? musicalKey;
  final String? camelot;

  const _ClipTempoOverrides({
    this.nativeBpm,
    this.bpmConfidence,
    this.beatsMs,
    this.downbeatsMs,
    this.musicalKey,
    this.camelot,
  });

  static _ClipTempoOverrides? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null || map.isEmpty) return null;
    final bpmMap = _readMap(map['bpm']);
    final beatGrid = _readMap(map['beat_grid'] ?? map['beatGrid']);
    final downbeats = _readMap(map['downbeats']);
    final key = map['key'] ?? map['musicalKey'];
    final overrides = _ClipTempoOverrides(
      nativeBpm: _readAnalysisValue(map['bpm']) ??
          _readDouble(map['nativeBpm']) ??
          _readDouble(beatGrid?['bpm']),
      bpmConfidence: _readDouble(map['bpmConfidence']) ??
          _readDouble(bpmMap?['confidence']) ??
          _readDouble(beatGrid?['confidence']),
      beatsMs: _readNullableIntList(
        map['beatGridMs'] ??
            map['beatsMs'] ??
            beatGrid?['beats_ms'] ??
            beatGrid?['beatsMs'],
      ),
      downbeatsMs: _readNullableIntList(
        map['downbeatsMs'] ??
            downbeats?['positions_ms'] ??
            downbeats?['positionsMs'],
      ),
      musicalKey: _readAnalysisText(key),
      camelot: _readAnalysisText(map['camelot']),
    );
    return overrides.isEmpty ? null : overrides;
  }

  bool get isEmpty =>
      nativeBpm == null &&
      bpmConfidence == null &&
      beatsMs == null &&
      downbeatsMs == null &&
      musicalKey == null &&
      camelot == null;

  ClipTempoMetadata applyTo(ClipTempoMetadata base) {
    final effectiveBpmConfidence =
        bpmConfidence ?? (nativeBpm == null ? null : 1.0);
    return ClipTempoMetadata(
      nativeBpm: nativeBpm ?? base.nativeBpm,
      bpmConfidence: effectiveBpmConfidence ?? base.bpmConfidence,
      beatsMs: beatsMs ?? base.beatsMs,
      downbeatsMs: downbeatsMs ?? base.downbeatsMs,
      musicalKey: musicalKey ?? base.musicalKey,
      camelot: camelot ?? base.camelot,
    );
  }
}

class PlaybackRateSegment {
  final int startMs;
  final int endMs;
  final double startRate;
  final double endRate;

  const PlaybackRateSegment({
    required this.startMs,
    required this.endMs,
    required this.startRate,
    required this.endRate,
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
      other.endRate == endRate;

  @override
  int get hashCode => Object.hash(startMs, endMs, startRate, endRate);
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

  double rateAt(int timelineMs) {
    for (final segment in segments.reversed) {
      if (segment.contains(timelineMs)) return segment.rateAt(timelineMs);
    }
    return baseRate
        .clamp(minTempoAutomationRate, maxTempoAutomationRate)
        .toDouble();
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

class TempoTransitionRatePlan {
  final PlaybackRateSegment outgoingSegment;
  final PlaybackRateSegment incomingSegment;

  const TempoTransitionRatePlan({
    required this.outgoingSegment,
    required this.incomingSegment,
  });

  PlaybackRateAutomation applyToOutgoing(PlaybackRateAutomation automation) =>
      automation.withSegment(outgoingSegment);

  PlaybackRateAutomation applyToIncoming(PlaybackRateAutomation automation) =>
      automation.withSegment(incomingSegment);
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

  final outgoingBpm = outgoingTempo.nativeBpm;
  final incomingBpm = incomingTempo.nativeBpm;
  if (outgoingBpm == null ||
      outgoingBpm <= 0 ||
      incomingBpm == null ||
      incomingBpm <= 0) {
    return null;
  }

  final outgoingStartRate = playbackRateForTargetBpm(
    baseRate: outgoingBaseRate,
    nativeBpm: outgoingBpm,
    targetBpm: outgoingBpm,
  );
  final outgoingEndRate = playbackRateForTargetBpm(
    baseRate: outgoingBaseRate,
    nativeBpm: outgoingBpm,
    targetBpm: incomingBpm,
  );
  final incomingStartRate = playbackRateForTargetBpm(
    baseRate: incomingBaseRate,
    nativeBpm: incomingBpm,
    targetBpm: outgoingBpm,
  );
  final incomingEndRate = playbackRateForTargetBpm(
    baseRate: incomingBaseRate,
    nativeBpm: incomingBpm,
    targetBpm: incomingBpm,
  );

  return TempoTransitionRatePlan(
    outgoingSegment: PlaybackRateSegment(
      startMs: overlapStartMs,
      endMs: overlapEndMs,
      startRate: outgoingStartRate,
      endRate: outgoingEndRate,
    ),
    incomingSegment: PlaybackRateSegment(
      startMs: overlapStartMs,
      endMs: overlapEndMs,
      startRate: incomingStartRate,
      endRate: incomingEndRate,
    ),
  );
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
  return (baseRate * targetBpm / nativeBpm)
      .clamp(minTempoAutomationRate, maxTempoAutomationRate)
      .toDouble();
}

double pitchFactorForRate({required double rate, required String pitchMode}) {
  final safeRate =
      rate.clamp(minTempoAutomationRate, maxTempoAutomationRate).toDouble();
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
      return safeRate;
    case 'preserve':
    case 'preservepitch':
    case 'keylock':
    case 'keepkey':
    default:
      return 1;
  }
}

int? snapIncomingStartToNearestDownbeat({
  required int requestedStartMs,
  required int incomingSourceStartMs,
  required ClipTempoMetadata incomingTempo,
  required int outgoingTimelineStartMs,
  required int outgoingSourceStartMs,
  required ClipTempoMetadata outgoingTempo,
  int toleranceMs = 900,
}) {
  if (!incomingTempo.hasDownbeats || !outgoingTempo.hasDownbeats) return null;

  final incomingAnchor = incomingTempo.downbeatsMs.firstWhere(
    (ms) => ms >= incomingSourceStartMs,
    orElse: () => incomingTempo.downbeatsMs.first,
  );
  final outgoingGlobals = outgoingTempo.downbeatsMs
      .map((ms) => outgoingTimelineStartMs + (ms - outgoingSourceStartMs))
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

  final snapped = nearest - (incomingAnchor - incomingSourceStartMs);
  return math.max(0, snapped);
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

  final outgoingBpm = outgoingTempo.nativeBpm;
  if (outgoingBpm == null || outgoingBpm <= 0 || phraseBeats <= 0) return 0;

  final beatMs = 60000 / outgoingBpm;
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

int downbeatSnapToleranceMs(ClipTempoMetadata tempo) {
  final bpm = tempo.nativeBpm;
  if (bpm == null || bpm <= 0) return 900;
  return math.max(900, (60000 / bpm).round());
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
  int? fallbackStartMs,
}) {
  final fallback = math.max(0, fallbackStartMs ?? outgoingTimelineEndMs);
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
    toleranceMs: downbeatSnapToleranceMs(outgoingTempo),
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

double? _readAnalysisValue(Object? value) {
  final map = _readMap(value);
  if (map != null) return _readDouble(map['value']);
  return _readDouble(value);
}

String? _readAnalysisText(Object? value) {
  final map = _readMap(value);
  if (map != null) return _readString(map['value']);
  return _readString(value);
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

List<int>? _readNullableIntList(Object? value) {
  if (value == null) return null;
  return _readIntList(value);
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
