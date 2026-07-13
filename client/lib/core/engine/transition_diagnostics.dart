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
  lowDownbeatConfidence,
  noUsableDownbeatMarker,
  downbeatOffset,
  tempoOutOfRange,
  tempoMatched,
  tempoShift,
  largeTempoShift,
  pitchLockRequired,
  pitchFollowsTempo,
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

  /// Lets callers without snap-mode context classify beat-lock advice later.
  bool get isDownbeatLockAdvisory =>
      code == TransitionDiagnosticCode.missingDownbeats ||
      code == TransitionDiagnosticCode.lowDownbeatConfidence ||
      code == TransitionDiagnosticCode.noUsableDownbeatMarker ||
      code == TransitionDiagnosticCode.downbeatOffset;
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

TransitionDiagnostics diagnoseTransition(
  MixClip first,
  MixClip second, {
  BeatSnapMode? snapMode,
}) {
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
        snapMode: snapMode,
      ),
      ..._pitchDiagnostics(outgoing, incoming),
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
        label: _missingLabel('BPM', missing),
        detail:
            'Missing ${_missingSideText(missing)} BPM; transition uses native speed.',
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

  final bpmPair = resolveTempoTransitionBpmPair(
    outgoingTempo: outgoing.tempo,
    incomingTempo: incoming.tempo,
    outgoingBaseRate: outgoing.rateAutomation.baseRate,
    incomingBaseRate: incoming.rateAutomation.baseRate,
  );
  if (bpmPair == null) {
    return [
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.tempoOutOfRange,
        label: 'Tempo range',
        detail:
            'BPM pull from ${_bpm(outgoing.tempo)} to ${_bpm(incoming.tempo)} exceeds the safe ${minTempoAutomationRate}x-${maxTempoAutomationRate}x sync range.',
      ),
    ];
  }

  final transitionStartBpm = effectiveBpmForRate(
    nativeBpm: bpmPair.outgoingBpm,
    rate: outgoing.rateAutomation.baseRate,
  );
  final transitionEndBpm = effectiveBpmForRate(
    nativeBpm: bpmPair.incomingBpm,
    rate: incoming.rateAutomation.baseRate,
  );
  final outgoingEndRate = _rateForTargetBpm(
    outgoing,
    transitionEndBpm,
    tempoScale: bpmPair.outgoingTempoScale,
  );
  final incomingStartRate = _rateForTargetBpm(
    incoming,
    transitionStartBpm,
    tempoScale: bpmPair.incomingTempoScale,
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

List<TransitionDiagnostic> _pitchDiagnostics(
  MixClip outgoing,
  MixClip incoming,
) {
  final bpmPair = resolveTempoTransitionBpmPair(
    outgoingTempo: outgoing.tempo,
    incomingTempo: incoming.tempo,
    outgoingBaseRate: outgoing.rateAutomation.baseRate,
    incomingBaseRate: incoming.rateAutomation.baseRate,
  );
  if (!_hasBpm(outgoing.tempo) ||
      !_hasBpm(incoming.tempo) ||
      !_hasReliableConfidence(outgoing.tempo) ||
      !_hasReliableConfidence(incoming.tempo) ||
      bpmPair == null) {
    return const [];
  }

  final transitionStartBpm = effectiveBpmForRate(
    nativeBpm: bpmPair.outgoingBpm,
    rate: outgoing.rateAutomation.baseRate,
  );
  final transitionEndBpm = effectiveBpmForRate(
    nativeBpm: bpmPair.incomingBpm,
    rate: incoming.rateAutomation.baseRate,
  );
  final outgoingRate = _rateForTargetBpm(
    outgoing,
    transitionEndBpm,
    tempoScale: bpmPair.outgoingTempoScale,
  );
  final incomingRate = _rateForTargetBpm(
    incoming,
    transitionStartBpm,
    tempoScale: bpmPair.incomingTempoScale,
  );
  final shifted = <String>[];
  final locked = <String>[];

  void classify(MixClip clip, String side, double transitionRate) {
    if ((transitionRate - clip.rateAutomation.baseRate).abs() < 0.005) {
      return;
    }
    final pitchFactor = pitchFactorForRate(
      rate: transitionRate,
      pitchMode: clip.rateAutomation.pitchMode,
    );
    if ((pitchFactor - 1).abs() < 0.005) {
      locked.add(side);
    } else {
      shifted.add(side);
    }
  }

  classify(outgoing, 'outgoing', outgoingRate);
  classify(incoming, 'incoming', incomingRate);

  return [
    if (shifted.isNotEmpty)
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.warning,
        code: TransitionDiagnosticCode.pitchFollowsTempo,
        label: 'Pitch shift',
        detail:
            'Tempo matching changes ${_missingSideText(shifted)} playback speed and pitch will follow tempo.',
      ),
    if (locked.isNotEmpty)
      TransitionDiagnostic(
        severity: TransitionDiagnosticSeverity.info,
        code: TransitionDiagnosticCode.pitchLockRequired,
        label: 'Pitch lock',
        detail:
            'Tempo matching changes ${_missingSideText(locked)} playback speed; key lock must stay available to avoid pitch shift.',
      ),
  ];
}

List<TransitionDiagnostic> _downbeatDiagnostics({
  required MixClip outgoing,
  required MixClip incoming,
  required int overlapStartMs,
  required int overlapEndMs,
  required BeatSnapMode? snapMode,
}) {
  final diagnostics = <TransitionDiagnostic>[];
  final missing = <String>[];
  if (!outgoing.tempo.hasDownbeatMarkers) missing.add('outgoing');
  if (!incoming.tempo.hasDownbeatMarkers) missing.add('incoming');
  if (missing.isNotEmpty) {
    diagnostics.add(
      TransitionDiagnostic(
        severity: _downbeatAdvisorySeverity(snapMode),
        code: TransitionDiagnosticCode.missingDownbeats,
        label: _missingLabel('downbeat', missing),
        detail:
            'Missing ${_missingSideText(missing)} downbeat markers; transition cannot be verified as phrase-locked.',
      ),
    );
  }

  final lowConfidence = <String>[];
  if (outgoing.tempo.hasDownbeatMarkers &&
      !outgoing.tempo.hasReliableDownbeats) {
    lowConfidence.add('outgoing');
  }
  if (incoming.tempo.hasDownbeatMarkers &&
      !incoming.tempo.hasReliableDownbeats) {
    lowConfidence.add('incoming');
  }
  for (final side in lowConfidence) {
    final confidence = side == 'outgoing'
        ? outgoing.tempo.downbeatConfidence
        : incoming.tempo.downbeatConfidence;
    diagnostics.add(
      TransitionDiagnostic(
        severity: _downbeatAdvisorySeverity(snapMode),
        code: TransitionDiagnosticCode.lowDownbeatConfidence,
        label:
            '${_diagnosticSideLabel(side)} downbeat confidence ${_confidencePercent(confidence)}',
        detail:
            '${_diagnosticSideLabel(side)} downbeat markers are present, but their ${_confidencePercent(confidence)} confidence is below the ${_percent(reliableDownbeatConfidenceFloor)} auto-lock threshold.',
      ),
    );
  }
  if (diagnostics.isNotEmpty) {
    return diagnostics;
  }

  final outgoingDownbeats = _globalDownbeatsFor(outgoing);
  final incomingDownbeats = _globalDownbeatsFor(incoming);
  final match = _nearestDownbeatMatch(
    outgoingDownbeats: outgoingDownbeats,
    incomingDownbeats: incomingDownbeats,
    overlapStartMs: overlapStartMs,
    overlapEndMs: overlapEndMs,
  );
  if (match == null) {
    return [
      TransitionDiagnostic(
        severity: _downbeatAdvisorySeverity(snapMode),
        code: TransitionDiagnosticCode.noUsableDownbeatMarker,
        label: 'No usable downbeat',
        detail:
            'Trustworthy markers do not produce a transformed downbeat in the current overlap window.',
      ),
    ];
  }

  final delta = match.delta;
  final absDelta = delta.abs();
  if (match.bothInsideOverlap && absDelta <= beatLockToleranceMs) {
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
      severity: _downbeatAdvisorySeverity(snapMode),
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
  final outgoingKey = _CamelotKey.fromTempo(outgoing.tempo);
  final incomingKey = _CamelotKey.fromTempo(incoming.tempo);
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

double _rateForTargetBpm(
  MixClip clip,
  double targetBpm, {
  double tempoScale = 1,
}) {
  final nativeBpm = clip.tempo.nativeBpm;
  if (nativeBpm == null || nativeBpm <= 0) {
    return clip.rateAutomation.baseRate;
  }
  return rawPlaybackRateForTargetBpm(
    baseRate: clip.rateAutomation.baseRate,
    nativeBpm: nativeBpm * tempoScale,
    targetBpm: targetBpm,
  ).clamp(minTempoAutomationRate, maxTempoAutomationRate).toDouble();
}

double _relativeRateShift(double baseRate, double transitionRate) {
  if (baseRate <= 0) return (transitionRate - 1).abs();
  return ((transitionRate - baseRate) / baseRate).abs();
}

List<int> _globalDownbeatsFor(MixClip clip) {
  final globals = <int>{};
  for (final sourceMs in clip.tempo.downbeatsMs) {
    if (sourceMs < clip.placement.sourceStartMs ||
        sourceMs > clip.placement.sourceEndMs) {
      continue;
    }
    final timelineMs = clip.timelineMsForSourcePosition(sourceMs);
    if (timelineMs >= 0) globals.add(timelineMs);
  }
  final sorted = globals.toList(growable: false)..sort();
  return sorted;
}

class _DownbeatMatch {
  final int delta;
  final bool bothInsideOverlap;

  const _DownbeatMatch({
    required this.delta,
    required this.bothInsideOverlap,
  });
}

_DownbeatMatch? _nearestDownbeatMatch({
  required List<int> outgoingDownbeats,
  required List<int> incomingDownbeats,
  required int overlapStartMs,
  required int overlapEndMs,
}) {
  if (outgoingDownbeats.isEmpty || incomingDownbeats.isEmpty) return null;

  final outgoingInside = outgoingDownbeats
      .where((ms) => ms >= overlapStartMs && ms < overlapEndMs)
      .toList(growable: false);
  final incomingInside = incomingDownbeats
      .where((ms) => ms >= overlapStartMs && ms < overlapEndMs)
      .toList(growable: false);
  final insideMatch = _nearestDownbeatPair(
    outgoingDownbeats: outgoingInside,
    incomingDownbeats: incomingInside,
    bothInsideOverlap: true,
  );
  if (insideMatch != null) return insideMatch;

  final windowStart = overlapStartMs - downbeatWarningToleranceMs;
  final windowEnd = overlapEndMs + downbeatWarningToleranceMs;
  final outgoing = outgoingDownbeats
      .where((ms) => ms >= windowStart && ms <= windowEnd)
      .toList(growable: false);
  final incoming = incomingDownbeats
      .where((ms) => ms >= windowStart && ms <= windowEnd)
      .toList(growable: false);

  return _nearestDownbeatPair(
    outgoingDownbeats: outgoing,
    incomingDownbeats: incoming,
    bothInsideOverlap: false,
  );
}

_DownbeatMatch? _nearestDownbeatPair({
  required List<int> outgoingDownbeats,
  required List<int> incomingDownbeats,
  required bool bothInsideOverlap,
}) {
  if (outgoingDownbeats.isEmpty || incomingDownbeats.isEmpty) return null;

  int? bestDelta;
  int? bestDistance;
  for (final incomingMs in incomingDownbeats) {
    for (final outgoingMs in outgoingDownbeats) {
      final delta = incomingMs - outgoingMs;
      final distance = delta.abs();
      if (bestDistance == null || distance < bestDistance) {
        bestDelta = delta;
        bestDistance = distance;
      }
    }
  }
  return bestDelta == null
      ? null
      : _DownbeatMatch(
          delta: bestDelta,
          bothInsideOverlap: bothInsideOverlap,
        );
}

String _percent(double value) => '${(value * 100).round()}%';

String _confidencePercent(double? value) {
  if (value == null || !value.isFinite) return 'unknown';
  return _percent(value.clamp(0.0, 1.0).toDouble());
}

TransitionDiagnosticSeverity _downbeatAdvisorySeverity(
        BeatSnapMode? snapMode) =>
    snapMode == BeatSnapMode.free
        ? TransitionDiagnosticSeverity.info
        : TransitionDiagnosticSeverity.warning;

String _missingLabel(String subject, List<String> missing) {
  if (missing.length == 1) return 'No ${_sideLabel(missing.single)} $subject';
  return 'No current/next $subject';
}

String _missingSideText(List<String> missing) {
  if (missing.length == 1) return _sideLabel(missing.single);
  return missing.map(_sideLabel).join(' and ');
}

String _sideLabel(String side) {
  switch (side) {
    case 'outgoing':
      return 'current';
    case 'incoming':
      return 'next';
    default:
      return side;
  }
}

String _diagnosticSideLabel(String side) {
  switch (side) {
    case 'outgoing':
      return 'Outgoing';
    case 'incoming':
      return 'Incoming';
    default:
      return side;
  }
}

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

  static _CamelotKey? fromTempo(ClipTempoMetadata tempo) {
    return parse(tempo.camelot) ?? fromMusicalKey(tempo.musicalKey);
  }

  static _CamelotKey? parse(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^\s*(1[0-2]|[1-9])\s*([abAB])\s*$').firstMatch(raw);
    if (match == null) return null;
    return _CamelotKey(
        int.parse(match.group(1)!), match.group(2)!.toUpperCase());
  }

  static _CamelotKey? fromMusicalKey(String? raw) {
    final parsed = _MusicalKey.parse(raw);
    if (parsed == null) return null;
    final labels = parsed.mode == _MusicalMode.minor
        ? _minorCamelotByPitchClass
        : _majorCamelotByPitchClass;
    return parse(labels[parsed.pitchClass]);
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

  static const _majorCamelotByPitchClass = [
    '8B',
    '3B',
    '10B',
    '5B',
    '12B',
    '7B',
    '2B',
    '9B',
    '4B',
    '11B',
    '6B',
    '1B',
  ];

  static const _minorCamelotByPitchClass = [
    '5A',
    '12A',
    '7A',
    '2A',
    '9A',
    '4A',
    '11A',
    '6A',
    '1A',
    '8A',
    '3A',
    '10A',
  ];
}

enum _MusicalMode { major, minor }

class _MusicalKey {
  final int pitchClass;
  final _MusicalMode mode;

  const _MusicalKey(this.pitchClass, this.mode);

  static _MusicalKey? parse(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final match = RegExp(
      r'^([A-Ga-g])\s*([#b]?)\s*(major|maj|min|minor|m)?$',
    ).firstMatch(text);
    if (match == null) return null;

    final pitchClass = _pitchClass(
      match.group(1)!,
      accidental: match.group(2),
    );
    if (pitchClass == null) return null;

    final rawMode = match.group(3)?.toLowerCase();
    final mode = switch (rawMode) {
      'minor' || 'min' || 'm' => _MusicalMode.minor,
      'major' || 'maj' || null => _MusicalMode.major,
      _ => null,
    };
    if (mode == null) return null;
    return _MusicalKey(pitchClass, mode);
  }

  static int? _pitchClass(String note, {String? accidental}) {
    final base = switch (note.toUpperCase()) {
      'C' => 0,
      'D' => 2,
      'E' => 4,
      'F' => 5,
      'G' => 7,
      'A' => 9,
      'B' => 11,
      _ => null,
    };
    if (base == null) return null;
    final delta = switch (accidental) {
      '#' => 1,
      'b' => -1,
      _ => 0,
    };
    return (base + delta) % 12;
  }
}
