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

  String get formattedDuration {
    if (duration == null) return '--:--';
    final totalSeconds = duration! ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get confidencePercentage => '${(confidence * 100).round()}%';

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

class Track {
  final int id;
  final String identityHash;
  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;
  final String? version;
  final String? mbRecordingId;
  final String? mbReleaseId;
  final String? mbArtistId;
  final bool mbVerified;
  final String? sourceUrl;
  final String? sourceType;
  final String? storageKey;
  final int? fileSizeBytes;
  final Map<String, dynamic>? metadata;
  final List<MBSuggestion> mbSuggestions;
  final DateTime createdAt;
  final DateTime updatedAt;

  Track({
    required this.id,
    required this.identityHash,
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.version,
    this.mbRecordingId,
    this.mbReleaseId,
    this.mbArtistId,
    this.mbVerified = false,
    this.sourceUrl,
    this.sourceType,
    this.storageKey,
    this.fileSizeBytes,
    this.metadata,
    this.mbSuggestions = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory Track.fromJson(Map<String, dynamic> json) {
    // Parse MB suggestions from the mb_suggestions field
    final suggestionsJson = json['mb_suggestions'] as List<dynamic>?;
    final suggestions = suggestionsJson
            ?.map((e) => MBSuggestion.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    return Track(
      id: json['id'] as int,
      identityHash: json['identity_hash'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      durationMs: json['duration_ms'] as int?,
      version: json['version'] as String?,
      mbRecordingId: json['mb_recording_id'] as String?,
      mbReleaseId: json['mb_release_id'] as String?,
      mbArtistId: json['mb_artist_id'] as String?,
      mbVerified: json['mb_verified'] as bool? ?? false,
      sourceUrl: json['source_url'] as String?,
      sourceType: json['source_type'] as String?,
      storageKey: json['storage_key'] as String?,
      fileSizeBytes: json['file_size_bytes'] as int?,
      metadata: json['metadata_json'] as Map<String, dynamic>?,
      mbSuggestions: suggestions,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'identity_hash': identityHash,
      'title': title,
      'artist': artist,
      'album': album,
      'duration_ms': durationMs,
      'version': version,
      'mb_recording_id': mbRecordingId,
      'mb_release_id': mbReleaseId,
      'mb_artist_id': mbArtistId,
      'mb_verified': mbVerified,
      'source_url': sourceUrl,
      'source_type': sourceType,
      'storage_key': storageKey,
      'file_size_bytes': fileSizeBytes,
      'metadata_json': metadata,
      'mb_suggestions': mbSuggestions.map((s) => s.toJson()).toList(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'identity_hash': identityHash,
      'title': title,
      'artist': artist,
      'album': album,
      'duration_ms': durationMs,
      'version': version,
      'mb_recording_id': mbRecordingId,
      'mb_release_id': mbReleaseId,
      'mb_artist_id': mbArtistId,
      'mb_verified': mbVerified ? 1 : 0,
      'source_url': sourceUrl,
      'source_type': sourceType,
      'storage_key': storageKey,
      'file_size_bytes': fileSizeBytes,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Track.fromDbMap(Map<String, dynamic> map) {
    return Track(
      id: map['id'] as int,
      identityHash: map['identity_hash'] as String,
      title: map['title'] as String,
      artist: map['artist'] as String?,
      album: map['album'] as String?,
      durationMs: map['duration_ms'] as int?,
      version: map['version'] as String?,
      mbRecordingId: map['mb_recording_id'] as String?,
      mbReleaseId: map['mb_release_id'] as String?,
      mbArtistId: map['mb_artist_id'] as String?,
      mbVerified: (map['mb_verified'] as int?) == 1,
      sourceUrl: map['source_url'] as String?,
      sourceType: map['source_type'] as String?,
      storageKey: map['storage_key'] as String?,
      fileSizeBytes: map['file_size_bytes'] as int?,
      metadata: null,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  String get displayArtist => artist ?? 'Unknown Artist';
  String get displayAlbum => album ?? 'Unknown Album';

  String get formattedDuration {
    if (durationMs == null) return '--:--';
    final seconds = durationMs! ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '$minutes:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  /// Returns true if this track has suggestions available
  bool get hasSuggestions => mbSuggestions.isNotEmpty;

  /// Returns true if this track needs verification (unverified with suggestions)
  bool get needsVerification => !mbVerified && hasSuggestions;

  /// Creates a copy of this track with updated fields
  Track copyWith({
    int? id,
    String? identityHash,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? version,
    String? mbRecordingId,
    String? mbReleaseId,
    String? mbArtistId,
    bool? mbVerified,
    String? sourceUrl,
    String? sourceType,
    String? storageKey,
    int? fileSizeBytes,
    Map<String, dynamic>? metadata,
    List<MBSuggestion>? mbSuggestions,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Track(
      id: id ?? this.id,
      identityHash: identityHash ?? this.identityHash,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationMs: durationMs ?? this.durationMs,
      version: version ?? this.version,
      mbRecordingId: mbRecordingId ?? this.mbRecordingId,
      mbReleaseId: mbReleaseId ?? this.mbReleaseId,
      mbArtistId: mbArtistId ?? this.mbArtistId,
      mbVerified: mbVerified ?? this.mbVerified,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      sourceType: sourceType ?? this.sourceType,
      storageKey: storageKey ?? this.storageKey,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      metadata: metadata ?? this.metadata,
      mbSuggestions: mbSuggestions ?? this.mbSuggestions,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
