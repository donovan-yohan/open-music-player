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

  /// Whether the current user has liked (favorited) this track. Sourced from
  /// the `is_liked` flag on the GET /library response.
  final bool isLiked;
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
    this.isLiked = false,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Serializes this library track into the map shape `PlaybackState.playQueue`
  /// expects: numeric `id` for signed-URL issuance, `duration` in whole seconds.
  Map<String, dynamic> toPlaybackJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': durationMs != null ? durationMs! ~/ 1000 : 0,
        'artwork_url': metadata?['cover_art_url'],
      };

  factory Track.fromJson(Map<String, dynamic> json) {
    // Parse MB suggestions from the mb_suggestions field
    final suggestionsJson = json['mb_suggestions'] as List<dynamic>?;
    final suggestions = suggestionsJson
            ?.map((e) => MBSuggestion.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    final id = _intValue(json['id']);

    return Track(
      id: id,
      identityHash:
          _optionalString(json['identityHash'] ?? json['identity_hash']) ??
              'track-$id',
      title: json['title'] as String,
      artist: json['artist'] as String?,
      album: json['album'] as String?,
      durationMs: _optionalInt(json['durationMs'] ?? json['duration_ms']),
      version: json['version'] as String?,
      mbRecordingId: json['mbRecordingId'] as String? ??
          json['mb_recording_id'] as String?,
      mbReleaseId:
          json['mbReleaseId'] as String? ?? json['mb_release_id'] as String?,
      mbArtistId:
          json['mbArtistId'] as String? ?? json['mb_artist_id'] as String?,
      mbVerified:
          json['mbVerified'] as bool? ?? json['mb_verified'] as bool? ?? false,
      sourceUrl: json['sourceUrl'] as String? ?? json['source_url'] as String?,
      sourceType:
          json['sourceType'] as String? ?? json['source_type'] as String?,
      storageKey:
          json['storageKey'] as String? ?? json['storage_key'] as String?,
      fileSizeBytes:
          _optionalInt(json['fileSizeBytes'] ?? json['file_size_bytes']),
      metadata: json['metadata_json'] as Map<String, dynamic>?,
      mbSuggestions: suggestions,
      isLiked: json['isLiked'] as bool? ?? json['is_liked'] as bool? ?? false,
      createdAt: _dateTimeValue(json['createdAt'] ?? json['created_at']),
      updatedAt: _dateTimeValue(json['updatedAt'] ?? json['updated_at']),
    );
  }

  factory Track.fromLibraryJson(Map<String, dynamic> json) {
    final addedAt =
        DateTime.tryParse(json['added_at'] as String? ?? '') ?? DateTime.now();
    final suggestionsJson = json['mb_suggestions'] as List<dynamic>?;

    return Track(
      id: json['id'] as int,
      identityHash: json['identity_hash'] as String? ?? 'library-${json['id']}',
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
      mbSuggestions: suggestionsJson
              ?.map((e) => MBSuggestion.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      isLiked: json['is_liked'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ?? addedAt,
      updatedAt:
          DateTime.tryParse(json['updated_at'] as String? ?? '') ?? addedAt,
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
      'is_liked': isLiked,
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

  /// Returns the cover art URL from Cover Art Archive if MusicBrainz release ID is available
  String? get coverArtUrl {
    if (mbReleaseId != null && mbReleaseId!.isNotEmpty) {
      return 'https://coverartarchive.org/release/$mbReleaseId/front-250';
    }
    return null;
  }

  /// Returns the thumbnail cover art URL (smaller size for lists)
  String? get coverArtThumbnailUrl {
    if (mbReleaseId != null && mbReleaseId!.isNotEmpty) {
      return 'https://coverartarchive.org/release/$mbReleaseId/front-250';
    }
    return null;
  }

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
    bool? isLiked,
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
      isLiked: isLiked ?? this.isLiked,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

String? _optionalString(dynamic value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _intValue(dynamic value, {int fallback = 0}) =>
    _optionalInt(value) ?? fallback;

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
