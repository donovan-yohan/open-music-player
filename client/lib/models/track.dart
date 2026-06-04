enum TrackQueueStatus { pending, downloading, failed, playable }

class Track {
  /// Stable UI identifier for this row. Queue API responses use queue item IDs;
  /// library/search responses usually use playable track IDs.
  final String id;

  /// Queue item ID required by queue item endpoints like retry/remove-by-item.
  final String queueItemId;

  /// Numeric backend track ID used to issue signed playback URLs. This differs
  /// from [id] for source-backed queue items, where [id] is the queue item UUID.
  final String? playbackTrackId;
  final String title;
  final String? artist;
  final String? album;
  final int duration;
  final String? coverUrl;
  final DateTime addedAt;
  final TrackQueueStatus queueStatus;
  final bool canPlay;
  final bool canRetry;

  Track({
    required this.id,
    String? queueItemId,
    this.playbackTrackId,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    this.coverUrl,
    required this.addedAt,
    this.queueStatus = TrackQueueStatus.playable,
    bool? canPlay,
    bool? canRetry,
  })  : queueItemId = queueItemId ?? id,
        canPlay = canPlay ?? queueStatus == TrackQueueStatus.playable,
        canRetry = canRetry ?? queueStatus == TrackQueueStatus.failed;

  factory Track.fromJson(Map<String, dynamic> json) {
    final queueItemId =
        json['queueItemId']?.toString() ?? json['queue_item_id']?.toString();
    final playbackTrackId =
        json['trackId']?.toString() ?? json['track_id']?.toString();
    final id = json['id']?.toString() ?? queueItemId ?? playbackTrackId ?? '';
    final status = _parseQueueStatus(json);

    return Track(
      id: id,
      queueItemId: queueItemId ?? id,
      playbackTrackId: playbackTrackId,
      title: json['title'] as String? ?? 'Unknown track',
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      duration: _parseDuration(json),
      coverUrl: json['coverUrl'] as String? ?? json['cover_url'] as String?,
      addedAt: _parseDate(json['addedAt'] ?? json['added_at']),
      queueStatus: status,
      canPlay: json['canPlay'] as bool? ??
          json['can_play'] as bool? ??
          status == TrackQueueStatus.playable,
      canRetry: json['canRetry'] as bool? ??
          json['can_retry'] as bool? ??
          status == TrackQueueStatus.failed,
    );
  }

  static int _parseDuration(Map<String, dynamic> json) {
    final duration = json['duration'];
    if (duration is int) return duration;
    if (duration is num) return duration.round();

    final durationMs = json['duration_ms'];
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

  static TrackQueueStatus _parseQueueStatus(Map<String, dynamic> json) {
    final raw = json['status'] ??
        json['download_status'] ??
        json['downloadStatus'] ??
        json['playback_status'] ??
        json['playbackStatus'];
    final status = raw?.toString().trim().toLowerCase().replaceAll('-', '_');

    switch (status) {
      case 'pending':
      case 'queued':
      case 'waiting':
        return TrackQueueStatus.pending;
      case 'downloading':
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
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'coverUrl': coverUrl,
      'addedAt': addedAt.toIso8601String(),
      'status': queueStatus.name,
      'canPlay': canPlay,
      'canRetry': canRetry,
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
    };
  }

  /// Track duration in milliseconds (stored as whole seconds).
  int get durationMs => duration * 1000;

  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
