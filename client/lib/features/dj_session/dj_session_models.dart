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
  const DjLineup({required this.requested, required this.blocks});

  final Map<String, dynamic> requested;
  final List<DjLineupBlock> blocks;

  factory DjLineup.fromJson(Map<String, dynamic> json) {
    final requested = json['requested'];
    final rawBlocks = json['blocks'];
    return DjLineup(
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
  });

  final String id;
  final String title;
  final String reason;
  final List<DjLineupTrack> tracks;

  factory DjLineupBlock.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'];
    return DjLineupBlock(
      id: _stringValue(json['id']),
      title: _stringValue(json['title']),
      reason: _stringValue(json['reason']),
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
