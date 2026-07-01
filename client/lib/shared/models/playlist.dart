import 'track.dart';

class Playlist {
  final int id;
  final int userId;
  final String name;
  final String? description;
  final String? coverUrl;
  final bool isPublic;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Track>? tracks;
  final int? _trackCount;
  final int? totalDurationMs;

  Playlist({
    required this.id,
    this.userId = 0,
    required this.name,
    this.description,
    this.coverUrl,
    this.isPublic = false,
    required this.createdAt,
    required this.updatedAt,
    this.tracks,
    int? trackCount,
    this.totalDurationMs,
  }) : _trackCount = trackCount;

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final tracks = json['tracks'] != null
        ? (json['tracks'] as List).map((t) => Track.fromJson(t)).toList()
        : null;

    return Playlist(
      id: _intValue(json['id']),
      userId: _intValue(json['userId'] ?? json['user_id'], fallback: 0),
      name: json['name'] as String,
      description: json['description'] as String?,
      coverUrl: json['coverUrl'] as String? ?? json['cover_url'] as String?,
      isPublic: _boolValue(json['isPublic'] ?? json['is_public']),
      createdAt: _dateTimeValue(json['createdAt'] ?? json['created_at']),
      updatedAt: _dateTimeValue(json['updatedAt'] ?? json['updated_at']),
      tracks: tracks,
      trackCount: _optionalInt(json['trackCount'] ?? json['track_count']),
      totalDurationMs: _optionalInt(
        json['durationMs'] ?? json['totalDuration'] ?? json['total_duration'],
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'description': description,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'description': description,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Playlist.fromDbMap(Map<String, dynamic> map) {
    return Playlist(
      id: map['id'] as int,
      userId: map['user_id'] as int,
      name: map['name'] as String,
      description: map['description'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  int get trackCount => tracks?.length ?? _trackCount ?? 0;

  /// Returns total duration of all tracks formatted as "Xh Ym" or "Xm Ys"
  String get formattedDuration {
    if ((tracks == null || tracks!.isEmpty) && totalDurationMs == null) {
      return '0m';
    }

    final totalMs = tracks != null && tracks!.isNotEmpty
        ? tracks!.fold<int>(0, (sum, track) => sum + (track.durationMs ?? 0))
        : totalDurationMs!;

    final totalSeconds = totalMs ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  /// Creates a copy with updated fields
  Playlist copyWith({
    int? id,
    int? userId,
    String? name,
    String? description,
    String? coverUrl,
    bool? isPublic,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<Track>? tracks,
    int? trackCount,
    int? totalDurationMs,
  }) {
    return Playlist(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      description: description ?? this.description,
      coverUrl: coverUrl ?? this.coverUrl,
      isPublic: isPublic ?? this.isPublic,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tracks: tracks ?? this.tracks,
      trackCount: trackCount ?? _trackCount,
      totalDurationMs: totalDurationMs ?? this.totalDurationMs,
    );
  }
}

int _intValue(dynamic value, {int fallback = 0}) =>
    _optionalInt(value) ?? fallback;

bool _boolValue(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.toLowerCase() == 'true' || value == '1';
  return false;
}

int? _optionalInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime _dateTimeValue(dynamic value) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
