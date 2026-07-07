import '../../shared/models/models.dart';
import 'api_client.dart';

class ListeningHistoryEntry {
  const ListeningHistoryEntry({
    required this.id,
    required this.track,
    required this.playedAt,
    this.contextType,
    this.contextId,
  });

  final int id;
  final Track track;
  final DateTime playedAt;
  final String? contextType;
  final String? contextId;

  factory ListeningHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ListeningHistoryEntry(
      id: _intValue(json['id']),
      track: HomeService.trackFromPlayEvent(
        json['track'] as Map<String, dynamic>,
      ),
      playedAt: DateTime.tryParse(json['playedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      contextType: json['contextType'] as String?,
      contextId: json['contextId'] as String?,
    );
  }
}

/// Backs the Home screen. Wraps the parser-based [ApiClient] and turns the
/// play-history + playlists endpoints into the shared [Track] / [Playlist]
/// models the UI already knows how to render and play.
class HomeService {
  final ApiClient _apiClient;

  HomeService(this._apiClient);

  /// GET /me/plays/recent - the user's most recently played tracks, newest
  /// first.
  Future<List<Track>> recentlyPlayed({int limit = 20}) {
    return _apiClient.get<List<Track>>(
      '/me/plays/recent',
      queryParams: {'limit': limit.toString()},
      parser: _parseTracks,
    );
  }

  /// GET /me/plays/history - raw, chronological listening history. Unlike the
  /// Home recently-played feed, repeated plays of the same track are preserved.
  Future<List<ListeningHistoryEntry>> listeningHistory({
    int limit = 50,
    int offset = 0,
  }) {
    return _apiClient.get<List<ListeningHistoryEntry>>(
      '/me/plays/history',
      queryParams: {
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
      parser: _parseHistory,
    );
  }

  /// GET /me/plays/top - the user's most played tracks over the last [days].
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) {
    return _apiClient.get<List<Track>>(
      '/me/plays/top',
      queryParams: {
        'days': days.toString(),
        'limit': limit.toString(),
      },
      parser: _parseTracks,
    );
  }

  /// GET /playlists - reuse the existing playlists listing shape.
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) {
    return _apiClient.get<List<Playlist>>(
      '/playlists',
      queryParams: {
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
      parser: (json) {
        final list =
            (json['playlists'] ?? json['data']) as List<dynamic>? ?? const [];
        return list
            .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
            .toList();
      },
    );
  }

  static List<Track> _parseTracks(Map<String, dynamic> json) {
    final list = json['tracks'] as List<dynamic>? ?? const [];
    return list
        .map((e) => trackFromPlayEvent(e as Map<String, dynamic>))
        .toList();
  }

  static List<ListeningHistoryEntry> _parseHistory(Map<String, dynamic> json) {
    final list = json['plays'] as List<dynamic>? ?? const [];
    return list
        .map((e) => ListeningHistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// The play-history endpoints return `coverArtUrl` as a flat field, but the
  /// shared [Track] only knows how to read cover art out of `metadata_json`.
  /// Fold it in so both the tile artwork and `toPlaybackJson`'s `artwork_url`
  /// carry the cover through.
  static Track trackFromPlayEvent(Map<String, dynamic> json) {
    final cover = json['coverArtUrl'] ?? json['cover_art_url'];
    if (cover is String && cover.isNotEmpty) {
      return Track.fromJson({
        ...json,
        'metadata_json': {
          ...?(json['metadata_json'] as Map<String, dynamic>?),
          'cover_art_url': cover,
        },
      });
    }
    return Track.fromJson(json);
  }
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
