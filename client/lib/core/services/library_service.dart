import '../../shared/models/track.dart';
import 'api_client.dart';

class LibraryService {
  final ApiClient _apiClient;

  LibraryService(this._apiClient);

  /// Projection used by the paged Library screen.
  static const libraryListFields = [
    'id',
    'title',
    'artist',
    'album',
    'duration_ms',
    'mb_verified',
    'added_at',
    'cover_art_url',
    'mb_recording_id',
    'mb_suggestions',
    'source_url',
    'file_size_bytes',
    'codec',
    'bitrate_kbps',
    'sample_rate_hz',
    'channels',
    'content_type',
    'is_liked',
    'analysis_status',
    'analysis_summary',
    'analysis_updated_at',
  ];

  /// Loads every library track whose `artist` exactly matches [artist], via the
  /// `GET /library?artist=` filter. Parses the `{tracks, total, ...}` envelope
  /// into shared [Track]s. [limit] is generous so an artist's full local
  /// catalogue arrives in one page.
  Future<List<Track>> getLibraryByArtist(
    String artist, {
    int limit = 500,
  }) async {
    return _apiClient.get<List<Track>>(
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
  Future<List<Track>> getLibraryByAlbum(
    String album, {
    int limit = 500,
  }) async {
    return _apiClient.get<List<Track>>(
      '/library',
      queryParams: {
        'album': album,
        'limit': limit.toString(),
      },
      parser: _parseLibraryTracks,
    );
  }

  /// Loads one page of the library list via `GET /library`, forwarding paging
  /// plus the optional `sort=`/`order=` ordering and the `mb_verified` /
  /// `fields` projection the Library screen relies on. Returns the parsed
  /// tracks alongside the envelope's `total` so callers can drive infinite
  /// scroll.
  Future<({List<Track> tracks, int total})> getLibraryPage({
    int limit = 20,
    int offset = 0,
    String? sort,
    String? order,
    bool? mbVerified,
    List<String>? fields,
    bool liked = false,
    String? genre,
    String? query,
  }) async {
    final trimmedQuery = query?.trim();
    final params = <String, String>{
      'limit': limit.toString(),
      'offset': offset.toString(),
      if (sort != null) 'sort': sort,
      if (order != null) 'order': order,
      if (mbVerified != null) 'mb_verified': mbVerified.toString(),
      if (fields != null && fields.isNotEmpty) 'fields': fields.join(','),
      if (liked) 'liked': 'true',
      if (genre != null && genre.isNotEmpty) 'genre': genre,
      if (trimmedQuery != null && trimmedQuery.isNotEmpty) 'q': trimmedQuery,
    };
    return _apiClient.get<({List<Track> tracks, int total})>(
      '/library',
      queryParams: params,
      parser: (json) {
        final tracks = _parseLibraryTracks(json);
        final total = json['total'] as int? ?? tracks.length;
        return (tracks: tracks, total: total);
      },
    );
  }

  /// Loads the caller's Liked Songs collection via `GET /library?liked=true`,
  /// ordered newest-liked-first by default. Thin convenience over
  /// [getLibraryPage] so the Liked Songs screen doesn't have to remember the
  /// `liked` flag or the projection it needs to render + play rows.
  Future<({List<Track> tracks, int total})> getLikedSongs({
    int limit = 200,
    int offset = 0,
    String? sort,
    String? order,
  }) {
    return getLibraryPage(
      limit: limit,
      offset: offset,
      sort: sort,
      order: order,
      liked: true,
      fields: const [
        'id',
        'title',
        'artist',
        'album',
        'duration_ms',
        'mb_verified',
        'added_at',
        'cover_art_url',
        'mb_recording_id',
        'source_url',
        'file_size_bytes',
        'codec',
        'bitrate_kbps',
        'sample_rate_hz',
        'channels',
        'content_type',
        'is_liked',
        'analysis_status',
        'analysis_summary',
        'analysis_updated_at',
      ],
    );
  }

  /// Parses the `{tracks: [...], total, limit, offset}` library envelope into
  /// shared [Track]s, tolerating a missing/empty `tracks` list.
  List<Track> _parseLibraryTracks(Map<String, dynamic> json) {
    final tracks = json['tracks'] as List<dynamic>? ?? const <dynamic>[];
    return tracks
        .map((t) => Track.fromLibraryJson(t as Map<String, dynamic>))
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

  /// Likes (favorites) a library track. Idempotent server-side.
  Future<void> like(int trackId) async {
    await _apiClient.post('/library/tracks/$trackId/like');
  }

  /// Removes the like (favorite) from a library track.
  Future<void> unlike(int trackId) async {
    await _apiClient.delete('/library/tracks/$trackId/like');
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
