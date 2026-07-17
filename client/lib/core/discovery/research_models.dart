import 'discovery_models.dart';

const _jobStatuses = {
  'queued',
  'running',
  'cancel_requested',
  'completed',
  'degraded',
  'cancelled',
};
const _revisionKinds = {'baseline', 'enhancement'};
const _stages = {'baseline', 'direct_judge', 'deep_agent'};
const _degradationCodes = {
  'model_disabled',
  'model_unavailable',
  'budget_exhausted',
  'transient',
  'timeout',
  'runner_terminal',
  'validation_rejected',
  'safety_rejected',
  'enhancement_rejected',
  'lease_expired',
  'no_candidates',
};
const _eventKinds = {
  'created',
  'revision_appended',
  'claimed',
  'lease_renewed',
  'lease_recovered',
  'degraded',
  'cancel_requested',
  'cancelled',
  'retried',
  'completed',
  'reviewed',
  'runner_terminal',
};

class ResearchJob {
  const ResearchJob({
    required this.id,
    required this.status,
    required this.retrySafe,
    required this.attempts,
    required this.maxAttempts,
    required this.latestRevision,
    required this.latestRevisionId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String status;
  final bool retrySafe;
  final int attempts;
  final int maxAttempts;
  final int latestRevision;
  final String latestRevisionId;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ResearchJob.fromJson(Map<String, dynamic> json) {
    final status = _string(json, 'status');
    if (!_jobStatuses.contains(status)) _invalid('unknown research job status');
    return ResearchJob(
      id: _string(json, 'id'),
      status: status,
      retrySafe: _bool(json, 'retrySafe'),
      attempts: _int(json, 'attempts'),
      maxAttempts: _int(json, 'maxAttempts'),
      latestRevision: _int(json, 'latestRevision'),
      latestRevisionId: _string(json, 'latestRevisionId'),
      createdAt: _date(json, 'createdAt'),
      updatedAt: _date(json, 'updatedAt'),
    );
  }

  bool get isActive =>
      status == 'queued' || status == 'running' || status == 'cancel_requested';
  bool get isTerminal => !isActive;
  bool get canRetry => isTerminal && retrySafe;
}

class ResearchSnapshot {
  const ResearchSnapshot({
    required this.job,
    required this.revisions,
    this.latestDegradation,
  });

  final ResearchJob job;
  final List<ResearchRevision> revisions;
  final ResearchDegradation? latestDegradation;

  factory ResearchSnapshot.fromJson(Map<String, dynamic> json) {
    final revisions = _list(json, 'revisions')
        .map((entry) => ResearchRevision.fromJson(_map(entry, 'revision')))
        .toList(growable: false);
    if (revisions.isEmpty) _invalid('research snapshot has no revisions');
    final numbers = revisions.map((revision) => revision.number).toList();
    if (numbers.toSet().length != numbers.length) {
      _invalid('research snapshot has duplicate revisions');
    }
    return ResearchSnapshot(
      job: ResearchJob.fromJson(_map(json['job'], 'job')),
      revisions: revisions,
      latestDegradation: json['latestDegradation'] == null
          ? null
          : ResearchDegradation.fromJson(
              _map(json['latestDegradation'], 'latestDegradation'),
            ),
    );
  }

  ResearchRevision get latestRevision {
    return revisions.reduce(
      (latest, revision) => revision.number > latest.number ? revision : latest,
    );
  }
}

class ResearchRevision {
  const ResearchRevision({
    required this.id,
    required this.jobId,
    required this.number,
    required this.kind,
    required this.payload,
    required this.validatedAt,
  });

  final String id;
  final String jobId;
  final int number;
  final String kind;
  final ResearchRevisionPayload payload;
  final DateTime validatedAt;

  factory ResearchRevision.fromJson(Map<String, dynamic> json) {
    final kind = _string(json, 'kind');
    if (!_revisionKinds.contains(kind)) {
      _invalid('unknown research revision kind');
    }
    return ResearchRevision(
      id: _string(json, 'id'),
      jobId: _string(json, 'jobId'),
      number: _int(json, 'number'),
      kind: kind,
      payload: ResearchRevisionPayload.fromJson(
        _map(json['payload'], 'payload'),
      ),
      validatedAt: _date(json, 'validatedAt'),
    );
  }
}

class ResearchRevisionPayload {
  const ResearchRevisionPayload({
    required this.stage,
    required this.query,
    required this.candidates,
    required this.recommendations,
    required this.provenanceSource,
  });

  final String stage;
  final String query;
  final List<ResearchCandidate> candidates;
  final List<ResearchRecommendation> recommendations;
  final String provenanceSource;

  factory ResearchRevisionPayload.fromJson(Map<String, dynamic> json) {
    if (_string(json, 'schemaVersion') != 'omp.research.revision.v1') {
      _invalid('unsupported research revision schema');
    }
    final stage = _string(json, 'stage');
    if (!_stages.contains(stage)) _invalid('unknown research stage');
    final provenance = _map(json['provenance'], 'provenance');
    return ResearchRevisionPayload(
      stage: stage,
      query: _string(json, 'query'),
      candidates: _list(json, 'candidates')
          .map((entry) => ResearchCandidate.fromJson(_map(entry, 'candidate')))
          .toList(growable: false),
      recommendations: _list(json, 'recommendations')
          .map(
            (entry) =>
                ResearchRecommendation.fromJson(_map(entry, 'recommendation')),
          )
          .toList(growable: false),
      provenanceSource: _string(provenance, 'source'),
    );
  }
}

class ResearchCandidate {
  const ResearchCandidate({
    required this.candidateId,
    required this.provider,
    required this.sourceUrl,
    required this.title,
    required this.downloadable,
    required this.playable,
    required this.sourceQuality,
    this.sourceId = '',
    this.artist,
    this.uploader,
    this.durationMs,
  });

  final String candidateId;
  final String provider;
  final String sourceUrl;
  final String title;
  final bool downloadable;
  final bool playable;
  final DiscoverySourceQuality sourceQuality;
  final String sourceId;
  final String? artist;
  final String? uploader;
  final int? durationMs;

  factory ResearchCandidate.fromJson(Map<String, dynamic> json) {
    return ResearchCandidate(
      candidateId: _string(json, 'candidateId'),
      provider: _string(json, 'provider'),
      sourceUrl: _string(json, 'sourceUrl'),
      title: _string(json, 'title'),
      downloadable: _bool(json, 'downloadable'),
      playable: _bool(json, 'playable'),
      sourceQuality: DiscoverySourceQuality.fromJson(
        _map(json['sourceQuality'], 'sourceQuality'),
      ),
      sourceId: _optionalString(json['sourceId']),
      artist: _optionalNullableString(json['artist']),
      uploader: _optionalNullableString(json['uploader']),
      durationMs: _optionalInt(json['durationMs']),
    );
  }

  DiscoveryCandidate toDiscoveryCandidate() => DiscoveryCandidate(
        candidateId: candidateId,
        provider: provider,
        sourceId: sourceId,
        sourceUrl: sourceUrl,
        title: title,
        artist: artist,
        uploader: uploader,
        durationMs: durationMs,
        downloadable: downloadable,
        playable: playable,
        sourceQuality: sourceQuality,
      );
}

class ResearchRecommendation {
  const ResearchRecommendation({
    required this.candidateId,
    required this.rank,
    required this.confidence,
    required this.classification,
  });

  final String candidateId;
  final int rank;
  final double confidence;
  final String classification;

  factory ResearchRecommendation.fromJson(Map<String, dynamic> json) {
    return ResearchRecommendation(
      candidateId: _string(json, 'candidateId'),
      rank: _int(json, 'rank'),
      confidence: _double(json, 'confidence'),
      classification: _string(json, 'classification'),
    );
  }
}

class ResearchDegradation {
  const ResearchDegradation({
    required this.code,
    required this.retryable,
    this.message,
  });

  final String code;
  final bool retryable;
  final String? message;

  factory ResearchDegradation.fromJson(Map<String, dynamic> json) {
    final code = _string(json, 'code');
    if (!_degradationCodes.contains(code)) {
      _invalid('unknown research degradation');
    }
    return ResearchDegradation(
      code: code,
      retryable: _bool(json, 'retryable'),
      message: _optionalNullableString(json['message']),
    );
  }
}

class ResearchEventPage {
  const ResearchEventPage({required this.events, required this.afterSequence});

  final List<ResearchEvent> events;
  final int afterSequence;

  factory ResearchEventPage.fromJson(Map<String, dynamic> json) {
    final after = _int(json, 'afterSequence');
    final events = _list(json, 'events')
        .map((entry) => ResearchEvent.fromJson(_map(entry, 'event')))
        .toList(growable: false);
    var previous = after;
    for (final event in events) {
      if (event.sequence <= previous) {
        _invalid('research events are not ordered');
      }
      previous = event.sequence;
    }
    return ResearchEventPage(events: events, afterSequence: after);
  }
}

class ResearchEvent {
  const ResearchEvent({
    required this.jobId,
    required this.sequence,
    required this.kind,
    required this.createdAt,
    this.revision,
    this.degradation,
  });

  final String jobId;
  final int sequence;
  final String kind;
  final DateTime createdAt;
  final int? revision;
  final ResearchDegradation? degradation;

  factory ResearchEvent.fromJson(Map<String, dynamic> json) {
    final kind = _string(json, 'kind');
    if (!_eventKinds.contains(kind)) _invalid('unknown research event kind');
    return ResearchEvent(
      jobId: _string(json, 'jobId'),
      sequence: _int(json, 'sequence'),
      kind: kind,
      createdAt: _date(json, 'createdAt'),
      revision: _optionalInt(json['revision']),
      degradation: json['degradation'] == null
          ? null
          : ResearchDegradation.fromJson(
              _map(json['degradation'], 'degradation'),
            ),
    );
  }
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  _invalid('research $label must be an object');
}

List<dynamic> _list(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is List) return value;
  _invalid('research $key must be a list');
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  _invalid('research $key is required');
}

bool _bool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  _invalid('research $key must be a boolean');
}

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  _invalid('research $key must be an integer');
}

int? _optionalInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  _invalid('research integer field is invalid');
}

double _double(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  _invalid('research $key must be a number');
}

String _optionalString(Object? value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  _invalid('research string field is invalid');
}

String? _optionalNullableString(Object? value) {
  if (value == null) return null;
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  _invalid('research string field is invalid');
}

DateTime _date(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) _invalid('research $key must be a timestamp');
  return parsed.toUtc();
}

Never _invalid(String message) => throw FormatException(message);
