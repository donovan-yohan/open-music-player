import 'dart:convert';

import '../../models/playback_payload.dart';
import '../../models/track_analysis.dart';

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

enum TrackArtworkKind {
  coverArt('cover_art'),
  releaseCover('release_cover'),
  providerThumbnail('provider_thumbnail'),
  none('none');

  const TrackArtworkKind(this.wireValue);

  final String wireValue;
}

typedef TrackArtworkDescriptor = ({String? url, TrackArtworkKind kind});

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
  final String? codec;
  final int? bitrateKbps;
  final int? sampleRateHz;
  final int? channels;
  final String? contentType;
  final Map<String, dynamic>? metadata;
  final List<MBSuggestion> mbSuggestions;
  final TrackAnalysis? analysis;
  final TrackArtworkDescriptor _artwork;
  final bool artworkDescriptorPresent;

  /// Whether the current user has liked (favorited) this track.
  ///
  /// Null means the source payload did not carry a backend `is_liked`
  /// annotation. Model construction must not turn that unknown into false.
  final bool? isLiked;
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
    this.codec,
    this.bitrateKbps,
    this.sampleRateHz,
    this.channels,
    this.contentType,
    this.metadata,
    this.mbSuggestions = const [],
    this.analysis,
    String? artworkUrl,
    TrackArtworkKind? artworkKind,
    bool? artworkDescriptorPresent,
    this.isLiked,
    required this.createdAt,
    required this.updatedAt,
  })  : _artwork = resolveTrackArtworkDescriptor(
          artworkUrl: artworkUrl,
          artworkKind: artworkKind,
          metadata: metadata,
          mbReleaseId: mbReleaseId,
        ),
        artworkDescriptorPresent =
            artworkDescriptorPresent ?? artworkKind != null;

  String? get artworkUrl => _artwork.url;
  TrackArtworkKind get artworkKind => _artwork.kind;

  /// Serializes this library track into the map shape `PlaybackState.playQueue`
  /// expects: numeric `id` for signed-URL issuance, `duration` in whole seconds.
  Map<String, dynamic> toPlaybackJson() => buildPlaybackPayload(
        id: id,
        title: title,
        artist: artist,
        album: album,
        duration: Duration(milliseconds: durationMs ?? 0),
        artworkUrl: artworkUrl,
        artworkKind: artworkKind.wireValue,
        analysis: analysis,
        isLiked: isLiked,
        sourceUrl: sourceUrl,
        codec: codec,
        bitrateKbps: bitrateKbps,
        sampleRateHz: sampleRateHz,
        channels: channels,
        contentType: contentType,
        sizeBytes: fileSizeBytes,
      );

  factory Track.fromJson(Map<String, dynamic> json) {
    // Parse MB suggestions from the mb_suggestions field
    final suggestionsJson = json['mb_suggestions'] as List<dynamic>?;
    final suggestions = suggestionsJson
            ?.map((e) => MBSuggestion.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];

    final id = _intValue(json['id']);
    final metadata = _optionalMap(json['metadata_json'] ?? json['metadata']);
    final mbReleaseId =
        _optionalString(json['mbReleaseId'] ?? json['mb_release_id']);
    final artworkKind = trackArtworkKindFromPayload(
      json,
      keys: const ['artworkKind', 'artwork_kind'],
    );

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
      mbReleaseId: mbReleaseId,
      mbArtistId:
          json['mbArtistId'] as String? ?? json['mb_artist_id'] as String?,
      mbVerified:
          json['mbVerified'] as bool? ?? json['mb_verified'] as bool? ?? false,
      sourceUrl: json['sourceUrl'] as String? ?? json['source_url'] as String?,
      sourceType:
          json['sourceType'] as String? ?? json['source_type'] as String?,
      storageKey:
          json['storageKey'] as String? ?? json['storage_key'] as String?,
      fileSizeBytes: _optionalInt(
        json['fileSizeBytes'] ??
            json['file_size_bytes'] ??
            json['sizeBytes'] ??
            json['size'],
      ),
      codec: _optionalString(json['codec']),
      bitrateKbps: _optionalInt(
        json['bitrateKbps'] ?? json['bitrate_kbps'] ?? json['bitRate'],
      ),
      sampleRateHz: _optionalInt(
        json['sampleRateHz'] ?? json['sample_rate_hz'] ?? json['samplingRate'],
      ),
      channels: _optionalInt(json['channels'] ?? json['channelCount']),
      contentType: _optionalString(json['contentType'] ?? json['content_type']),
      metadata: metadata,
      mbSuggestions: suggestions,
      analysis: trackAnalysisFromTrackJson(json),
      artworkUrl: _optionalString(
        json['artworkUrl'] ??
            json['artwork_url'] ??
            json['coverArtUrl'] ??
            json['cover_art_url'],
      ),
      artworkKind: artworkKind,
      isLiked: json['isLiked'] as bool? ?? json['is_liked'] as bool?,
      createdAt: _dateTimeValue(json['createdAt'] ?? json['created_at']),
      updatedAt: _dateTimeValue(json['updatedAt'] ?? json['updated_at']),
    );
  }

  factory Track.fromLibraryJson(Map<String, dynamic> json) {
    final addedAt =
        DateTime.tryParse(json['added_at'] as String? ?? '') ?? DateTime.now();
    final suggestionsJson = json['mb_suggestions'] as List<dynamic>?;
    final metadata = _optionalMap(json['metadata_json'] ?? json['metadata']);
    final artworkKind = trackArtworkKindFromPayload(
      json,
      keys: const ['artwork_kind', 'artworkKind'],
    );

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
      fileSizeBytes: _optionalInt(
        json['file_size_bytes'] ??
            json['fileSizeBytes'] ??
            json['sizeBytes'] ??
            json['size'],
      ),
      codec: _optionalString(json['codec']),
      bitrateKbps: _optionalInt(
        json['bitrate_kbps'] ?? json['bitrateKbps'] ?? json['bitRate'],
      ),
      sampleRateHz: _optionalInt(
        json['sample_rate_hz'] ?? json['sampleRateHz'] ?? json['samplingRate'],
      ),
      channels: _optionalInt(json['channels'] ?? json['channelCount']),
      contentType: _optionalString(json['content_type'] ?? json['contentType']),
      metadata: metadata,
      mbSuggestions: suggestionsJson
              ?.map((e) => MBSuggestion.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      analysis: trackAnalysisFromTrackJson(json),
      artworkUrl: _optionalString(
        json['artwork_url'] ??
            json['artworkUrl'] ??
            json['cover_art_url'] ??
            json['coverArtUrl'],
      ),
      artworkKind: artworkKind,
      isLiked: json['is_liked'] as bool?,
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
      'codec': codec,
      'bitrate_kbps': bitrateKbps,
      'sample_rate_hz': sampleRateHz,
      'channels': channels,
      'content_type': contentType,
      'metadata_json': metadata,
      if (artworkDescriptorPresent && artworkUrl != null)
        'artwork_url': artworkUrl,
      if (artworkDescriptorPresent) 'artwork_kind': artworkKind.wireValue,
      if (!artworkDescriptorPresent && coverArtUrl != null)
        'cover_art_url': coverArtUrl,
      'mb_suggestions': mbSuggestions.map((s) => s.toJson()).toList(),
      ...trackAnalysisFields(
        analysis,
        fieldStyle: TrackAnalysisFieldStyle.snakeCase,
      ),
      if (isLiked != null) 'is_liked': isLiked,
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
      'artwork_url': artworkUrl,
      'artwork_kind': artworkKind.wireValue,
      'artwork_descriptor_present': artworkDescriptorPresent ? 1 : 0,
      ...trackAnalysisFields(
        analysis,
        fieldStyle: TrackAnalysisFieldStyle.snakeCase,
        summarySerializer: (summary) =>
            jsonEncode(_compactAnalysisSummaryJson(summary)),
        overridesSerializer: (overrides) =>
            jsonEncode(overrides?.toJson() ?? const <String, dynamic>{}),
        includeUpdatedAtMicros: true,
      ),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Track.fromDbMap(Map<String, dynamic> map) {
    final artworkDescriptorPresent =
        (map['artwork_descriptor_present'] as num?)?.toInt() == 1;
    final artworkUrl = _optionalString(map['artwork_url']);
    final storedArtworkKind = _parsedArtworkKind(map['artwork_kind']);
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
      artworkUrl: artworkUrl,
      artworkKind: artworkDescriptorPresent || artworkUrl != null
          ? storedArtworkKind
          : null,
      artworkDescriptorPresent: artworkDescriptorPresent,
      analysis: trackAnalysisFromTrackJson(_analysisJsonFromDbMap(map)),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  String get displayArtist => artist ?? 'Unknown Artist';
  String get displayAlbum => album ?? 'Unknown Album';

  /// The one resolved remote visual used by Home, Library, playback and cache.
  String? get displayArtworkUrl => artworkUrl;

  /// Legacy album-art accessor. Provider thumbnails remain available through
  /// [displayArtworkUrl] but are not represented as verified cover art.
  String? get coverArtUrl => artworkKind == TrackArtworkKind.coverArt ||
          artworkKind == TrackArtworkKind.releaseCover
      ? artworkUrl
      : null;

  /// Legacy list accessor with the same provenance-safe semantics.
  String? get coverArtThumbnailUrl => coverArtUrl;

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
    String? codec,
    int? bitrateKbps,
    int? sampleRateHz,
    int? channels,
    String? contentType,
    Map<String, dynamic>? metadata,
    List<MBSuggestion>? mbSuggestions,
    TrackAnalysis? analysis,
    String? artworkUrl,
    TrackArtworkKind? artworkKind,
    bool? artworkDescriptorPresent,
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
      codec: codec ?? this.codec,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      channels: channels ?? this.channels,
      contentType: contentType ?? this.contentType,
      metadata: metadata ?? this.metadata,
      mbSuggestions: mbSuggestions ?? this.mbSuggestions,
      analysis: analysis ?? this.analysis,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      artworkKind: artworkKind ?? this.artworkKind,
      artworkDescriptorPresent: artworkDescriptorPresent ??
          (artworkKind != null ? true : this.artworkDescriptorPresent),
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

Map<String, dynamic>? _optionalMap(dynamic value) {
  if (value is! Map) return null;
  return Map<String, dynamic>.from(value);
}

TrackArtworkKind? parseTrackArtworkKind(dynamic value) {
  final normalized = _optionalString(value)?.toLowerCase();
  for (final kind in TrackArtworkKind.values) {
    if (kind.wireValue == normalized) return kind;
  }
  return null;
}

TrackArtworkKind? _parsedArtworkKind(dynamic value) {
  if (value == null) return null;
  return parseTrackArtworkKind(value) ?? TrackArtworkKind.none;
}

TrackArtworkKind? trackArtworkKindFromPayload(
  Map<String, dynamic>? json, {
  Iterable<String> keys = const ['artworkKind', 'artwork_kind'],
}) {
  if (json == null) return null;
  for (final key in keys) {
    if (json.containsKey(key)) {
      return parseTrackArtworkKind(json[key]) ?? TrackArtworkKind.none;
    }
  }
  return null;
}

TrackArtworkDescriptor resolveTrackArtworkDescriptor({
  required String? artworkUrl,
  required TrackArtworkKind? artworkKind,
  required Map<String, dynamic>? metadata,
  required String? mbReleaseId,
}) {
  final explicitURL = safeTrackArtworkUrl(artworkUrl);
  if (artworkKind != null) {
    if (artworkKind == TrackArtworkKind.none) {
      return (url: null, kind: TrackArtworkKind.none);
    }
    if (explicitURL != null) {
      return (url: explicitURL, kind: artworkKind);
    }
    return _releaseArtwork(mbReleaseId);
  }

  final legacyURL =
      explicitURL ?? safeTrackArtworkUrl(metadata?['cover_art_url']);
  if (legacyURL != null) {
    return (
      url: legacyURL,
      kind: _looksLikeReleaseCover(legacyURL, mbReleaseId)
          ? TrackArtworkKind.releaseCover
          : TrackArtworkKind.coverArt,
    );
  }
  return _releaseArtwork(mbReleaseId);
}

({String? url, TrackArtworkKind kind}) _releaseArtwork(String? mbReleaseId) {
  final url = _releaseArtworkUrl(mbReleaseId);
  return (
    url: url,
    kind: url == null ? TrackArtworkKind.none : TrackArtworkKind.releaseCover,
  );
}

String? safeTrackArtworkUrl(dynamic value) {
  final candidate = _optionalString(value);
  if (candidate == null) return null;
  final uri = Uri.tryParse(candidate);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return candidate;
}

String? _releaseArtworkUrl(String? mbReleaseId) {
  final releaseID = _optionalString(mbReleaseId);
  if (releaseID == null) return null;
  return 'https://coverartarchive.org/release/$releaseID/front-250';
}

bool _looksLikeReleaseCover(String candidate, String? mbReleaseId) {
  final releaseURL = _releaseArtworkUrl(mbReleaseId);
  if (releaseURL != null && candidate == releaseURL) return true;
  final uri = Uri.tryParse(candidate);
  return uri?.host.toLowerCase() == 'coverartarchive.org' &&
      uri!.path.startsWith('/release/');
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

Object? _decodeJsonColumn(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is! String || value.trim().isEmpty) return null;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

Map<String, dynamic> _analysisJsonFromDbMap(Map<String, dynamic> map) {
  final summary = _decodeJsonColumn(map['analysis_summary']);
  final overrides = _decodeJsonColumn(map['analysis_overrides']);
  return {
    if (map['analysis_status'] != null)
      'analysis_status': map['analysis_status'],
    if (summary != null) 'analysis_summary': summary,
    if (overrides != null) 'analysis_overrides': overrides,
    if (map['analysis_updated_at'] != null)
      'analysis_updated_at': map['analysis_updated_at'],
  };
}

Map<String, dynamic> _compactAnalysisSummaryJson(TrackAnalysisSummary summary) {
  final json = summary.toJson();
  return {
    for (final key in const [
      'bpm',
      'beat_grid',
      'downbeats',
      'key',
      'camelot',
      'energy',
    ])
      if (json[key] != null) key: json[key],
  };
}
