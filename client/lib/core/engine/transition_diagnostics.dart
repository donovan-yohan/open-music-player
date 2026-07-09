import 'dart:math' as math;

import 'tempo_automation.dart';
import 'timeline_model.dart';

const int beatLockToleranceMs = 80;
const int downbeatWarningToleranceMs = 250;
const double tempoShiftNoticeFloor = 0.08;
const double tempoShiftWarningFloor = 0.16;

enum TransitionDiagnosticSeverity { info, warning, error }

enum TransitionDiagnosticCode {
  noOverlap,
  beatLocked,
  missingBpm,
  lowBpmConfidence,
  missingDownbeats,
  downbeatOffset,
  tempoMatched,
  tempoShift,
  largeTempoShift,
  harmonicCompatible,
  harmonicClash,
}

class TransitionDiagnostic {
  final TransitionDiagnosticSeverity severity;
  final TransitionDiagnosticCode code;
  final String label;
  final String detail;

  const TransitionDiagnostic({
    required this.severity,
    required this.code,
    required this.label,
    required this.detail,
  });
}

class TransitionDiagnostics {
  final MixClip outgoing;
  final MixClip incoming;
  final int overlapStartMs;
  final int overlapEndMs;
  final List<TransitionDiagnostic> diagnostics;

  const TransitionDiagnostics({
    required this.outgoing,
    required this.incoming,
    required this.overlapStartMs,
    required this.overlapEndMs,
    required this.diagnostics,
  });

  int get overlapDurationMs => math.max(0, overlapEndMs - overlapStartMs);

  bool get hasWarnings => diagnostics.any(
        (diagnostic) =>
            diagnostic.severity == TransitionDiagnosticSeverity.warning ||
            diagnostic.severity == TransitionDiagnosticSeverity.error,
      );

  TransitionDiagnosticSeverity get severity {
    if (diagnostics.any(
      (diagnostic) => diagnostic.severity == TransitionDiagnosticSeverity.error,
    )) {
      return TransitionDiagnosticSeverity.error;
    }
    if (diagnostics.any(
      (diagnostic) =>
          diagnostic.severity == TransitionDiagnosticSeverity.warning,
    )) {
      return TransitionDiagnosticSeverity.warning;
    }
    return TransitionDiagnosticSeverity.info;
  }

  List<String> get compactLabels {
    final warnings = diagnostics
        .where((diagnostic) =>
            diagnostic.severity != TransitionDiagnosticSeverity.info)
        .map((diagnostic) => diagnostic.label)
        .toList(growable: false);
    if (warnings.isNotEmpty) return warnings;
    return diagnostics
        .map((diagnostic) => diagnostic.label)
        .toList(growable: false);
  }

  String get semanticsLabel => diagnostics
      .map((diagnostic) => '${diagnostic.label}: ${diagnostic.detail}')
      .join('. ');
}

TransitionDiagnostics diagnoseTransition(MixClip first, MixClip second) {
  final outgoing =
      first.timelineStartMs <= second.timelineStartMs ? first : second;
  final incoming = identical(outgoing, first) ? second : first;
  final overlapStartMs =
      math.max(outgoing.timelineStartMs, incoming.timelineStartMs);
  final overlapEndMs = math.min(outgoing.timelineEndMs, incoming.timelineEndMs);

  if (overlapEndMs <= overlapStartMs) {
    return TransitionDiagnostics(
      outgoing: outgoing,
      incoming: incoming,
      overlapStartMs: overlapStartMs,
      overlapEndMs: overlapEndMs,
      diagnostics: const [
        TransitionDiagnostic(
          severity: TransitionDiagnosticSeverity.info,
          code: TransitionDiagnosticCode.noOverlap,
          label: 'No overlap',
          detail: 'These clips do not currently crossfade.',
        ),
      ],
    );
  }

  return TransitionDiagnostics(
    outgoing: outgoing,
    incoming: incoming,
    overlapStartMs: overlapStartMs,
    overlapEndMs: overlapEndMs,
    diagnostics: [
      ..._tempoDiagnostics(outgoing, incoming),
      ..._downbeatDiagnostics(
        outgoing: outgoing,
        incoming: incoming,
        overlapStartMs: overlapStartMs,
        overlapEndMs: overlapEndMs,
      ),
      ..._harmonicDiagnostics(outgoing, incoming),
    ],
  );
}

List<TransitionDiagnostic> _tempoDiagnostics(
  MixClip outgoing,
  MixClip incoming,
) {
  final missing = <String>[];
  if (!_hasBpm(outgoing.tempo)) missing.add('outgoing');
  if (!_hasBpm(incoming.tempo)) missing.add('incoming');
  if (missing.isNotEmpty) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.missingBpm,
        label: 'No BPM',
        detail:
            'Missing ${missing.join(' and ')} BPM; transition uses native speed.',
      ),
    ];
  }

  final lowConfidence = <String>[];
  if (!_hasReliableConfidence(outgoing.tempo)) lowConfidence.add('outgoing');
  if (!_hasReliableConfidence(incoming.tempo)) lowConfidence.add('incoming');
  if (lowConfidence.isNotEmpty) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.lowBpmConfidence,
        label: 'Low BPM',
        detail:
            'Low ${lowConfidence.join(' and ')} BPM confidence; beat sync may drift.',
      ),
    ];
  }

  final outgoingEndRate =
      _rateForTargetBpm(outgoing, incoming.tempo.nativeBpm!);
  final incomingStartRate = _rateForTargetBpm(
    incoming,
    outgoing.tempo.nativeBpm!,
  );
  final outgoingShift =
      _relativeRateShift(outgoing.playbackRate, outgoingEndRate);
  final incomingShift = _relativeRateShift(
    incoming.playbackRate,
    incomingStartRate,
  );
  final maxShift = math.max(outgoingShift, incomingShift);

  if (maxShift >= tempoShiftWarningFloor) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.largeTempoShift,
        label: 'Tempo ${_percent(maxShift)}',
        detail:
            'Large BPM pull between ${_bpm(outgoing.tempo)} and ${_bpm(incoming.tempo)}.',
      ),
    ];
  }
  if (maxShift >= tempoShiftNoticeFloor) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.info,
        code: TransitionDiagnosticCode.tempoShift,
        label: 'Tempo ${_percent(maxShift)}',
        detail:
            'Moderate BPM pull between ${_bpm(outgoing.tempo)} and ${_bpm(incoming.tempo)}.',
      ),
    ];
  }

  return [
    TransitionDiagnostic(
      severity: TransitionDiagnosticSeverity.info,
      code: TransitionDiagnosticCode.tempoMatched,
      label: 'Tempo match',
      detail:
          'BPMs are close enough for a transparent transition: ${_bpm(outgoing.tempo)} to ${_bpm(incoming.tempo)}.',
    ),
  ];
}

List<TransitionDiagnostic> _downbeatDiagnostics({
  required MixClip outgoing,
  required MixClip incoming,
  required int overlapStartMs,
  required int overlapEndMs,
}) {
  if (!outgoing.tempo.hasDownbeats || !incoming.tempo.hasDownbeats) {
    return const [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.missingDownbeats,
        label: 'No downbeat',
        detail:
            'Missing downbeat markers; transition cannot be verified as phrase-locked.',
      ),
    ];
  }

  final outgoingDownbeats = _globalDownbeatsFor(outgoing);
  final incomingDownbeats = _globalDownbeatsFor(incoming);
  final delta = _nearestDownbeatDelta(
    outgoingDownbeats: outgoingDownbeats,
    incomingDownbeats: incomingDownbeats,
    overlapStartMs: overlapStartMs,
    overlapEndMs: overlapEndMs,
  );
  if (delta == null) {
    return const [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.missingDownbeats,
        label: 'No downbeat',
        detail: 'No downbeat marker lands near the current overlap.',
      ),
    ];
  }

  final absDelta = delta.abs();
  if (absDelta <= beatLockToleranceMs) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.info,
        code: TransitionDiagnosticCode.beatLocked,
        label: 'Beat locked',
        detail: 'Nearest downbeats are ${absDelta}ms apart.',
      ),
    ];
  }

  final direction = delta > 0 ? 'late' : 'early';
  return [
    TransitionDiagnostic(
      severity: TransitionDiagnosticSeverity.warning,
      code: TransitionDiagnosticCode.downbeatOffset,
      label: 'Downbeat ${delta >= 0 ? '+' : ''}${delta}ms',
      detail: 'Incoming downbeat is ${absDelta}ms $direction.',
    ),
  ];
}

List<TransitionDiagnostic> _harmonicDiagnostics(
  MixClip outgoing,
  MixClip incoming,
) {
  final outgoingKey = _CamelotKey.parse(outgoing.tempo.camelot);
  final incomingKey = _CamelotKey.parse(incoming.tempo.camelot);
  if (outgoingKey == null || incomingKey == null) return const [];

  final label = '${outgoingKey.label}->${incomingKey.label}';
  if (outgoingKey.isCompatibleWith(incomingKey)) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.info,
        code: TransitionDiagnosticCode.harmonicCompatible,
        label: 'Harmonic $label',
        detail: 'Camelot keys are compatible.',
      ),
    ];
  }

  return [
    TransitionDiagnostic(
      severity: TransitionDiagnosticSeverity.warning,
      code: TransitionDiagnosticCode.harmonicClash,
      label: 'Key clash $label',
      detail: 'Camelot keys are not adjacent or relative.',
    ),
  ];
}

bool _hasBpm(ClipTempoMetadata tempo) {
  final bpm = tempo.nativeBpm;
  return bpm != null && bpm.isFinite && bpm > 0;
}

bool _hasReliableConfidence(ClipTempoMetadata tempo) {
  final confidence = tempo.bpmConfidence;
  return confidence == null || confidence >= reliableBpmConfidenceFloor;
}

double _rateForTargetBpm(MixClip clip, double targetBpm) {
  final nativeBpm = clip.tempo.nativeBpm;
  if (nativeBpm == null || nativeBpm <= 0) return clip.playbackRate;
  return (clip.playbackRate * targetBpm / nativeBpm)
      .clamp(minTempoAutomationRate, maxTempoAutomationRate)
      .toDouble();
}

double _relativeRateShift(double baseRate, double transitionRate) {
  if (baseRate <= 0) return (transitionRate - 1).abs();
  return ((transitionRate - baseRate) / baseRate).abs();
}

List<int> _globalDownbeatsFor(MixClip clip) => clip.tempo.downbeatsMs
    .map((ms) => clip.timelineStartMs + (ms - clip.placement.sourceStartMs))
    .where((ms) => ms >= 0)
    .toList(growable: false);

int? _nearestDownbeatDelta({
  required List<int> outgoingDownbeats,
  required List<int> incomingDownbeats,
  required int overlapStartMs,
  required int overlapEndMs,
}) {
  if (outgoingDownbeats.isEmpty || incomingDownbeats.isEmpty) return null;
  final windowStart = overlapStartMs - downbeatWarningToleranceMs;
  final windowEnd = overlapEndMs + downbeatWarningToleranceMs;
  final outgoing = outgoingDownbeats
      .where((ms) => ms >= windowStart && ms <= windowEnd)
      .toList(growable: false);
  final incoming = incomingDownbeats
      .where((ms) => ms >= windowStart && ms <= windowEnd)
      .toList(growable: false);
  final outgoingCandidates = outgoing.isEmpty ? outgoingDownbeats : outgoing;
  final incomingCandidates = incoming.isEmpty ? incomingDownbeats : incoming;

  int? bestDelta;
  int? bestDistance;
  for (final incomingMs in incomingCandidates) {
    for (final outgoingMs in outgoingCandidates) {
      final delta = incomingMs - outgoingMs;
      final distance = delta.abs();
      if (bestDistance == null || distance < bestDistance) {
        bestDelta = delta;
        bestDistance = distance;
      }
    }
  }
  return bestDelta;
}

String _percent(double value) => '${(value * 100).round()}%';

String _bpm(ClipTempoMetadata tempo) {
  final bpm = tempo.nativeBpm;
  if (bpm == null) return '? BPM';
  final rounded = bpm.roundToDouble() == bpm
      ? bpm.round().toString()
      : bpm.toStringAsFixed(1);
  return '$rounded BPM';
}

class _CamelotKey {
  final int number;
  final String letter;

  const _CamelotKey(this.number, this.letter);

  String get label => '$number$letter';

  static _CamelotKey? parse(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^\s*(1[0-2]|[1-9])\s*([abAB])\s*$').firstMatch(raw);
    if (match == null) return null;
    return _CamelotKey(
        int.parse(match.group(1)!), match.group(2)!.toUpperCase());
  }

  bool isCompatibleWith(_CamelotKey other) {
    if (number == other.number) return true;
    if (letter != other.letter) return false;
    return _isAdjacent(number, other.number);
  }

  bool _isAdjacent(int a, int b) {
    final distance = (a - b).abs();
    return distance == 1 || distance == 11;
  }
}
