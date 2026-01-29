import 'mb_suggestion.dart';

class Track {
  final String id;
  final String title;
  final String? artist;
  final String? album;
  final int duration;
  final int? trackNumber;
  final int? discNumber;
  final int? year;
  final String? genre;
  final String? mbid;
  final String? coverUrl;
  final String? filePath;
  final DateTime addedAt;
  final bool mbVerified;
  final List<MBSuggestion> mbSuggestions;

  const Track({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    this.trackNumber,
    this.discNumber,
    this.year,
    this.genre,
    this.mbid,
    this.coverUrl,
    this.filePath,
    required this.addedAt,
    this.mbVerified = false,
    this.mbSuggestions = const [],
  });

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id']?.toString() ?? '',
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      duration: json['duration'] ?? json['duration_ms'] ?? 0,
      trackNumber: json['trackNumber'] ?? json['track_number'] as int?,
      discNumber: json['discNumber'] ?? json['disc_number'] as int?,
      year: json['year'] as int?,
      genre: json['genre'] as String?,
      mbid: json['mbid'] ?? json['mb_recording_id'] as String?,
      coverUrl: json['coverUrl'] ?? json['cover_art_url'] as String?,
      filePath: json['filePath'] ?? json['file_path'] as String?,
      addedAt: json['addedAt'] != null
          ? DateTime.parse(json['addedAt'] as String)
          : json['added_at'] != null
              ? DateTime.parse(json['added_at'] as String)
              : DateTime.now(),
      mbVerified: json['mbVerified'] ?? json['mb_verified'] ?? false,
      mbSuggestions: (json['mbSuggestions'] ?? json['mb_suggestions'] as List<dynamic>?)
              ?.map((e) => MBSuggestion.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'trackNumber': trackNumber,
      'discNumber': discNumber,
      'year': year,
      'genre': genre,
      'mbid': mbid,
      'coverUrl': coverUrl,
      'filePath': filePath,
      'addedAt': addedAt.toIso8601String(),
      'mbVerified': mbVerified,
      'mbSuggestions': mbSuggestions.map((s) => s.toJson()).toList(),
    };
  }

  String get formattedDuration {
    final durationSeconds = duration > 1000 ? duration ~/ 1000 : duration;
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Returns true if this track has suggestions available
  bool get hasSuggestions => mbSuggestions.isNotEmpty;

  /// Returns true if this track needs verification (unverified with suggestions)
  bool get needsVerification => !mbVerified && hasSuggestions;

  /// Creates a copy of this track with updated fields
  Track copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    int? duration,
    int? trackNumber,
    int? discNumber,
    int? year,
    String? genre,
    String? mbid,
    String? coverUrl,
    String? filePath,
    DateTime? addedAt,
    bool? mbVerified,
    List<MBSuggestion>? mbSuggestions,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      year: year ?? this.year,
      genre: genre ?? this.genre,
      mbid: mbid ?? this.mbid,
      coverUrl: coverUrl ?? this.coverUrl,
      filePath: filePath ?? this.filePath,
      addedAt: addedAt ?? this.addedAt,
      mbVerified: mbVerified ?? this.mbVerified,
      mbSuggestions: mbSuggestions ?? this.mbSuggestions,
    );
  }
}

class TrackResult {
  final String mbid;
  final String title;
  final String? artist;
  final String? artistMbid;
  final String? album;
  final String? albumMbid;
  final int? duration;
  final int? trackNumber;
  final String? releaseDate;
  final String? coverUrl;
  final int? score;

  const TrackResult({
    required this.mbid,
    required this.title,
    this.artist,
    this.artistMbid,
    this.album,
    this.albumMbid,
    this.duration,
    this.trackNumber,
    this.releaseDate,
    this.coverUrl,
    this.score,
  });

  factory TrackResult.fromJson(Map<String, dynamic> json) {
    return TrackResult(
      mbid: json['mbid'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      artistMbid: json['artistMbid'] as String?,
      album: json['album'] as String?,
      albumMbid: json['albumMbid'] as String?,
      duration: json['duration'] as int?,
      trackNumber: json['trackNumber'] as int?,
      releaseDate: json['releaseDate'] as String?,
      coverUrl: json['coverArtUrl'] ?? json['coverUrl'] as String?,
      score: json['score'] as int?,
    );
  }

  String get formattedDuration {
    if (duration == null) return '--:--';
    final totalSeconds = duration! ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class TrackDetail {
  final String id;
  final String title;
  final String? artist;
  final String? artistId;
  final String? album;
  final String? albumId;
  final int? duration;
  final int? position;
  final bool? inLibrary;
  final bool? downloadable;

  const TrackDetail({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.duration,
    this.position,
    this.inLibrary,
    this.downloadable,
  });

  factory TrackDetail.fromJson(Map<String, dynamic> json) {
    return TrackDetail(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      artistId: json['artistId'] as String?,
      album: json['album'] as String?,
      albumId: json['albumId'] as String?,
      duration: json['duration'] as int?,
      position: json['position'] as int?,
      inLibrary: json['inLibrary'] as bool?,
      downloadable: json['downloadable'] as bool?,
    );
  }

  String get formattedDuration {
    if (duration == null) return '--:--';
    final totalSeconds = duration! ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
