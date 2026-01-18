/// MusicBrainz match suggestion for unverified tracks
class MBSuggestion {
  final String mbRecordingId;
  final String title;
  final String artist;
  final String? artistMbid;
  final String? album;
  final String? albumMbid;
  final int? duration;
  final double confidence;
  final List<String> matchReasons;

  const MBSuggestion({
    required this.mbRecordingId,
    required this.title,
    required this.artist,
    this.artistMbid,
    this.album,
    this.albumMbid,
    this.duration,
    required this.confidence,
    this.matchReasons = const [],
  });

  factory MBSuggestion.fromJson(Map<String, dynamic> json) {
    return MBSuggestion(
      mbRecordingId: json['mb_recording_id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      artistMbid: json['artist_mbid'] as String?,
      album: json['album'] as String?,
      albumMbid: json['album_mbid'] as String?,
      duration: json['duration'] as int?,
      confidence: (json['confidence'] as num).toDouble(),
      matchReasons: (json['match_reasons'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mb_recording_id': mbRecordingId,
      'title': title,
      'artist': artist,
      'artist_mbid': artistMbid,
      'album': album,
      'album_mbid': albumMbid,
      'duration': duration,
      'confidence': confidence,
      'match_reasons': matchReasons,
    };
  }

  /// Returns formatted duration string (e.g., "3:45")
  String get formattedDuration {
    if (duration == null) return '--:--';
    final totalSeconds = duration! ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Returns confidence as a percentage string (e.g., "87%")
  String get confidencePercentage {
    return '${(confidence * 100).round()}%';
  }

  /// Returns human-readable match reasons
  List<String> get formattedMatchReasons {
    return matchReasons.map((reason) {
      switch (reason) {
        case 'title_match':
          return 'Title matches';
        case 'artist_match':
          return 'Artist matches';
        case 'duration_match':
          return 'Duration matches';
        default:
          return reason;
      }
    }).toList();
  }
}
