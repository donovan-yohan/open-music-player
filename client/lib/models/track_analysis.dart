enum TrackAnalysisStatus {
  pending,
  analyzing,
  analyzed,
  failed,
  stale,
  unsupported,
  unknown,
}

class TrackAnalysis {
  final TrackAnalysisStatus status;
  final TrackAnalysisSummary? summary;

  const TrackAnalysis({required this.status, this.summary});

  factory TrackAnalysis.fromJson({Object? status, Object? summary}) {
    final parsedStatus = parseTrackAnalysisStatus(status);
    final parsedSummary =
        summary == null ? null : TrackAnalysisSummary.fromJson(summary);
    return TrackAnalysis(status: parsedStatus, summary: parsedSummary);
  }

  bool get isNonSuccess =>
      status == TrackAnalysisStatus.pending ||
      status == TrackAnalysisStatus.analyzing ||
      status == TrackAnalysisStatus.failed ||
      status == TrackAnalysisStatus.stale ||
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
    case 'stale':
    case 'outdated':
    case 'superseded':
      return TrackAnalysisStatus.stale;
    case 'unsupported':
    case 'not_supported':
      return TrackAnalysisStatus.unsupported;
    default:
      return TrackAnalysisStatus.unknown;
  }
}

class TrackAnalysisSummary {
  final AnalysisValue? bpm;
  final BeatGridSummary? beatGrid;
  final DownbeatSummary? downbeats;
  final AnalysisValue? key;
  final AnalysisValue? camelot;
  final AnalysisValue? energy;
  final LoudnessSummary? loudness;
  final TruePeakSummary? truePeak;
  final WaveformSummary? waveform;
  final AnalysisRange? intro;
  final AnalysisRange? outro;
  final List<AnalysisRange> sections;
  final List<CueCandidate> cueCandidates;

  const TrackAnalysisSummary({
    this.bpm,
    this.beatGrid,
    this.downbeats,
    this.key,
    this.camelot,
    this.energy,
    this.loudness,
    this.truePeak,
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
      beatGrid: BeatGridSummary.fromJson(map['beat_grid'] ?? map['beatGrid']),
      downbeats: DownbeatSummary.fromJson(map['downbeats']),
      key: AnalysisValue.fromJson(map['key']),
      camelot: AnalysisValue.fromJson(map['camelot']),
      energy: AnalysisValue.fromJson(map['energy']),
      loudness: LoudnessSummary.fromJson(map['loudness']),
      truePeak: TruePeakSummary.fromJson(map['true_peak'] ?? map['truePeak']),
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

    final beatCount = beatGrid?.beatsMs.length ?? 0;
    if (beatCount > 0) {
      labels.add(_pluralizedCount(beatCount, 'beat'));
    }

    final downbeatCount = downbeats?.positionsMs.length ?? 0;
    if (downbeatCount > 0) {
      labels.add(_pluralizedCount(downbeatCount, 'downbeat'));
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

    final integratedLufs = loudness?.integratedLufs;
    if (integratedLufs != null) {
      labels.add('Loudness ${integratedLufs.toStringAsFixed(1)} LUFS');
    }

    final truePeakDbtp = truePeak?.dbtp;
    if (truePeakDbtp != null) {
      labels.add('Peak ${truePeakDbtp.toStringAsFixed(1)} dBTP');
    }

    final sampleCount = waveform?.sampleCount;
    if (sampleCount != null && sampleCount > 0) {
      labels.add('Waveform $sampleCount samples');
    }

    final resolutionCount = waveform?.resolutions.length ?? 0;
    if (resolutionCount > 0) {
      labels.add(_pluralizedCount(resolutionCount, 'waveform layer'));
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
      if (beatGrid != null) 'beat_grid': beatGrid!.toJson(),
      if (downbeats != null) 'downbeats': downbeats!.toJson(),
      if (key != null) 'key': key!.toJson(),
      if (camelot != null) 'camelot': camelot!.toJson(),
      if (energy != null) 'energy': energy!.toJson(),
      if (loudness != null) 'loudness': loudness!.toJson(),
      if (truePeak != null) 'true_peak': truePeak!.toJson(),
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

class BeatGridSummary {
  final double? bpm;
  final int? offsetMs;
  final List<int> beatsMs;
  final double? confidence;
  final String? provenance;

  const BeatGridSummary({
    this.bpm,
    this.offsetMs,
    this.beatsMs = const [],
    this.confidence,
    this.provenance,
  });

  static BeatGridSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return BeatGridSummary(
      bpm: _readDouble(map['bpm']),
      offsetMs: _readInt(map['offset_ms'] ?? map['offsetMs']),
      beatsMs: _readIntList(map['beats_ms'] ?? map['beatsMs']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (bpm != null) 'bpm': bpm,
      if (offsetMs != null) 'offset_ms': offsetMs,
      if (beatsMs.isNotEmpty) 'beats_ms': beatsMs,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class DownbeatSummary {
  final List<int> positionsMs;
  final double? confidence;
  final String? provenance;

  const DownbeatSummary({
    this.positionsMs = const [],
    this.confidence,
    this.provenance,
  });

  static DownbeatSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return DownbeatSummary(
      positionsMs: _readIntList(map['positions_ms'] ?? map['positionsMs']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (positionsMs.isNotEmpty) 'positions_ms': positionsMs,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class LoudnessSummary {
  final double? integratedLufs;
  final double? shortTermLufs;
  final double? loudnessRangeLu;
  final double? confidence;
  final String? provenance;

  const LoudnessSummary({
    this.integratedLufs,
    this.shortTermLufs,
    this.loudnessRangeLu,
    this.confidence,
    this.provenance,
  });

  static LoudnessSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return LoudnessSummary(
      integratedLufs:
          _readDouble(map['integrated_lufs'] ?? map['integratedLufs']),
      shortTermLufs:
          _readDouble(map['short_term_lufs'] ?? map['shortTermLufs']),
      loudnessRangeLu:
          _readDouble(map['loudness_range_lu'] ?? map['loudnessRangeLu']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (integratedLufs != null) 'integrated_lufs': integratedLufs,
      if (shortTermLufs != null) 'short_term_lufs': shortTermLufs,
      if (loudnessRangeLu != null) 'loudness_range_lu': loudnessRangeLu,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class TruePeakSummary {
  final double? dbtp;
  final double? confidence;
  final String? provenance;

  const TruePeakSummary({this.dbtp, this.confidence, this.provenance});

  static TruePeakSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return TruePeakSummary(
      dbtp: _readDouble(map['dbtp'] ?? map['db_tp']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (dbtp != null) 'dbtp': dbtp,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class WaveformSummary {
  final int? sampleCount;
  final List<WaveformResolutionSummary> resolutions;
  final Map<String, SpectralBandSummary> spectralBands;
  final double? confidence;
  final String? provenance;

  const WaveformSummary({
    this.sampleCount,
    this.resolutions = const [],
    this.spectralBands = const {},
    this.confidence,
    this.provenance,
  });

  static WaveformSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return WaveformSummary(
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      resolutions: _readList(map['resolutions'])
          .map(WaveformResolutionSummary.fromJson)
          .whereType<WaveformResolutionSummary>()
          .toList(growable: false),
      spectralBands:
          _readSpectralBands(map['spectral_bands'] ?? map['spectralBands']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sampleCount != null) 'sample_count': sampleCount,
      if (resolutions.isNotEmpty)
        'resolutions': resolutions.map((layer) => layer.toJson()).toList(),
      if (spectralBands.isNotEmpty)
        'spectral_bands':
            spectralBands.map((key, value) => MapEntry(key, value.toJson())),
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class WaveformResolutionSummary {
  final String? name;
  final int? samplesPerPixel;
  final int? sampleCount;
  final String? artifactRef;

  const WaveformResolutionSummary({
    this.name,
    this.samplesPerPixel,
    this.sampleCount,
    this.artifactRef,
  });

  static WaveformResolutionSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return WaveformResolutionSummary(
      name: _readString(map['name']),
      samplesPerPixel:
          _readInt(map['samples_per_pixel'] ?? map['samplesPerPixel']),
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      artifactRef: _readString(map['artifact_ref'] ?? map['artifactRef']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      if (samplesPerPixel != null) 'samples_per_pixel': samplesPerPixel,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (artifactRef != null) 'artifact_ref': artifactRef,
    };
  }
}

class SpectralBandSummary {
  final int? sampleCount;
  final String? artifactRef;

  const SpectralBandSummary({this.sampleCount, this.artifactRef});

  static SpectralBandSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return SpectralBandSummary(
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      artifactRef: _readString(map['artifact_ref'] ?? map['artifactRef']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sampleCount != null) 'sample_count': sampleCount,
      if (artifactRef != null) 'artifact_ref': artifactRef,
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

List<int> _readIntList(Object? value) {
  return _readList(value)
      .map(_readInt)
      .whereType<int>()
      .toList(growable: false);
}

Map<String, SpectralBandSummary> _readSpectralBands(Object? value) {
  final map = _readMap(value);
  if (map == null) return const {};
  final bands = <String, SpectralBandSummary>{};
  for (final entry in map.entries) {
    final band = SpectralBandSummary.fromJson(entry.value);
    if (band != null) {
      bands[entry.key] = band;
    }
  }
  return bands;
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
  final clampedMs = ms < 0 ? 0 : ms;
  final totalSeconds = (clampedMs / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _pluralizedCount(int count, String singular) {
  return '$count ${count == 1 ? singular : '${singular}s'}';
}
