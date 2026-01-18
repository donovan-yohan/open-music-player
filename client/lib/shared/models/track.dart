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
    required this.createdAt,
    required this.updatedAt,
  });

  factory Track.fromJson(Map<String, dynamic> json) {
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
}
