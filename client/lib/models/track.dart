class Track {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final int duration;
  final String? coverUrl;
  final DateTime addedAt;

  Track({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    this.coverUrl,
    required this.addedAt,
  });

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id']?.toString() ?? json['track_id']?.toString() ?? '',
      title: json['title'] as String? ?? 'Unknown track',
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      duration: _parseDuration(json),
      coverUrl: json['coverUrl'] as String? ?? json['cover_url'] as String?,
      addedAt: _parseDate(json['addedAt'] ?? json['added_at']),
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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'coverUrl': coverUrl,
      'addedAt': addedAt.toIso8601String(),
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
