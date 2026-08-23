import 'dj_session_filters.dart';

class DjLineupRequest {
  const DjLineupRequest({
    this.blocks,
    this.perBlock,
    this.energy,
    this.genre,
    this.eraStart,
    this.eraEnd,
    this.query,
    this.seed,
    this.excludeIds = const [],
    this.block,
  });

  final int? blocks;
  final int? perBlock;
  final DjEnergy? energy;
  final String? genre;
  final int? eraStart;
  final int? eraEnd;
  final String? query;
  final int? seed;
  final List<int> excludeIds;
  final String? block;

  Map<String, dynamic> toQueryParameters() => {
        if (blocks != null) 'blocks': blocks,
        if (perBlock != null) 'perBlock': perBlock,
        if (energy != null) 'energy': energy!.wireValue,
        if (genre != null && genre!.isNotEmpty) 'genre': genre,
        if (eraStart != null) 'eraStart': eraStart,
        if (eraEnd != null) 'eraEnd': eraEnd,
        if (query != null && query!.isNotEmpty) 'q': query,
        if (seed != null) 'seed': seed,
        if (excludeIds.isNotEmpty) 'excludeIds': excludeIds.join(','),
        if (block != null && block!.isNotEmpty) 'block': block,
      };
}

class DjLineup {
  const DjLineup({
    required this.requested,
    required this.blocks,
    this.pinnedBlockId,
  });

  final Map<String, dynamic> requested;
  final List<DjLineupBlock> blocks;

  /// Block id of the active vibe pin, mirrored by the server in every lineup
  /// response while a pin exists. Null when nothing is pinned.
  final String? pinnedBlockId;

  factory DjLineup.fromJson(Map<String, dynamic> json) {
    final requested = json['requested'];
    final rawBlocks = json['blocks'];
    final pinned = json['pinned'];
    return DjLineup(
      pinnedBlockId: pinned is Map
          ? _stringValue(pinned['blockId'])
          : null,
      requested: requested is Map
          ? Map<String, dynamic>.from(requested)
          : const <String, dynamic>{},
      blocks: rawBlocks is List
          ? rawBlocks
              .whereType<Map>()
              .map((block) => DjLineupBlock.fromJson(
                    Map<String, dynamic>.from(block),
                  ))
              .toList(growable: false)
          : const [],
    );
  }
}

class DjLineupBlock {
  const DjLineupBlock({
    required this.id,
    required this.title,
    required this.reason,
    required this.tracks,
    this.detail = '',
  });

  final String id;
  final String title;
  final String reason;
  final List<DjLineupTrack> tracks;

  /// Optional data-derived secondary line (e.g. "23 plays in the last 90
  /// days"). Empty when the backend omits it, so callers can hide it.
  final String detail;

  factory DjLineupBlock.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'];
    return DjLineupBlock(
      id: _stringValue(json['id']),
      title: _stringValue(json['title']),
      reason: _stringValue(json['reason']),
      detail: _stringValue(json['detail']),
      tracks: rawTracks is List
          ? rawTracks
              .whereType<Map>()
              .map((track) => DjLineupTrack.fromJson(
                    Map<String, dynamic>.from(track),
                  ))
              .toList(growable: false)
          : const [],
    );
  }
}

class DjLineupTrack {
  const DjLineupTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.bpm,
    this.camelot,
    this.energy,
    this.artworkUrl,
  });

  final int id;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;
  final double? bpm;
  final String? camelot;
  final double? energy;
  final String? artworkUrl;

  factory DjLineupTrack.fromJson(Map<String, dynamic> json) {
    return DjLineupTrack(
      id: _intValue(json['id']),
      title: _stringValue(json['title']),
      artist: _stringValue(json['artist']),
      album: _nullableString(json['album']),
      durationMs: _nullableInt(json['durationMs'] ?? json['duration_ms']),
      bpm: _nullableDouble(json['bpm']),
      camelot: _nullableString(json['camelot']),
      energy: _nullableDouble(json['energy']),
      artworkUrl: _nullableString(json['artworkUrl'] ?? json['artwork_url']),
    );
  }

  List<String> get djMeta => [
        if (bpm != null) '${bpm!.round()} BPM',
        if (camelot != null && camelot!.isNotEmpty) camelot!,
        if (energy != null) '${(energy! * 100).round()}%',
      ];
}

/// The active lineup pin as returned by GET/POST /dj/pin.
class DjPin {
  const DjPin({
    required this.blockId,
    required this.energyLow,
    required this.energyHigh,
    required this.genres,
    required this.expiresAt,
  });

  final String blockId;
  final double energyLow;
  final double energyHigh;
  final List<String> genres;
  final DateTime? expiresAt;

  factory DjPin.fromJson(Map<String, dynamic> json) {
    final rawGenres = json['genres'];
    return DjPin(
      blockId: _stringValue(json['blockId']),
      energyLow: _nullableDouble(json['energyLow']) ?? 0,
      energyHigh: _nullableDouble(json['energyHigh']) ?? 0,
      genres: rawGenres is List
          ? rawGenres.map(_stringValue).toList(growable: false)
          : const [],
      expiresAt: json['expiresAt'] is String
          ? DateTime.tryParse(json['expiresAt'] as String)
          : null,
    );
  }
}

int _intValue(Object? value) => _nullableInt(value) ?? 0;

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return value is String ? int.tryParse(value) : null;
}

double? _nullableDouble(Object? value) {
  if (value is num) return value.toDouble();
  return value is String ? double.tryParse(value) : null;
}

String _stringValue(Object? value) => value is String ? value : '';

String? _nullableString(Object? value) => value is String ? value : null;
