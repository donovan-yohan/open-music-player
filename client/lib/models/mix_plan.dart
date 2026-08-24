import '../core/engine/tempo_automation.dart';
import 'stem_edits.dart';

bool _isNonBlank(String value) => value.trim().isNotEmpty;

bool _isPositiveIntString(String value) {
  final parsed = int.tryParse(value);
  return parsed != null && parsed > 0 && parsed.toString() == value;
}

int _parsePositiveTrackId(String value) {
  final parsed = int.parse(value);
  if (parsed <= 0) {
    throw FormatException('trackId must be a positive integer', value);
  }
  return parsed;
}

class MixPlanClip {
  final String clipId;
  final String queueItemId;
  final bool hasExplicitQueueItemId;
  final String trackId;
  final int sourceStartMs;
  final int sourceEndMs;
  final int timelineStartMs;
  final double gainDb;
  final int? fadeInMs;
  final int? fadeOutMs;
  final String pitchMode;

  /// Optional ADR 0006 `stemEdits` v1 document. Authoring/persistence only —
  /// playback of stem cuts is not wired up on this path.
  final StemEdits? stemEdits;

  MixPlanClip({
    required this.clipId,
    required this.queueItemId,
    this.hasExplicitQueueItemId = true,
    required this.trackId,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.timelineStartMs,
    this.gainDb = 0,
    this.fadeInMs,
    this.fadeOutMs,
    String pitchMode = pitchModePreserve,
    this.stemEdits,
  })  : assert(_isNonBlank(clipId)),
        assert(_isNonBlank(queueItemId)),
        assert(_isPositiveIntString(trackId)),
        assert(sourceStartMs >= 0),
        assert(sourceEndMs > sourceStartMs),
        pitchMode = normalizePitchMode(pitchMode),
        assert(timelineStartMs >= 0),
        assert(fadeInMs == null || fadeInMs >= 0),
        assert(fadeOutMs == null || fadeOutMs >= 0);

  int get selectedDurationMs => sourceEndMs - sourceStartMs;

  int get timelineEndMs => timelineStartMs + selectedDurationMs;

  MixPlanClip withTimelineStartMs(int ms) => MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId,
        hasExplicitQueueItemId: hasExplicitQueueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: ms < 0 ? 0 : ms,
        gainDb: gainDb,
        fadeInMs: fadeInMs,
        fadeOutMs: fadeOutMs,
        pitchMode: pitchMode,
        stemEdits: stemEdits,
      );

  MixPlanClip withSourceRange({
    required int sourceStartMs,
    required int sourceEndMs,
  }) =>
      MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId,
        hasExplicitQueueItemId: hasExplicitQueueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
        gainDb: gainDb,
        fadeInMs: fadeInMs,
        fadeOutMs: fadeOutMs,
        pitchMode: pitchMode,
        stemEdits: stemEdits,
      );

  MixPlanClip withPitchMode(String mode) => MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId,
        hasExplicitQueueItemId: hasExplicitQueueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
        gainDb: gainDb,
        fadeInMs: fadeInMs,
        fadeOutMs: fadeOutMs,
        pitchMode: mode,
        stemEdits: stemEdits,
      );

  /// Replaces (or clears, with `null`) the stem edit document on this clip.
  MixPlanClip withStemEdits(StemEdits? edits) => MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId,
        hasExplicitQueueItemId: hasExplicitQueueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
        gainDb: gainDb,
        fadeInMs: fadeInMs,
        fadeOutMs: fadeOutMs,
        pitchMode: pitchMode,
        stemEdits: edits,
      );

  /// General-purpose copy used by editing surfaces. Null arguments keep the
  /// current value; fades may be explicitly cleared with [clearFadeIn] /
  /// [clearFadeOut].
  MixPlanClip copyWith({
    String? queueItemId,
    int? sourceStartMs,
    int? sourceEndMs,
    int? timelineStartMs,
    double? gainDb,
    int? fadeInMs,
    int? fadeOutMs,
  }) =>
      MixPlanClip(
        clipId: clipId,
        queueItemId: queueItemId ?? this.queueItemId,
        hasExplicitQueueItemId: hasExplicitQueueItemId,
        trackId: trackId,
        sourceStartMs: sourceStartMs ?? this.sourceStartMs,
        sourceEndMs: sourceEndMs ?? this.sourceEndMs,
        timelineStartMs: timelineStartMs ?? this.timelineStartMs,
        gainDb: gainDb ?? this.gainDb,
        fadeInMs: fadeInMs ?? this.fadeInMs,
        fadeOutMs: fadeOutMs ?? this.fadeOutMs,
        pitchMode: pitchMode,
        stemEdits: stemEdits,
      );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'clipId': clipId,
      'queueItemId': queueItemId,
      'trackId': _parsePositiveTrackId(trackId),
      'sourceStartMs': sourceStartMs,
      'sourceEndMs': sourceEndMs,
      'timelineStartMs': timelineStartMs,
      'gainDb': gainDb,
    };
    if (fadeInMs != null) {
      json['fadeInMs'] = fadeInMs;
    }
    if (fadeOutMs != null) {
      json['fadeOutMs'] = fadeOutMs;
    }
    if (pitchMode != pitchModePreserve) {
      json['pitchMode'] = pitchMode;
    }
    if (stemEdits != null) {
      json['stemEdits'] = stemEdits!.toJson();
    }
    return json;
  }

  factory MixPlanClip.fromJson(Map<String, dynamic> json) {
    final clipId = json['clipId'] as String;
    final rawQueueItemId = (json['queueItemId'] as String?)?.trim();
    final hasExplicitQueueItemId = rawQueueItemId?.isNotEmpty ?? false;
    final rawStemEdits = json['stemEdits'];
    return MixPlanClip(
      clipId: clipId,
      queueItemId: hasExplicitQueueItemId ? rawQueueItemId! : clipId,
      hasExplicitQueueItemId: hasExplicitQueueItemId,
      trackId: json['trackId'].toString(),
      sourceStartMs: (json['sourceStartMs'] as num).toInt(),
      sourceEndMs: (json['sourceEndMs'] as num).toInt(),
      timelineStartMs: (json['timelineStartMs'] as num).toInt(),
      gainDb: (json['gainDb'] as num?)?.toDouble() ?? 0,
      fadeInMs: (json['fadeInMs'] as num?)?.toInt(),
      fadeOutMs: (json['fadeOutMs'] as num?)?.toInt(),
      pitchMode: (json['pitchMode'] as String?) ?? pitchModePreserve,
      stemEdits: rawStemEdits is Map
          ? StemEdits.fromJson(Map<String, dynamic>.from(rawStemEdits))
          : null,
    );
  }
}

class MixPlanSummary {
  final int clipCount;
  final List<String> trackIds;
  final int durationMs;

  const MixPlanSummary({
    required this.clipCount,
    required this.trackIds,
    required this.durationMs,
  });

  factory MixPlanSummary.fromJson(Map<String, dynamic> json) => MixPlanSummary(
        clipCount: (json['clipCount'] as num).toInt(),
        trackIds: (json['trackIds'] as List? ?? const [])
            .map((id) => id.toString())
            .toList(),
        durationMs: (json['durationMs'] as num).toInt(),
      );
}

class MixPlan {
  final String id;
  final int schemaVersion;
  final String name;
  final List<MixPlanClip> clips;
  final MixPlanSummary summary;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MixPlan({
    required this.id,
    required this.schemaVersion,
    required this.name,
    required this.clips,
    required this.summary,
    required this.version,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MixPlan.fromJson(Map<String, dynamic> json) => MixPlan(
        id: json['id'] as String,
        schemaVersion: (json['schemaVersion'] as num).toInt(),
        name: json['name'] as String,
        clips: (json['clips'] as List? ?? const [])
            .map((clip) => MixPlanClip.fromJson(clip as Map<String, dynamic>))
            .toList(),
        summary:
            MixPlanSummary.fromJson(json['summary'] as Map<String, dynamic>),
        version: (json['version'] as num).toInt(),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}
