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
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      duration: json['duration'] as int,
      coverUrl: json['coverUrl'] as String?,
      addedAt: DateTime.parse(json['addedAt'] as String),
    );
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

  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
