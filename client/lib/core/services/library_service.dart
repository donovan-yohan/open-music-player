import '../models/models.dart';
import '../../shared/models/track.dart' as lib;
import 'api_client.dart';

class LibraryService {
  final ApiClient _apiClient;

  LibraryService(this._apiClient);

  /// Loads every library track whose `artist` exactly matches [artist], via the
  /// `GET /library?artist=` filter. Parses the `{tracks, total, ...}` envelope
  /// into shared [lib.Track]s. [limit] is generous so an artist's full local
  /// catalogue arrives in one page.
  Future<List<lib.Track>> getLibraryByArtist(
    String artist, {
    int limit = 500,
  }) async {
    return _apiClient.get<List<lib.Track>>(
      '/library',
      queryParams: {
        'artist': artist,
        'limit': limit.toString(),
      },
      parser: _parseLibraryTracks,
    );
  }

  /// Loads every library track whose `album` exactly matches [album], via the
  /// `GET /library?album=` filter. See [getLibraryByArtist] for the parsing
  /// contract.
  Future<List<lib.Track>> getLibraryByAlbum(
    String album, {
    int limit = 500,
  }) async {
    return _apiClient.get<List<lib.Track>>(
      '/library',
      queryParams: {
        'album': album,
        'limit': limit.toString(),
      },
      parser: _parseLibraryTracks,
    );
  }

  /// Parses the `{tracks: [...], total, limit, offset}` library envelope into
  /// shared [lib.Track]s, tolerating a missing/empty `tracks` list.
  List<lib.Track> _parseLibraryTracks(Map<String, dynamic> json) {
    final tracks = json['tracks'] as List<dynamic>? ?? const <dynamic>[];
    return tracks
        .map((t) => lib.Track.fromLibraryJson(t as Map<String, dynamic>))
        .toList();
  }

  Future<void> addTrackToLibrary(String mbid) async {
    await _apiClient.post(
      '/library/tracks',
      body: {'mbid': mbid},
    );
  }

  Future<void> removeTrackFromLibrary(String trackId) async {
    await _apiClient.delete('/library/tracks/$trackId');
  }

  Future<List<Playlist>> getPlaylists({int limit = 20, int offset = 0}) async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/playlists',
      queryParams: {
        'limit': limit.toString(),
        'offset': offset.toString(),
      },
    );
    return (response['playlists'] as List<dynamic>)
        .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    await _apiClient.post(
      '/playlists/$playlistId/tracks',
      body: {
        'trackIds': [trackId]
      },
    );
  }

  /// Confirms a MusicBrainz match suggestion for a track
  Future<void> confirmMatchSuggestion({
    required int trackId,
    required String recordingMbid,
    String? artistMbid,
    String? releaseMbid,
  }) async {
    await _apiClient.post(
      '/tracks/$trackId/confirm-match',
      body: {
        'recordingMbid': recordingMbid,
        if (artistMbid != null) 'artistMbid': artistMbid,
        if (releaseMbid != null) 'releaseMbid': releaseMbid,
      },
    );
  }

  /// Triggers a re-match for an unverified track
  Future<Map<String, dynamic>> rematchTrack(int trackId) async {
    return await _apiClient.post<Map<String, dynamic>>(
      '/tracks/$trackId/match',
    );
  }
}
