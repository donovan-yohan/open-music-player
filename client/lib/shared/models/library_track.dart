class LibraryTrack {
  final int id;
  final String title;
  final String? artist;
  final String? album;
  final int durationMs;
  final bool mbVerified;
  final DateTime addedAt;
  final String? coverArtUrl;
  final String? mbRecordingId;

  const LibraryTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.durationMs,
    required this.mbVerified,
    required this.addedAt,
    this.coverArtUrl,
    this.mbRecordingId,
  });

  factory LibraryTrack.fromJson(Map<String, dynamic> json) {
    return LibraryTrack(
      id: json['id'] as int,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      durationMs: json['duration_ms'] as int? ?? 0,
      mbVerified: json['mb_verified'] as bool? ?? false,
      addedAt: DateTime.parse(json['added_at'] as String),
      coverArtUrl: json['cover_art_url'] as String?,
      mbRecordingId: json['mb_recording_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration_ms': durationMs,
      'mb_verified': mbVerified,
      'added_at': addedAt.toIso8601String(),
      'cover_art_url': coverArtUrl,
      'mb_recording_id': mbRecordingId,
    };
  }

  String get formattedDuration {
    final minutes = durationMs ~/ 60000;
    final seconds = (durationMs % 60000) ~/ 1000;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
