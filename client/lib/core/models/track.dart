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
  });

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      duration: json['duration'] as int,
      trackNumber: json['trackNumber'] as int?,
      discNumber: json['discNumber'] as int?,
      year: json['year'] as int?,
      genre: json['genre'] as String?,
      mbid: json['mbid'] as String?,
      coverUrl: json['coverUrl'] as String?,
      filePath: json['filePath'] as String?,
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
      'trackNumber': trackNumber,
      'discNumber': discNumber,
      'year': year,
      'genre': genre,
      'mbid': mbid,
      'coverUrl': coverUrl,
      'filePath': filePath,
      'addedAt': addedAt.toIso8601String(),
    };
  }

  String get formattedDuration {
    final minutes = duration ~/ 60;
    final seconds = duration % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
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
