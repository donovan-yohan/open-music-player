import 'track_analysis.dart';

enum TrackQueueStatus { pending, downloading, failed, playable }

class QueueTrack {
  /// Stable UI identifier for this row. Queue API responses use queue item IDs;
  /// library/search responses usually use playable track IDs.
  final String id;

  /// Queue item ID required by queue item endpoints like retry/remove-by-item.
  final String queueItemId;

  /// Numeric backend track ID used to issue signed playback URLs. This differs
  /// from [id] for source-backed queue items, where [id] is the queue item UUID.
  final String? playbackTrackId;
  final String? sourceCandidateId;
  final String? sourceUrl;
  final String title;
  final String? artist;
  final String? album;
  final int duration;
  final String? coverUrl;
  final DateTime addedAt;
  final TrackQueueStatus queueStatus;
  final bool canPlay;
  final bool canRetry;
  final TrackAnalysis? analysis;

  QueueTrack({
    required this.id,
    String? queueItemId,
    this.playbackTrackId,
    this.sourceCandidateId,
    this.sourceUrl,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    this.coverUrl,
    required this.addedAt,
    this.queueStatus = TrackQueueStatus.playable,
    bool? canPlay,
    bool? canRetry,
    this.analysis,
  })  : queueItemId = queueItemId ?? id,
        canPlay = canPlay ?? queueStatus == TrackQueueStatus.playable,
        canRetry = canRetry ?? queueStatus == TrackQueueStatus.failed;

  factory QueueTrack.fromJson(Map<String, dynamic> json) {
    final sourceCandidate = _readMap(json['sourceCandidate']);
    final queueItemId = json['queueItemId']?.toString();
    final playbackTrackId =
        json['trackId']?.toString() ?? json['track_id']?.toString();
    final sourceCandidateId =
        _readString(sourceCandidate, const ['candidateId', 'candidate_id']) ??
            _readString(json, const ['sourceCandidateId']);
    final sourceUrl =
        _readString(sourceCandidate, const ['sourceUrl', 'source_url']) ??
            _readString(json, const ['sourceUrl']);
    final id = json['id']?.toString() ??
        queueItemId ??
        playbackTrackId ??
        sourceCandidateId ??
        sourceUrl ??
        '';
    final status = _parseQueueStatus(json);
    final canPlayOverride = json['canPlay'] as bool?;
    final analysis = trackAnalysisFromTrackJson(json);

    return QueueTrack(
      id: id,
      queueItemId: queueItemId ?? id,
      playbackTrackId: playbackTrackId,
      sourceCandidateId: sourceCandidateId,
      sourceUrl: sourceUrl,
      title: json['title'] as String? ??
          _readString(sourceCandidate, const ['title']) ??
          'Unknown track',
      artist: json['artist'] as String? ??
          _readString(sourceCandidate, const ['artist', 'uploader']),
      album: json['album'] as String? ??
          _readString(sourceCandidate, const ['album', 'provider']),
      duration: _parseDuration(json, sourceCandidate),
      coverUrl: json['coverUrl'] as String? ??
          json['cover_url'] as String? ??
          _readString(sourceCandidate, const ['thumbnailUrl', 'thumbnail_url']),
      addedAt: _parseDate(json['addedAt'] ?? json['added_at']),
      queueStatus: status,
      canPlay: status == TrackQueueStatus.playable && (canPlayOverride ?? true),
      canRetry: json['canRetry'] as bool? ?? status == TrackQueueStatus.failed,
      analysis: analysis,
    );
  }

  static int _parseDuration(
    Map<String, dynamic> json,
    Map<String, dynamic>? sourceCandidate,
  ) {
    final duration = json['duration'] ?? sourceCandidate?['duration'];
    if (duration is int) return duration;
    if (duration is num) return duration.round();

    final durationMs = json['duration_ms'] ??
        json['durationMs'] ??
        sourceCandidate?['duration_ms'] ??
        sourceCandidate?['durationMs'];
    if (durationMs is int) return durationMs ~/ 1000;
    if (durationMs is num) return (durationMs / 1000).round();

    return 0;
  }

  static DateTime _parseDate(Object? value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  static Map<String, dynamic>? _readMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  static String? _readString(
    Map<String, dynamic>? json,
    Iterable<String> keys,
  ) {
    if (json == null) return null;
    for (final key in keys) {
      final value = json[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static TrackQueueStatus _parseQueueStatus(Map<String, dynamic> json) {
    final raw =
        json['status'] ?? json['downloadStatus'] ?? json['playbackState'];
    final status = raw
        ?.toString()
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');

    switch (status) {
      case 'pending':
      case 'queued':
      case 'waiting':
        return TrackQueueStatus.pending;
      case 'downloading':
      case 'uploading':
      case 'processing':
      case 'in_progress':
        return TrackQueueStatus.downloading;
      case 'failed':
      case 'error':
        return TrackQueueStatus.failed;
      case 'completed':
      case 'complete':
      case 'ready':
      case 'available':
      case 'playable':
      default:
        return TrackQueueStatus.playable;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'queueItemId': queueItemId,
      if (playbackTrackId != null) 'trackId': playbackTrackId,
      if (sourceCandidateId != null) 'sourceCandidateId': sourceCandidateId,
      if (sourceUrl != null) 'sourceUrl': sourceUrl,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'coverUrl': coverUrl,
      'addedAt': addedAt.toIso8601String(),
      'status': queueStatus.name,
      'canPlay': canPlay,
      'canRetry': canRetry,
      if (analysis != null) 'analysisStatus': analysis!.status.name,
      if (analysis?.summary != null)
        'analysisSummary': analysis!.summary!.toJson(),
      if (analysis?.overrides != null)
        'analysisOverrides': analysis!.overrides!.toJson(),
      if (analysis?.updatedAt != null)
        'analysisUpdatedAt': analysis!.updatedAt!.toUtc().toIso8601String(),
    };
  }

  Map<String, dynamic> toPlaybackJson() {
    return {
      'id': playbackTrackId ?? id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'artwork_url': coverUrl,
      if (analysis != null) 'analysisStatus': analysis!.status.name,
      if (analysis?.summary != null)
        'analysisSummary': analysis!.summary!.toJson(),
      if (analysis?.overrides != null)
        'analysisOverrides': analysis!.overrides!.toJson(),
      if (analysis?.updatedAt != null)
        'analysisUpdatedAt': analysis!.updatedAt!.toUtc().toIso8601String(),
    };
  }

  QueueTrack copyWith({
    String? id,
    String? queueItemId,
    String? playbackTrackId,
    String? sourceCandidateId,
    String? sourceUrl,
    String? title,
    String? artist,
    String? album,
    int? duration,
    String? coverUrl,
    DateTime? addedAt,
    TrackQueueStatus? queueStatus,
    bool? canPlay,
    bool? canRetry,
    TrackAnalysis? analysis,
  }) {
    return QueueTrack(
      id: id ?? this.id,
      queueItemId: queueItemId ?? this.queueItemId,
      playbackTrackId: playbackTrackId ?? this.playbackTrackId,
      sourceCandidateId: sourceCandidateId ?? this.sourceCandidateId,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      coverUrl: coverUrl ?? this.coverUrl,
      addedAt: addedAt ?? this.addedAt,
      queueStatus: queueStatus ?? this.queueStatus,
      canPlay: canPlay ?? this.canPlay,
      canRetry: canRetry ?? this.canRetry,
      analysis: analysis ?? this.analysis,
    );
  }

  /// Track duration in milliseconds (stored as whole seconds).
  int get durationMs => duration * 1000;

  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
