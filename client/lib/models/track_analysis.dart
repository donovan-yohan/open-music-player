import 'dart:convert';
import 'dart:math' as math;

enum TrackAnalysisStatus {
  pending,
  analyzing,
  analyzed,
  failed,
  stale,
  unsupported,
  unknown,
}

enum TrackAnalysisSummaryProjection { generated, effective }

const String trackAnalysisSummaryContractKey = '_omp_summary_contract';
const int _analysisSummaryContractVersion = 1;

class TrackAnalysis {
  final TrackAnalysisStatus status;

  /// Latest analyzer-owned facts before manual overrides are projected.
  ///
  /// [summary] remains the effective timing contract consumed by playback and
  /// queue surfaces. Keeping the generated source alongside it lets correction
  /// UIs reset without reverse-engineering analyzer facts from the projection.
  final TrackAnalysisSummary? generatedSummary;
  final TrackAnalysisSummary? summary;
  final TrackAnalysisOverrides? overrides;
  final bool overridesPresent;
  final DateTime? updatedAt;

  /// Monotonic server revision for the user-authored override document.
  ///
  /// This is deliberately separate from [updatedAt], which also advances when
  /// generated analyzer output changes. PATCH callers use this value for
  /// optimistic concurrency rather than treating a timestamp as a lock.
  final int? overrideRevision;
  final DateTime? overrideUpdatedAt;

  const TrackAnalysis({
    required this.status,
    this.generatedSummary,
    this.summary,
    this.overrides,
    bool? overridesPresent,
    this.updatedAt,
    this.overrideRevision,
    this.overrideUpdatedAt,
  }) : overridesPresent = overridesPresent ?? overrides != null;

  factory TrackAnalysis.fromJson({
    Object? status,
    Object? summary,
    Object? artifacts,
    Object? overrides,
    bool? overridesPresent,
    Object? updatedAt,
    Object? overrideRevision,
    Object? overrideUpdatedAt,
    TrackAnalysisSummaryProjection? summaryProjection,
  }) {
    final parsedStatus = parseTrackAnalysisStatus(status);
    final baseSummary = summary == null
        ? null
        : TrackAnalysisSummary.fromJson(summary, artifacts: artifacts);
    final parsedOverrides = TrackAnalysisOverrides.fromJson(overrides);
    final manualTiming = parsedOverrides?.manualTiming;
    final resolvedProjection = _summaryProjectionFromPayload(summary) ??
        summaryProjection ??
        TrackAnalysisSummaryProjection.generated;
    final generatedSummary =
        resolvedProjection == TrackAnalysisSummaryProjection.generated
            ? baseSummary
            : null;
    final effectiveSummary = resolvedProjection ==
                TrackAnalysisSummaryProjection.effective ||
            parsedOverrides == null
        ? baseSummary
        : parsedOverrides.applyTo(baseSummary ?? const TrackAnalysisSummary());
    return TrackAnalysis(
      status: parsedStatus,
      generatedSummary: generatedSummary,
      summary: effectiveSummary,
      overrides: parsedOverrides,
      overridesPresent: overridesPresent ?? overrides != null,
      updatedAt: _readDateTime(updatedAt),
      overrideRevision: _readInt(overrideRevision) ?? manualTiming?.revision,
      overrideUpdatedAt:
          _readDateTime(overrideUpdatedAt) ?? manualTiming?.updatedAt,
    );
  }

  bool get isNonSuccess =>
      status == TrackAnalysisStatus.pending ||
      status == TrackAnalysisStatus.analyzing ||
      status == TrackAnalysisStatus.failed ||
      status == TrackAnalysisStatus.stale ||
      status == TrackAnalysisStatus.unsupported;

  bool get hasDisplayableSummary => summary?.displayLabels.isNotEmpty ?? false;

  TrackAnalysisSummary? get _serializedSummary => generatedSummary ?? summary;

  TrackAnalysisSummaryProjection get _serializedSummaryProjection =>
      generatedSummary != null || !overridesPresent
          ? TrackAnalysisSummaryProjection.generated
          : TrackAnalysisSummaryProjection.effective;

  Map<String, dynamic> toJson() {
    final serializedSummary = _serializedSummary;
    return {
      'status': status.name,
      if (serializedSummary != null)
        'summary': _summaryWithContract(
          serializedSummary.toJson(),
          _serializedSummaryProjection,
        ),
      if (overridesPresent) 'overrides': overrides?.toJson() ?? const {},
      if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
      if (overrideRevision != null) 'override_revision': overrideRevision,
      if (overrideUpdatedAt != null)
        'override_updated_at': overrideUpdatedAt!.toUtc().toIso8601String(),
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
  final rawOverrideRevision =
      json['analysisOverrideRevision'] ?? json['analysis_override_revision'];
  final rawOverrideUpdatedAt =
      json['analysisOverrideUpdatedAt'] ?? json['analysis_override_updated_at'];
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
      rawUpdatedAt == null &&
      rawOverrideRevision == null &&
      rawOverrideUpdatedAt == null) {
    return null;
  }

  final analysis = TrackAnalysis.fromJson(
    status: rawStatus,
    summary: rawSummary,
    overrides: rawOverrides,
    overridesPresent: overridesPresent,
    updatedAt: rawUpdatedAt,
    overrideRevision: rawOverrideRevision,
    overrideUpdatedAt: rawOverrideUpdatedAt,
    summaryProjection: overridesPresent
        ? TrackAnalysisSummaryProjection.effective
        : TrackAnalysisSummaryProjection.generated,
  );
  if (analysis.status == TrackAnalysisStatus.unknown &&
      !analysis.hasDisplayableSummary &&
      !analysis.overridesPresent &&
      analysis.updatedAt == null &&
      analysis.overrideRevision == null &&
      analysis.overrideUpdatedAt == null) {
    return null;
  }
  return analysis;
}

/// Serializes analysis metadata into the camelCase playback payload contract.
///
/// An explicitly-present empty override object remains present. That
/// distinction lets downstream consumers preserve "known empty" instead of
/// collapsing it into "not provided".
Map<String, dynamic> analysisPlaybackFields(TrackAnalysis? analysis) {
  return trackAnalysisFields(analysis);
}

enum TrackAnalysisFieldStyle { camelCase, snakeCase }

typedef TrackAnalysisSummarySerializer = Object? Function(
    TrackAnalysisSummary summary);
typedef TrackAnalysisOverridesSerializer = Object Function(
    TrackAnalysisOverrides? overrides);

/// Canonical analysis-field mapping for track serializers.
///
/// Field naming and storage encoding vary by target, but presence semantics do
/// not: explicit empty overrides are always emitted, while absent overrides
/// remain omitted.
Map<String, dynamic> trackAnalysisFields(
  TrackAnalysis? analysis, {
  TrackAnalysisFieldStyle fieldStyle = TrackAnalysisFieldStyle.camelCase,
  TrackAnalysisSummarySerializer? summarySerializer,
  TrackAnalysisOverridesSerializer? overridesSerializer,
  bool includeUpdatedAtMicros = false,
}) {
  if (analysis == null) return const {};
  final snakeCase = fieldStyle == TrackAnalysisFieldStyle.snakeCase;
  final statusKey = snakeCase ? 'analysis_status' : 'analysisStatus';
  final summaryKey = snakeCase ? 'analysis_summary' : 'analysisSummary';
  final overridesKey = snakeCase ? 'analysis_overrides' : 'analysisOverrides';
  final updatedAtKey = snakeCase ? 'analysis_updated_at' : 'analysisUpdatedAt';
  final overrideRevisionKey =
      snakeCase ? 'analysis_override_revision' : 'analysisOverrideRevision';
  final overrideUpdatedAtKey =
      snakeCase ? 'analysis_override_updated_at' : 'analysisOverrideUpdatedAt';
  final updatedAt = analysis.updatedAt?.toUtc();
  final serializedSummary = analysis._serializedSummary;
  final serializedSummaryValue = serializedSummary == null
      ? null
      : summarySerializer == null
          ? serializedSummary.toJson()
          : summarySerializer(serializedSummary);
  return {
    statusKey: analysis.status.name,
    if (serializedSummaryValue != null)
      summaryKey: _serializedSummaryWithContract(
        serializedSummaryValue,
        analysis._serializedSummaryProjection,
      ),
    if (analysis.overridesPresent)
      overridesKey: overridesSerializer?.call(analysis.overrides) ??
          analysis.overrides?.toJson() ??
          const {},
    if (updatedAt != null) updatedAtKey: updatedAt.toIso8601String(),
    if (includeUpdatedAtMicros && updatedAt != null)
      'analysis_updated_at_us': updatedAt.microsecondsSinceEpoch,
    if (analysis.overrideRevision != null)
      overrideRevisionKey: analysis.overrideRevision,
    if (analysis.overrideUpdatedAt != null)
      overrideUpdatedAtKey:
          analysis.overrideUpdatedAt!.toUtc().toIso8601String(),
  };
}

TrackAnalysisSummaryProjection? _summaryProjectionFromPayload(Object? value) {
  final summary = _readMap(value);
  final contract = _readMap(summary?[trackAnalysisSummaryContractKey]);
  if (_readInt(contract?['version']) != _analysisSummaryContractVersion) {
    return null;
  }
  return switch (_readString(contract?['projection'])) {
    'generated' => TrackAnalysisSummaryProjection.generated,
    'effective' => TrackAnalysisSummaryProjection.effective,
    _ => null,
  };
}

/// Returns the normalized projection marker for a supported summary payload.
///
/// Playback and persistence boundaries use this instead of interpreting the
/// marker independently, leaving this model as the sole projection authority.
Map<String, dynamic>? trackAnalysisSummaryContract(Object? summary) {
  final projection = _summaryProjectionFromPayload(summary);
  return projection == null ? null : _summaryContract(projection);
}

Map<String, dynamic> _summaryWithContract(
  Map<String, dynamic> summary,
  TrackAnalysisSummaryProjection projection,
) {
  return {
    ...summary,
    trackAnalysisSummaryContractKey: _summaryContract(projection),
  };
}

Map<String, dynamic> _summaryContract(
  TrackAnalysisSummaryProjection projection,
) =>
    {
      'version': _analysisSummaryContractVersion,
      'projection': projection.name,
    };

Object _serializedSummaryWithContract(
  Object serialized,
  TrackAnalysisSummaryProjection projection,
) {
  if (serialized is String) {
    try {
      final decoded = jsonDecode(serialized);
      final summary = _readMap(decoded);
      if (summary != null) {
        return jsonEncode(_summaryWithContract(summary, projection));
      }
    } catch (_) {
      return serialized;
    }
    return serialized;
  }
  final summary = _readMap(serialized);
  return summary == null
      ? serialized
      : _summaryWithContract(summary, projection);
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

/// Canonical, normalized manual timing facts.
///
/// A manual correction is not a second beat-grid store. The backend owns the
/// effective timing projection used by playback; this document records only
/// the facts a DJ changed and remains available to the editor and for legacy
/// payload migration.
class ManualTimingOverride {
  final double? bpm;
  final int? beatAnchorMs;
  final int? beatsPerBar;
  final int? downbeatPhaseIndex;
  final int? phraseLengthBars;
  final double? confidence;
  final String? provenance;
  final int? revision;
  final DateTime? updatedAt;

  const ManualTimingOverride({
    this.bpm,
    this.beatAnchorMs,
    this.beatsPerBar,
    this.downbeatPhaseIndex,
    this.phraseLengthBars,
    this.confidence,
    this.provenance,
    this.revision,
    this.updatedAt,
  });

  static ManualTimingOverride? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null || map.isEmpty) return null;
    final value = ManualTimingOverride(
      bpm: _readDouble(map['bpm']),
      beatAnchorMs: _readInt(map['beat_anchor_ms'] ?? map['beatAnchorMs']),
      beatsPerBar: _readInt(map['beats_per_bar'] ?? map['beatsPerBar']),
      downbeatPhaseIndex: _readInt(
        map['downbeat_phase_index'] ?? map['downbeatPhaseIndex'],
      ),
      phraseLengthBars: _readInt(
        map['phrase_length_bars'] ?? map['phraseLengthBars'],
      ),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
      revision: _readInt(map['revision']),
      updatedAt: _readDateTime(map['updated_at'] ?? map['updatedAt']),
    );
    return value.isEmpty ? null : value;
  }

  bool get isEmpty =>
      bpm == null &&
      beatAnchorMs == null &&
      beatsPerBar == null &&
      downbeatPhaseIndex == null &&
      phraseLengthBars == null &&
      revision == null &&
      updatedAt == null;

  int? get normalizedDownbeatPhaseIndex {
    final meter = beatsPerBar;
    final phase = downbeatPhaseIndex;
    if (meter == null || meter <= 0 || phase == null) return null;
    return ((phase % meter) + meter) % meter;
  }

  ManualTimingOverride copyWith({
    double? bpm,
    int? beatAnchorMs,
    int? beatsPerBar,
    int? downbeatPhaseIndex,
    int? phraseLengthBars,
    double? confidence,
    String? provenance,
    int? revision,
    DateTime? updatedAt,
  }) =>
      ManualTimingOverride(
        bpm: bpm ?? this.bpm,
        beatAnchorMs: beatAnchorMs ?? this.beatAnchorMs,
        beatsPerBar: beatsPerBar ?? this.beatsPerBar,
        downbeatPhaseIndex: downbeatPhaseIndex ?? this.downbeatPhaseIndex,
        phraseLengthBars: phraseLengthBars ?? this.phraseLengthBars,
        confidence: confidence ?? this.confidence,
        provenance: provenance ?? this.provenance,
        revision: revision ?? this.revision,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson({bool includeServerMetadata = true}) => {
        if (bpm != null) 'bpm': bpm,
        if (beatAnchorMs != null) 'beat_anchor_ms': beatAnchorMs,
        if (beatsPerBar != null) 'beats_per_bar': beatsPerBar,
        if (normalizedDownbeatPhaseIndex != null)
          'downbeat_phase_index': normalizedDownbeatPhaseIndex,
        if (phraseLengthBars != null) 'phrase_length_bars': phraseLengthBars,
        if (!isEmpty) 'confidence': confidence ?? 1.0,
        if (!isEmpty) 'provenance': provenance ?? 'manual_override',
        if (includeServerMetadata && revision != null) 'revision': revision,
        if (includeServerMetadata && updatedAt != null)
          'updated_at': updatedAt!.toUtc().toIso8601String(),
      };

  static const int _maxProjectedBeatPositions = 8192;

  /// Applies only the normalized fallback projection used for old payload
  /// paths. The server remains the timing authority for current responses.
  TrackAnalysisSummary applyTo(TrackAnalysisSummary base) {
    final source = provenance ?? 'manual_override';
    final baseGrid = base.beatGrid;
    final baseBeats = baseGrid?.beatsMs ?? const <int>[];
    final effectiveBpm =
        bpm ?? base.bpm?.numericValue?.toDouble() ?? baseGrid?.bpm;
    final effectiveAnchor = beatAnchorMs ??
        baseGrid?.offsetMs ??
        (baseBeats.isEmpty ? null : baseBeats.first);
    final rewritesGrid = (bpm != null || beatAnchorMs != null) &&
        effectiveBpm != null &&
        effectiveBpm > 0 &&
        effectiveAnchor != null;
    final projectedBeats = rewritesGrid && baseBeats.isNotEmpty
        ? _regenerateBeatGrid(
            bpm: effectiveBpm,
            anchorMs: effectiveAnchor,
            baseBeats: baseBeats,
          )
        : baseBeats;
    final effectiveGrid = (baseGrid != null ||
            rewritesGrid ||
            bpm != null ||
            beatAnchorMs != null)
        ? BeatGridSummary(
            bpm: effectiveBpm,
            offsetMs: effectiveAnchor,
            beatsMs: projectedBeats,
            confidence: confidence ??
                (bpm == null && !rewritesGrid ? baseGrid?.confidence : 1.0),
            provenance: (bpm != null || beatAnchorMs != null)
                ? source
                : baseGrid?.provenance,
          )
        : null;
    final hasAnyPhaseFact = beatsPerBar != null || downbeatPhaseIndex != null;
    final phase = normalizedDownbeatPhaseIndex;
    final effectiveDownbeats = phase == null
        ? ((rewritesGrid || hasAnyPhaseFact) ? null : base.downbeats)
        : DownbeatSummary(
            positionsMs: List<int>.unmodifiable([
              for (var index = phase;
                  index < projectedBeats.length;
                  index += beatsPerBar!)
                projectedBeats[index],
            ]),
            confidence: confidence ?? 1.0,
            provenance: source,
          );
    return TrackAnalysisSummary(
      bpm: bpm == null
          ? base.bpm
          : AnalysisValue(
              value: bpm!,
              confidence: confidence ?? 1.0,
              provenance: source,
            ),
      beatGrid: effectiveGrid,
      downbeats: effectiveDownbeats,
      key: base.key,
      camelot: base.camelot,
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

  static List<int> _regenerateBeatGrid({
    required double bpm,
    required int anchorMs,
    required List<int> baseBeats,
  }) {
    if (bpm < 30 || bpm > 300 || anchorMs < 0 || baseBeats.isEmpty) {
      return baseBeats;
    }
    final maxBeat = baseBeats.fold<int>(-1, math.max);
    if (maxBeat < 0) return const [];
    final intervalMs = 60000 / bpm;
    final startIndex = (-anchorMs / intervalMs).ceil();
    final generated = <int>[];
    var previous = -1;
    for (var index = startIndex;
        generated.length < _maxProjectedBeatPositions;
        index++) {
      final beat = (anchorMs + index * intervalMs).round();
      if (beat > maxBeat) break;
      if (beat < 0 || beat == previous) continue;
      generated.add(beat);
      previous = beat;
    }
    return List<int>.unmodifiable(generated);
  }
}

/// User-authored corrections for analyzer metadata.
///
/// The analyzer summary stays useful for waveform/loudness/artifacts, while
/// these fields override the musical timing facts used by queue snapping,
/// BPM-sync automation, and user-facing analysis labels.
class TrackAnalysisOverrides {
  /// Normalized timing authority for newly written overrides.
  final ManualTimingOverride? manualTiming;
  final double? bpm;
  final double? bpmConfidence;
  final int? beatGridOffsetMs;
  final List<int>? beatsMs;
  final List<int>? downbeatsMs;
  final String? musicalKey;
  final String? camelot;
  final String? provenance;
  final String? bpmProvenance;
  final String? beatGridProvenance;
  final String? downbeatProvenance;

  const TrackAnalysisOverrides({
    this.manualTiming,
    this.bpm,
    this.bpmConfidence,
    this.beatGridOffsetMs,
    this.beatsMs,
    this.downbeatsMs,
    this.musicalKey,
    this.camelot,
    this.provenance,
    this.bpmProvenance,
    this.beatGridProvenance,
    this.downbeatProvenance,
  });

  static TrackAnalysisOverrides? fromJson(Object? json) {
    final map = _readMap(json);
    if (map == null || map.isEmpty) return null;

    final manualTiming = ManualTimingOverride.fromJson(
      map['manual_timing_override'] ?? map['manualTimingOverride'],
    );
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
      downbeats == null
          ? map['downbeats']
          : downbeats['positions_ms'] ?? downbeats['positionsMs'],
    ]);
    final keyValue = AnalysisValue.fromJson(map['key'] ?? map['musicalKey']);
    final camelotValue = AnalysisValue.fromJson(map['camelot']);

    final overrides = TrackAnalysisOverrides(
      manualTiming: manualTiming,
      bpm: bpmValue?.numericValue?.toDouble() ??
          _readDouble(map['nativeBpm']) ??
          _readDouble(beatGrid?['bpm']),
      bpmConfidence: _readDouble(map['bpmConfidence']) ??
          _readDouble(bpmMap?['confidence']) ??
          _readDouble(beatGrid?['confidence']),
      beatGridOffsetMs: _readInt(
        map['beatGridOffsetMs'] ??
            map['offsetMs'] ??
            beatGrid?['offset_ms'] ??
            beatGrid?['offsetMs'],
      ),
      beatsMs: beatsRaw == null ? null : _readIntList(beatsRaw),
      downbeatsMs: downbeatsRaw == null ? null : _readIntList(downbeatsRaw),
      musicalKey: keyValue?.textValue ?? _readString(map['musicalKey']),
      camelot: camelotValue?.textValue,
      provenance: _readString(map['provenance']) ??
          _readString(bpmMap?['provenance']) ??
          _readString(beatGrid?['provenance']) ??
          _readString(downbeats?['provenance']),
      bpmProvenance:
          _readString(bpmMap?['provenance']) ?? _readString(map['provenance']),
      beatGridProvenance: _readString(beatGrid?['provenance']) ??
          _readString(map['provenance']),
      downbeatProvenance: _readString(downbeats?['provenance']) ??
          _readString(map['provenance']),
    );
    return overrides.isEmpty ? null : overrides;
  }

  bool get isEmpty =>
      manualTiming == null &&
      bpm == null &&
      bpmConfidence == null &&
      beatGridOffsetMs == null &&
      beatsMs == null &&
      downbeatsMs == null &&
      musicalKey == null &&
      camelot == null;

  TrackAnalysisSummary applyTo(TrackAnalysisSummary base) {
    final legacy = _applyLegacyTo(base);
    final canonicalTiming = manualTiming;
    return canonicalTiming == null ? legacy : canonicalTiming.applyTo(legacy);
  }

  TrackAnalysisSummary _applyLegacyTo(TrackAnalysisSummary base) {
    final source = provenance ?? 'manual_override';
    final bpmSource = bpmProvenance ?? source;
    final beatGridSource = beatGridProvenance ?? source;
    final downbeatSource = downbeatProvenance ?? source;
    final effectiveBpmConfidence = bpm == null ? null : 1.0;
    // A legacy BPM-only correction changes tempo automation but never blesses
    // or rewrites analyzer beat markers. Only an explicit legacy marker list
    // can make the grid manual; normalized overrides use [manualTiming].
    final hasTrustedBeatGridOverride = beatsMs != null;
    final effectiveBeatGridConfidence = hasTrustedBeatGridOverride ? 1.0 : null;
    return TrackAnalysisSummary(
      bpm: bpm == null
          ? base.bpm
          : AnalysisValue(
              value: bpm!,
              confidence: effectiveBpmConfidence ?? base.bpm?.confidence,
              provenance: bpmSource,
            ),
      beatGrid: (bpm == null && beatGridOffsetMs == null && beatsMs == null)
          ? base.beatGrid
          : BeatGridSummary(
              bpm: bpm ?? base.beatGrid?.bpm,
              offsetMs: beatGridOffsetMs ?? base.beatGrid?.offsetMs,
              beatsMs: beatsMs ?? base.beatGrid?.beatsMs ?? const [],
              confidence:
                  effectiveBeatGridConfidence ?? base.beatGrid?.confidence,
              provenance: hasTrustedBeatGridOverride
                  ? beatGridSource
                  : base.beatGrid?.provenance,
            ),
      downbeats: downbeatsMs == null
          ? base.downbeats
          : DownbeatSummary(
              positionsMs: downbeatsMs!,
              confidence: 1.0,
              provenance: downbeatSource,
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

  Map<String, dynamic> toJson({bool includeServerMetadata = true}) {
    final canonicalTiming = manualTiming;
    final source = provenance ?? 'manual_override';
    final bpmSource = bpmProvenance ?? source;
    final beatGridSource = beatGridProvenance ?? source;
    final downbeatSource = downbeatProvenance ?? source;
    final effectiveBpmConfidence = bpm == null ? null : 1.0;
    // A legacy BPM override changes only BPM. It does not establish a manual
    // beat grid unless the legacy payload explicitly carried beat markers.
    final hasTrustedBeatGridOverride = beatsMs != null;
    final effectiveBeatGridConfidence = hasTrustedBeatGridOverride ? 1.0 : null;
    return {
      if (canonicalTiming != null)
        'manual_timing_override': canonicalTiming.toJson(
          includeServerMetadata: includeServerMetadata,
        ),
      if (bpm != null)
        'bpm': {
          'value': bpm,
          if (effectiveBpmConfidence != null)
            'confidence': effectiveBpmConfidence,
          'provenance': bpmSource,
        },
      if (beatGridOffsetMs != null || beatsMs != null)
        'beat_grid': {
          if (bpm != null && hasTrustedBeatGridOverride) 'bpm': bpm,
          if (beatGridOffsetMs != null) 'offset_ms': beatGridOffsetMs,
          if (effectiveBeatGridConfidence != null)
            'confidence': effectiveBeatGridConfidence,
          if (beatsMs != null) 'beats_ms': beatsMs,
          if (hasTrustedBeatGridOverride) 'provenance': beatGridSource,
        },
      if (downbeatsMs != null)
        'downbeats': {
          'positions_ms': downbeatsMs,
          'confidence': 1.0,
          'provenance': downbeatSource,
        },
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

  factory TrackAnalysisSummary.fromJson(Object? json, {Object? artifacts}) {
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
      waveform: WaveformSummary.fromJson(map['waveform'], artifacts: artifacts),
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
    if (json is List) {
      return DownbeatSummary(positionsMs: _readIntList(json));
    }
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
  final List<double> minPeaks;
  final List<double> maxPeaks;
  final List<double> rms;
  final int? sampleCount;
  final List<WaveformResolutionSummary> resolutions;
  final WaveformChannelsSummary? channels;
  final Map<String, SpectralBandSummary> spectralBands;
  final double? confidence;
  final String? provenance;

  const WaveformSummary({
    this.peaks = const [],
    this.minPeaks = const [],
    this.maxPeaks = const [],
    this.rms = const [],
    this.sampleCount,
    this.resolutions = const [],
    this.channels,
    this.spectralBands = const {},
    this.confidence,
    this.provenance,
  });

  static WaveformSummary? fromJson(Object? json, {Object? artifacts}) {
    final map = _readMap(json);
    if (map == null) return null;
    final artifactMap = _readMap(artifacts);
    final waveformArtifacts = _readMap(artifactMap?['waveforms']);
    final channelArtifacts = _readMap(artifactMap?['channels']);
    final spectralArtifacts = _readMap(artifactMap?['spectral_bands']);
    final preferredWaveform = _preferredArtifactTier(waveformArtifacts);
    final preferredChannels = _preferredArtifactTier(channelArtifacts);
    final preferredSpectral = _preferredArtifactTier(spectralArtifacts);
    final resolutions = _readList(map['resolutions'])
        .map(
          (resolution) => WaveformResolutionSummary.fromJson(
            resolution,
            waveformArtifact: _namedArtifactTier(
              waveformArtifacts,
              _readString(_readMap(resolution)?['name']),
            ),
            channelArtifact: _namedArtifactTier(
              channelArtifacts,
              _readString(_readMap(resolution)?['name']),
            ),
            spectralArtifact: _namedArtifactTier(
              spectralArtifacts,
              _readString(_readMap(resolution)?['name']),
            ),
          ),
        )
        .whereType<WaveformResolutionSummary>()
        .toList(growable: false);
    return WaveformSummary(
      peaks: _readDoubleList(map['peaks'] ?? preferredWaveform?['peaks']),
      minPeaks: _readDoubleList(
        map['min_peaks'] ??
            map['minPeaks'] ??
            map['minima'] ??
            preferredWaveform?['min_peaks'] ??
            preferredWaveform?['minPeaks'] ??
            preferredWaveform?['minima'],
      ),
      maxPeaks: _readDoubleList(
        map['max_peaks'] ??
            map['maxPeaks'] ??
            map['maxima'] ??
            preferredWaveform?['max_peaks'] ??
            preferredWaveform?['maxPeaks'] ??
            preferredWaveform?['maxima'],
      ),
      rms: _readDoubleList(map['rms'] ?? preferredWaveform?['rms']),
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      resolutions: resolutions,
      channels: WaveformChannelsSummary.fromJson(
        map['channels'],
        artifactValues: preferredChannels,
      ),
      spectralBands: _mergeSpectralBands(
        _readSpectralBands(map['spectral_bands'] ?? map['spectralBands']),
        _readSpectralBands(preferredSpectral),
      ),
      confidence: _readDouble(map['confidence']),
      provenance: _readString(map['provenance']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (peaks.isNotEmpty) 'peaks': peaks,
      if (minPeaks.isNotEmpty) 'min_peaks': minPeaks,
      if (maxPeaks.isNotEmpty) 'max_peaks': maxPeaks,
      if (rms.isNotEmpty) 'rms': rms,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (resolutions.isNotEmpty)
        'resolutions': resolutions.map((layer) => layer.toJson()).toList(),
      if (channels != null) 'channels': channels!.toJson(),
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
  final List<double> peaks;
  final List<double> minPeaks;
  final List<double> maxPeaks;
  final List<double> rms;
  final Map<String, SpectralBandSummary> channels;
  final Map<String, SpectralBandSummary> spectralBands;

  const WaveformResolutionSummary({
    this.name,
    this.samplesPerPixel,
    this.sampleCount,
    this.artifactRef,
    this.peaks = const [],
    this.minPeaks = const [],
    this.maxPeaks = const [],
    this.rms = const [],
    this.channels = const {},
    this.spectralBands = const {},
  });

  static WaveformResolutionSummary? fromJson(
    Object? json, {
    Object? waveformArtifact,
    Object? channelArtifact,
    Object? spectralArtifact,
  }) {
    final map = _readMap(json);
    if (map == null) return null;
    final waveform = _readMap(waveformArtifact);
    return WaveformResolutionSummary(
      name: _readString(map['name']),
      samplesPerPixel: _readInt(
        map['samples_per_pixel'] ?? map['samplesPerPixel'],
      ),
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      artifactRef: _readString(map['artifact_ref'] ?? map['artifactRef']),
      peaks: _readDoubleList(map['peaks'] ?? waveform?['peaks']),
      minPeaks: _readDoubleList(
        map['min_peaks'] ??
            map['minPeaks'] ??
            map['minima'] ??
            waveform?['min_peaks'] ??
            waveform?['minPeaks'] ??
            waveform?['minima'],
      ),
      maxPeaks: _readDoubleList(
        map['max_peaks'] ??
            map['maxPeaks'] ??
            map['maxima'] ??
            waveform?['max_peaks'] ??
            waveform?['maxPeaks'] ??
            waveform?['maxima'],
      ),
      rms: _readDoubleList(map['rms'] ?? waveform?['rms']),
      channels: _mergeSpectralBands(
        _readChannelValues(map['channels']),
        _readChannelValues(channelArtifact),
      ),
      spectralBands: _mergeSpectralBands(
        _readSpectralBands(map['spectral_bands'] ?? map['spectralBands']),
        _readSpectralBands(spectralArtifact),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      if (samplesPerPixel != null) 'samples_per_pixel': samplesPerPixel,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (artifactRef != null) 'artifact_ref': artifactRef,
      if (peaks.isNotEmpty) 'peaks': peaks,
      if (minPeaks.isNotEmpty) 'min_peaks': minPeaks,
      if (maxPeaks.isNotEmpty) 'max_peaks': maxPeaks,
      if (rms.isNotEmpty) 'rms': rms,
      if (channels.isNotEmpty)
        'channels': channels.map((key, value) => MapEntry(key, value.toJson())),
      if (spectralBands.isNotEmpty)
        'spectral_bands': spectralBands.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
    };
  }
}

class WaveformChannelsSummary {
  final String? channelSet;
  final Object? audioRef;
  final int? sampleCount;
  final Map<String, dynamic> normalization;
  final Map<String, double> weights;
  final Map<String, double> crossoversHz;
  final String? provenance;
  final Map<String, SpectralBandSummary> values;

  const WaveformChannelsSummary({
    this.channelSet,
    this.audioRef,
    this.sampleCount,
    this.normalization = const {},
    this.weights = const {},
    this.crossoversHz = const {},
    this.provenance,
    this.values = const {},
  });

  static WaveformChannelsSummary? fromJson(
    Object? json, {
    Object? artifactValues,
  }) {
    final map = _readMap(json);
    if (map == null) return null;
    final descriptorValues = _readChannelValues(map['values']);
    final resolvedValues = _mergeSpectralBands(
      descriptorValues,
      _readChannelValues(artifactValues),
    );
    return WaveformChannelsSummary(
      channelSet: _readString(map['channel_set'] ?? map['channelSet']),
      audioRef:
          map.containsKey('audio_ref') ? map['audio_ref'] : map['audioRef'],
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      normalization: Map<String, dynamic>.unmodifiable(
        _readMap(map['normalization']) ?? const {},
      ),
      weights: Map<String, double>.unmodifiable(_readDoubleMap(map['weights'])),
      crossoversHz: Map<String, double>.unmodifiable(
        _readDoubleMap(map['crossovers_hz'] ?? map['crossoversHz']),
      ),
      provenance: _readString(map['provenance']),
      values: Map<String, SpectralBandSummary>.unmodifiable(resolvedValues),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (channelSet != null) 'channel_set': channelSet,
      'audio_ref': audioRef,
      if (sampleCount != null) 'sample_count': sampleCount,
      if (normalization.isNotEmpty) 'normalization': normalization,
      if (weights.isNotEmpty) 'weights': weights,
      if (crossoversHz.isNotEmpty) 'crossovers_hz': crossoversHz,
      if (provenance != null) 'provenance': provenance,
      if (values.isNotEmpty)
        'values': values.map((key, value) => MapEntry(key, value.toJson())),
    };
  }
}

class SpectralBandSummary {
  final int? sampleCount;
  final String? artifactRef;
  final Map<String, dynamic> normalization;
  final double? weight;
  final String? provenance;
  final List<double> values;

  const SpectralBandSummary({
    this.sampleCount,
    this.artifactRef,
    this.normalization = const {},
    this.weight,
    this.provenance,
    this.values = const [],
  });

  static SpectralBandSummary? fromJson(Object? json) {
    if (json is List) {
      return SpectralBandSummary(
        sampleCount: json.length,
        values: _readDoubleList(json),
      );
    }
    final map = _readMap(json);
    if (map == null) return null;
    return SpectralBandSummary(
      sampleCount: _readInt(map['sample_count'] ?? map['sampleCount']),
      artifactRef: _readString(map['artifact_ref'] ?? map['artifactRef']),
      normalization: Map<String, dynamic>.unmodifiable(
        _readMap(map['normalization']) ?? const {},
      ),
      weight: _readDouble(map['weight']),
      provenance: _readString(map['provenance']),
      values: _readDoubleList(map['values'] ?? map['samples'] ?? map['data']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sampleCount != null) 'sample_count': sampleCount,
      if (artifactRef != null) 'artifact_ref': artifactRef,
      if (normalization.isNotEmpty) 'normalization': normalization,
      if (weight != null) 'weight': weight,
      if (provenance != null) 'provenance': provenance,
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

Map<String, SpectralBandSummary> _readChannelValues(Object? value) {
  final map = _readMap(value);
  if (map == null) return const {};
  final nestedValues = _readMap(map['values']);
  return _readSpectralBands(nestedValues ?? map);
}

Map<String, SpectralBandSummary> _mergeSpectralBands(
  Map<String, SpectralBandSummary> descriptors,
  Map<String, SpectralBandSummary> artifacts,
) {
  if (artifacts.isEmpty) return descriptors;
  final merged = <String, SpectralBandSummary>{...descriptors};
  for (final entry in artifacts.entries) {
    final descriptor = descriptors[entry.key];
    final artifact = entry.value;
    merged[entry.key] = SpectralBandSummary(
      sampleCount: artifact.sampleCount ??
          descriptor?.sampleCount ??
          artifact.values.length,
      artifactRef: descriptor?.artifactRef ?? artifact.artifactRef,
      normalization: descriptor?.normalization ?? artifact.normalization,
      weight: descriptor?.weight ?? artifact.weight,
      provenance: descriptor?.provenance ?? artifact.provenance,
      values: artifact.values.isNotEmpty
          ? artifact.values
          : descriptor?.values ?? const [],
    );
  }
  return merged;
}

Map<String, dynamic>? _namedArtifactTier(
  Map<String, dynamic>? artifacts,
  String? name,
) {
  if (artifacts == null || name == null) return null;
  return _readMap(artifacts[name]);
}

Map<String, double> _readDoubleMap(Object? value) {
  final map = _readMap(value);
  if (map == null) return const {};
  return {
    for (final entry in map.entries)
      if (_readDouble(entry.value) case final parsed?) entry.key: parsed,
  };
}

Map<String, dynamic>? _preferredArtifactTier(Map<String, dynamic>? artifacts) {
  if (artifacts == null) return null;
  return _readMap(artifacts['detail']) ??
      _readMap(artifacts['overview']) ??
      _readMap(artifacts['values']) ??
      artifacts;
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
