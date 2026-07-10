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
  final TrackAnalysisOverrides? overrides;
  final bool overridesPresent;
  final DateTime? updatedAt;

  const TrackAnalysis({
    required this.status,
    this.summary,
    this.overrides,
    bool? overridesPresent,
    this.updatedAt,
  }) : overridesPresent = overridesPresent ?? overrides != null;

  factory TrackAnalysis.fromJson({
    Object? status,
    Object? summary,
    Object? overrides,
    bool? overridesPresent,
    Object? updatedAt,
  }) {
    final parsedStatus = parseTrackAnalysisStatus(status);
    final baseSummary =
        summary == null ? null : TrackAnalysisSummary.fromJson(summary);
    final parsedOverrides = TrackAnalysisOverrides.fromJson(overrides);
    final effectiveSummary = parsedOverrides == null
        ? baseSummary
        : parsedOverrides.applyTo(baseSummary ?? const TrackAnalysisSummary());
    return TrackAnalysis(
      status: parsedStatus,
      summary: effectiveSummary,
      overrides: parsedOverrides,
      overridesPresent: overridesPresent ?? overrides != null,
      updatedAt: _readDateTime(updatedAt),
    );
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
      if (overridesPresent) 'overrides': overrides?.toJson() ?? const {},
      if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    };
  }
}

/// Reads analysis fields from any track-list payload shape.
///
/// API surfaces use a mix of camelCase and snake_case. Overrides remain the
/// source of truth and are applied by [TrackAnalysis.fromJson] before callers
/// read BPM or key metadata.
TrackAnalysis? trackAnalysisFromTrackJson(Map<String, dynamic> json) {
  final rawStatus = json['analysisStatus'] ?? json['analysis_status'];
  final rawSummary = json['analysisSummary'] ?? json['analysis_summary'];
  final rawUpdatedAt = json['analysisUpdatedAt'] ?? json['analysis_updated_at'];
  final summaryMap = _readMap(rawSummary);
  final hasCamelCaseOverrides = json.containsKey('analysisOverrides');
  final hasSnakeCaseOverrides = json.containsKey('analysis_overrides');
  final hasSummaryOverrides = summaryMap?.containsKey('overrides') ?? false;
  final overridesPresent =
      hasCamelCaseOverrides || hasSnakeCaseOverrides || hasSummaryOverrides;
  final rawOverrides = hasCamelCaseOverrides
      ? json['analysisOverrides']
      : hasSnakeCaseOverrides
          ? json['analysis_overrides']
          : summaryMap?['overrides'];
  if (rawStatus == null &&
      rawSummary == null &&
      !overridesPresent &&
      rawUpdatedAt == null) {
    return null;
  }

  final analysis = TrackAnalysis.fromJson(
    status: rawStatus,
    summary: rawSummary,
    overrides: rawOverrides,
    overridesPresent: overridesPresent,
    updatedAt: rawUpdatedAt,
  );
  if (analysis.status == TrackAnalysisStatus.unknown &&
      !analysis.hasDisplayableSummary &&
      !analysis.overridesPresent &&
      analysis.updatedAt == null) {
    return null;
  }
  return analysis;
}

DateTime? _readDateTime(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is! String || value.trim().isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
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

/// User-authored corrections for analyzer metadata.
///
/// The analyzer summary stays useful for waveform/loudness/artifacts, while
/// these fields override the musical timing facts used by queue snapping,
/// BPM-sync automation, and user-facing analysis labels.
class TrackAnalysisOverrides {
  final double? bpm;
  final double? bpmConfidence;
  final List<int>? beatsMs;
  final List<int>? downbeatsMs;
  final String? musicalKey;
  final String? camelot;
  final String? provenance;

  const TrackAnalysisOverrides({
    this.bpm,
    this.bpmConfidence,
    this.beatsMs,
    this.downbeatsMs,
    this.musicalKey,
    this.camelot,
    this.provenance,
  });

  static TrackAnalysisOverrides? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null || map.isEmpty) return null;

    final bpmValue = AnalysisValue.fromJson(map['bpm']);
    final bpmMap = _readMap(map['bpm']);
    final beatGrid = _readMap(map['beat_grid'] ?? map['beatGrid']);
    final downbeats = _readMap(map['downbeats']);
    final beatsRaw = _firstPresent([
      map['beatGridMs'],
      map['beatsMs'],
      beatGrid?['beats_ms'],
      beatGrid?['beatsMs'],
    ]);
    final downbeatsRaw = _firstPresent([
      map['downbeatsMs'],
      downbeats?['positions_ms'],
      downbeats?['positionsMs'],
    ]);
    final keyValue = AnalysisValue.fromJson(map['key'] ?? map['musicalKey']);
    final camelotValue = AnalysisValue.fromJson(map['camelot']);

    final overrides = TrackAnalysisOverrides(
      bpm: bpmValue?.numericValue?.toDouble() ??
          _readDouble(map['nativeBpm']) ??
          _readDouble(beatGrid?['bpm']),
      bpmConfidence: _readDouble(map['bpmConfidence']) ??
          _readDouble(bpmMap?['confidence']) ??
          _readDouble(beatGrid?['confidence']),
      beatsMs: beatsRaw == null ? null : _readIntList(beatsRaw),
      downbeatsMs: downbeatsRaw == null ? null : _readIntList(downbeatsRaw),
      musicalKey: keyValue?.textValue ?? _readString(map['musicalKey']),
      camelot: camelotValue?.textValue,
      provenance: _readString(map['provenance']),
    );
    return overrides.isEmpty ? null : overrides;
  }

  bool get isEmpty =>
      bpm == null &&
      bpmConfidence == null &&
      beatsMs == null &&
      downbeatsMs == null &&
      musicalKey == null &&
      camelot == null;

  TrackAnalysisSummary applyTo(TrackAnalysisSummary base) {
    final source = provenance ?? 'manual_override';
    final effectiveBpmConfidence = bpmConfidence ?? (bpm == null ? null : 1.0);
    return TrackAnalysisSummary(
      bpm: bpm == null
          ? base.bpm
          : AnalysisValue(
              value: bpm!,
              confidence: effectiveBpmConfidence ?? base.bpm?.confidence,
              provenance: source,
            ),
      beatGrid: (bpm == null && beatsMs == null)
          ? base.beatGrid
          : BeatGridSummary(
              bpm: bpm ?? base.beatGrid?.bpm,
              offsetMs: base.beatGrid?.offsetMs,
              beatsMs: beatsMs ?? base.beatGrid?.beatsMs ?? const [],
              confidence: effectiveBpmConfidence ?? base.beatGrid?.confidence,
              provenance: source,
            ),
      downbeats: downbeatsMs == null
          ? base.downbeats
          : DownbeatSummary(
              positionsMs: downbeatsMs!,
              confidence: base.downbeats?.confidence,
              provenance: source,
            ),
      key: musicalKey == null
          ? base.key
          : AnalysisValue(
              value: musicalKey!,
              confidence: base.key?.confidence,
              provenance: source,
            ),
      camelot: camelot == null
          ? base.camelot
          : AnalysisValue(
              value: camelot!,
              confidence: base.camelot?.confidence,
              provenance: source,
            ),
      energy: base.energy,
      loudness: base.loudness,
      truePeak: base.truePeak,
      waveform: base.waveform,
      transients: base.transients,
      silence: base.silence,
      intro: base.intro,
      outro: base.outro,
      sections: base.sections,
      cueCandidates: base.cueCandidates,
    );
  }

  Map<String, dynamic> toJson() {
    final source = provenance ?? 'manual_override';
    final effectiveBpmConfidence = bpmConfidence ?? (bpm == null ? null : 1.0);
    return {
      if (bpm != null)
        'bpm': {
          'value': bpm,
          if (effectiveBpmConfidence != null)
            'confidence': effectiveBpmConfidence,
          'provenance': source,
        },
      if (bpm != null || effectiveBpmConfidence != null || beatsMs != null)
        'beat_grid': {
          if (bpm != null) 'bpm': bpm,
          if (effectiveBpmConfidence != null)
            'confidence': effectiveBpmConfidence,
          if (beatsMs != null) 'beats_ms': beatsMs,
          'provenance': source,
        },
      if (downbeatsMs != null)
        'downbeats': {'positions_ms': downbeatsMs, 'provenance': source},
      if (musicalKey != null)
        'key': {'value': musicalKey, 'provenance': source},
      if (camelot != null) 'camelot': {'value': camelot, 'provenance': source},
      if (provenance != null) 'provenance': provenance,
    };
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
  final TransientsSummary? transients;
  final SilenceSummary? silence;
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
    this.transients,
    this.silence,
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
      transients: TransientsSummary.fromJson(map['transients']),
      silence: SilenceSummary.fromJson(map['silence']),
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

    final peakCount = waveform?.peaks.length ?? 0;
    if (peakCount > 0) {
      labels.add(_pluralizedCount(peakCount, 'peak'));
    }

    final resolutionCount = waveform?.resolutions.length ?? 0;
    if (resolutionCount > 0) {
      labels.add(_pluralizedCount(resolutionCount, 'waveform layer'));
    }

    final transientCount = transients?.count ?? transients?.strongestMs.length;
    if (transientCount != null && transientCount > 0) {
      labels.add(_pluralizedCount(transientCount, 'transient'));
    }

    final silenceCount = silence?.ranges.length ?? 0;
    if (silenceCount > 0) {
      labels.add(_pluralizedCount(silenceCount, 'silence range'));
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
      if (transients != null) 'transients': transients!.toJson(),
      if (silence != null) 'silence': silence!.toJson(),
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
      integratedLufs: _readDouble(
        map['integrated_lufs'] ?? map['integratedLufs'],
      ),
      shortTermLufs: _readDouble(
        map['short_term_lufs'] ?? map['shortTermLufs'],
      ),
      loudnessRangeLu: _readDouble(
        map['loudness_range_lu'] ?? map['loudnessRangeLu'],
      ),
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
  final List<double> peaks;
  final List<double> rms;
  final int? sampleCount;
  final List<WaveformResolutionSummary> resolutions;
  final Map<String, SpectralBandSummary> spectralBands;
  final double? confidence;
  final String? provenance;

  const WaveformSummary({
    this.peaks = const [],
    this.rms = const [],
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
      peaks: _readDoubleList(map['peaks']),
      rms: _readDoubleList(map['rms']),
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      resolutions: _readList(map['resolutions'])
          .map(WaveformResolutionSummary.fromJson)
          .whereType<WaveformResolutionSummary>()
          .toList(growable: false),
      spectralBands: _readSpectralBands(
        map['spectral_bands'] ?? map['spectralBands'],
      ),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (peaks.isNotEmpty) 'peaks': peaks,
      if (rms.isNotEmpty) 'rms': rms,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (resolutions.isNotEmpty)
        'resolutions': resolutions.map((layer) => layer.toJson()).toList(),
      if (spectralBands.isNotEmpty)
        'spectral_bands': spectralBands.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class TransientsSummary {
  final int? count;
  final double? densityPerSecond;
  final List<int> strongestMs;
  final double? confidence;
  final String? provenance;

  const TransientsSummary({
    this.count,
    this.densityPerSecond,
    this.strongestMs = const [],
    this.confidence,
    this.provenance,
  });

  static TransientsSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return TransientsSummary(
      count: _readInt(map['count']),
      densityPerSecond: _readDouble(
        map['density_per_second'] ?? map['densityPerSecond'],
      ),
      strongestMs: _readIntList(map['strongest_ms'] ?? map['strongestMs']),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (count != null) 'count': count,
      if (densityPerSecond != null) 'density_per_second': densityPerSecond,
      if (strongestMs.isNotEmpty) 'strongest_ms': strongestMs,
      if (confidence != null) 'confidence': confidence,
      if (provenance != null) 'provenance': provenance,
    };
  }
}

class SilenceSummary {
  final int? leadingMs;
  final int? trailingMs;
  final List<AnalysisRange> ranges;
  final double? confidence;
  final String? provenance;

  const SilenceSummary({
    this.leadingMs,
    this.trailingMs,
    this.ranges = const [],
    this.confidence,
    this.provenance,
  });

  static SilenceSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return SilenceSummary(
      leadingMs: _readInt(map['leading_ms'] ?? map['leadingMs']),
      trailingMs: _readInt(map['trailing_ms'] ?? map['trailingMs']),
      ranges: _readList(map['ranges'])
          .map(AnalysisRange.fromJson)
          .whereType<AnalysisRange>()
          .toList(growable: false),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (leadingMs != null) 'leading_ms': leadingMs,
      if (trailingMs != null) 'trailing_ms': trailingMs,
      if (ranges.isNotEmpty)
        'ranges': ranges.map((range) => range.toJson()).toList(),
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
      samplesPerPixel: _readInt(
        map['samples_per_pixel'] ?? map['samplesPerPixel'],
      ),
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
  final List<double> values;

  const SpectralBandSummary({
    this.sampleCount,
    this.artifactRef,
    this.values = const [],
  });

  static SpectralBandSummary? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null) return null;
    return SpectralBandSummary(
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      artifactRef: _readString(map['artifact_ref'] ?? map['artifactRef']),
      values: _readDoubleList(map['values'] ?? map['samples'] ?? map['data']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sampleCount != null) 'sample_count': sampleCount,
      if (artifactRef != null) 'artifact_ref': artifactRef,
      if (values.isNotEmpty) 'values': values,
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

Object? _firstPresent(List<Object?> values) {
  for (final value in values) {
    if (value != null) return value;
  }
  return null;
}

List<int> _readIntList(Object? value) {
  return _readList(
    value,
  ).map(_readInt).whereType<int>().toList(growable: false);
}

List<double> _readDoubleList(Object? value) {
  return _readList(
    value,
  ).map(_readDouble).whereType<double>().toList(growable: false);
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
