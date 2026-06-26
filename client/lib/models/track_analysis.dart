enum TrackAnalysisStatus {
  pending,
  analyzing,
  analyzed,
  failed,
  unsupported,
  unknown,
}

class TrackAnalysis {
  final TrackAnalysisStatus status;
  final TrackAnalysisSummary? summary;

  const TrackAnalysis({required this.status, this.summary});

  factory TrackAnalysis.fromJson({Object? status, Object? summary}) {
    final parsedStatus = parseTrackAnalysisStatus(status);
    final parsedSummary = TrackAnalysisSummary.fromJson(summary);
    return TrackAnalysis(status: parsedStatus, summary: parsedSummary);
  }

  bool get isNonSuccess =>
      status == TrackAnalysisStatus.pending ||
      status == TrackAnalysisStatus.analyzing ||
      status == TrackAnalysisStatus.failed ||
      status == TrackAnalysisStatus.unsupported;

  bool get hasDisplayableSummary => summary?.displayLabels.isNotEmpty ?? false;

  Map<String, dynamic> toJson() {
    return {
      'status': status.name,
      if (summary != null) 'summary': summary!.toJson(),
    };
  }
}

TrackAnalysisStatus parseTrackAnalysisStatus(Object? value) {
  final status = value
      ?.toString()
      .trim()
      .toLowerCase()
      .replaceAll('-', '_')
      .replaceAll(' ', '_');
  switch (status) {
    case 'pending':
    case 'queued':
      return TrackAnalysisStatus.pending;
    case 'analyzing':
    case 'analysing':
    case 'in_progress':
      return TrackAnalysisStatus.analyzing;
    case 'analyzed':
    case 'analysed':
    case 'complete':
    case 'completed':
    case 'ready':
      return TrackAnalysisStatus.analyzed;
    case 'failed':
    case 'error':
      return TrackAnalysisStatus.failed;
    case 'unsupported':
    case 'not_supported':
      return TrackAnalysisStatus.unsupported;
    default:
      return TrackAnalysisStatus.unknown;
  }
}

class TrackAnalysisSummary {
  final AnalysisValue? bpm;
  final AnalysisValue? key;
  final AnalysisValue? camelot;
  final AnalysisValue? energy;
  final WaveformSummary? waveform;
  final AnalysisRange? intro;
  final AnalysisRange? outro;
  final List<AnalysisRange> sections;
  final List<CueCandidate> cueCandidates;

  const TrackAnalysisSummary({
    this.bpm,
    this.key,
    this.camelot,
    this.energy,
    this.waveform,
    this.intro,
    this.outro,
    this.sections = const [],
    this.cueCandidates = const [],
  });

  factory TrackAnalysisSummary.fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null || map.isEmpty) return const TrackAnalysisSummary();
    return TrackAnalysisSummary(
      bpm: AnalysisValue.fromJson(map['bpm']),
      key: AnalysisValue.fromJson(map['key']),
      camelot: AnalysisValue.fromJson(map['camelot']),
      energy: AnalysisValue.fromJson(map['energy']),
      waveform: WaveformSummary.fromJson(map['waveform']),
      intro: AnalysisRange.fromJson(map['intro']),
      outro: AnalysisRange.fromJson(map['outro']),
      sections: _readList(map['sections'])
          .map(AnalysisRange.fromJson)
          .whereType<AnalysisRange>()
          .toList(growable: false),
      cueCandidates: _readList(map['cue_candidates'] ?? map['cueCandidates'])
          .map(CueCandidate.fromJson)
          .whereType<CueCandidate>()
          .toList(growable: false),
    );
  }

  List<String> get displayLabels {
    final labels = <String>[];
    final bpmValue = bpm?.numericValue;
    if (bpmValue != null) {
      labels.add('${bpmValue.round()} BPM');
    }

    final keyValue = key?.textValue;
    final camelotValue = camelot?.textValue;
    if (keyValue != null && camelotValue != null) {
      labels.add('$keyValue · $camelotValue');
    } else if (keyValue != null) {
      labels.add(keyValue);
    } else if (camelotValue != null) {
      labels.add(camelotValue);
    }

    final energyValue = energy?.numericValue;
    if (energyValue != null) {
      labels.add('Energy ${(energyValue.clamp(0, 1) * 100).round()}%');
    }

    final sampleCount = waveform?.sampleCount;
    if (sampleCount != null && sampleCount > 0) {
      labels.add('Waveform $sampleCount samples');
    }

    if (intro?.hasRange ?? false) {
      labels.add('Intro ${intro!.formattedRange}');
    }
    if (outro?.hasRange ?? false) {
      labels.add('Outro ${outro!.formattedRange}');
    }

    if (sections.isNotEmpty) {
      labels.add('${sections.length} sections');
    }

    for (final cue in cueCandidates.take(2)) {
      labels.add(cue.displayLabel);
    }
    return labels;
  }

  Map<String, dynamic> toJson() {
    return {
      if (bpm != null) 'bpm': bpm!.toJson(),
      if (key != null) 'key': key!.toJson(),
      if (camelot != null) 'camelot': camelot!.toJson(),
      if (energy != null) 'energy': energy!.toJson(),
      if (waveform != null) 'waveform': waveform!.toJson(),
      if (intro != null) 'intro': intro!.toJson(),
      if (outro != null) 'outro': outro!.toJson(),
      if (sections.isNotEmpty)
        'sections': sections.map((section) => section.toJson()).toList(),
      if (cueCandidates.isNotEmpty)
        'cue_candidates': cueCandidates.map((cue) => cue.toJson()).toList(),
    };
  }
}

class AnalysisValue {
  final Object value;
  final double? confidence;
  final String? provenance;

  const AnalysisValue({required this.value, this.confidence, this.provenance});

  static AnalysisValue? fromJson(Object? json) {
    final map = _readMap(json);
    if (map != null) {
      final value = map['value'];
      if (value == null) return null;
      return AnalysisValue(
        value: value,
        confidence: _readDouble(map['confidence']),
        provenance: _readString(map['provenance']),
      );
    }
    if (json == null) return null;
    return AnalysisValue(value: json);
  }

  num? get numericValue {
    final raw = value;
    if (raw is num) return raw;
    return num.tryParse(raw.toString());
  }

  String? get textValue {
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  Map<String, dynamic> toJson() {
    return {
      'value': value,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class WaveformSummary {
  final int? sampleCount;
  final double? confidence;
  final String? provenance;

  const WaveformSummary({this.sampleCount, this.confidence, this.provenance});

  static WaveformSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return WaveformSummary(
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sampleCount != null) 'sample_count': sampleCount,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class AnalysisRange {
  final String? label;
  final int? startMs;
  final int? endMs;
  final double? confidence;
  final String? provenance;

  const AnalysisRange({
    this.label,
    this.startMs,
    this.endMs,
    this.confidence,
    this.provenance,
  });

  static AnalysisRange? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return AnalysisRange(
      label: _readString(map['label']),
      startMs: _readInt(map['start_ms'] ?? map['startMs']),
      endMs: _readInt(map['end_ms'] ?? map['endMs']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  bool get hasRange => startMs != null && endMs != null;

  String get formattedRange =>
      '${_formatMs(startMs ?? 0)}-${_formatMs(endMs ?? 0)}';

  Map<String, dynamic> toJson() {
    return {
      if (label != null) 'label': label,
      if (startMs != null) 'start_ms': startMs,
      if (endMs != null) 'end_ms': endMs,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class CueCandidate {
  final String? kind;
  final int? startMs;
  final double? confidence;
  final String? provenance;

  const CueCandidate({
    this.kind,
    this.startMs,
    this.confidence,
    this.provenance,
  });

  static CueCandidate? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return CueCandidate(
      kind: _readString(map['kind']),
      startMs: _readInt(map['start_ms'] ?? map['startMs']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  String get displayLabel {
    final kindLabel = switch (kind) {
      'mix_in' => 'Cue in',
      'mix_out' => 'Cue out',
      final value when value != null && value.isNotEmpty => value,
      _ => 'Cue',
    };
    final at = startMs == null ? '' : ' ${_formatMs(startMs!)}';
    return '$kindLabel$at';
  }

  Map<String, dynamic> toJson() {
    return {
      if (kind != null) 'kind': kind,
      if (startMs != null) 'start_ms': startMs,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

Map<String, dynamic>? _readMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<Object?> _readList(Object? value) {
  if (value is List) return value.cast<Object?>();
  return const [];
}

String? _readString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}

double? _readDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

String _formatMs(int ms) {
  final totalSeconds = (ms / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
