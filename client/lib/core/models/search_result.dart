import '../../models/track_analysis.dart';

class TrackResult {
  /// Local library track id (present for local /search/recordings results).
  final int? id;
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
  final TrackAnalysis? analysis;

  const TrackResult({
    this.id,
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
    this.analysis,
  });

  factory TrackResult.fromJson(Map<String, dynamic> json) {
    // Maps the backend RecordingResponse shape (id, durationMs, coverArtUrl,
    // mbRecordingId/mbReleaseId/mbArtistId). Falls back to the older MusicBrainz
    // field names so a MB-shaped payload still parses. mbid may be empty for local
    // tracks with no MusicBrainz match.
    return TrackResult(
      id: (json['id'] as num?)?.toInt(),
      mbid: (json['mbRecordingId'] ?? json['mbid'] ?? '') as String,
      title: (json['title'] ?? '') as String,
      artist: json['artist'] as String?,
      artistMbid: (json['mbArtistId'] ?? json['artistMbid']) as String?,
      album: json['album'] as String?,
      albumMbid: (json['mbReleaseId'] ?? json['albumMbid']) as String?,
      duration: ((json['durationMs'] ?? json['duration']) as num?)?.toInt(),
      trackNumber: (json['trackNumber'] as num?)?.toInt(),
      releaseDate: json['releaseDate'] as String?,
      coverUrl: (json['coverArtUrl'] ?? json['coverUrl']) as String?,
      score: (json['score'] as num?)?.toInt(),
      analysis: trackAnalysisFromTrackJson(json),
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
