class Playlist {
  final String id;
  final String name;
  final String? description;
  final int trackCount;
  final int? totalDuration;
  final String? coverUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    required this.trackCount,
    this.totalDuration,
    this.coverUrl,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      trackCount: json['trackCount'] as int,
      totalDuration: json['totalDuration'] as int?,
      coverUrl: json['coverUrl'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}
