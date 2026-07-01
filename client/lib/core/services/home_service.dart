import '../../shared/models/models.dart';
import 'api_client.dart';

/// Backs the Home screen. Wraps the parser-based [ApiClient] and turns the
/// play-history + playlists endpoints into the shared [Track] / [Playlist]
/// models the UI already knows how to render and play.
class HomeService {
  final ApiClient _apiClient;

  HomeService(this._apiClient);

  /// GET /me/plays/recent — the user's most recently played tracks, newest
  /// first.
  Future<List<Track>> recentlyPlayed({int limit = 20}) {
    return _apiClient.get<List<Track>>(
      '/me/plays/recent',
      queryParams: {'limit': limit.toString()},
      parser: _parseTracks,
    );
  }

  /// GET /me/plays/top — the user's most played tracks over the last [days].
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

  /// GET /playlists — reuse the existing playlists listing shape.
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
        .map((e) => _trackFromPlayEvent(e as Map<String, dynamic>))
        .toList();
  }

  /// The play-history endpoints return `coverArtUrl` as a flat field, but the
  /// shared [Track] only knows how to read cover art out of `metadata_json`.
  /// Fold it in so both the tile artwork and `toPlaybackJson`'s `artwork_url`
  /// carry the cover through.
  static Track _trackFromPlayEvent(Map<String, dynamic> json) {
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
