import '../api/api_client.dart';
import '../../shared/models/playlist.dart';

class PlaylistsResponse {
  final List<Playlist> playlists;
  final int total;
  final int offset;
  final int limit;

  const PlaylistsResponse({
    required this.playlists,
    required this.total,
    required this.offset,
    required this.limit,
  });

  bool get hasMore => offset + playlists.length < total;
}

/// Result of adding tracks to a playlist, mirroring the backend's
/// {added, skipped, playlist} report so callers can surface duplicate
/// ("Already in this playlist") feedback.
class AddTracksResult {
  final List<int> added;
  final List<int> skipped;
  final Playlist? playlist;

  const AddTracksResult({
    required this.added,
    required this.skipped,
    this.playlist,
  });

  bool get hasSkipped => skipped.isNotEmpty;
  bool get hasAdded => added.isNotEmpty;

  /// Feedback for the user after an add attempt. Surfaces the duplicate case
  /// ("Already in this playlist") when the backend skipped every track.
  String feedbackMessage(String playlistName) {
    if (added.isEmpty && skipped.isNotEmpty) {
      return skipped.length == 1
          ? 'Already in this playlist'
          : 'Already in "$playlistName"';
    }
    if (skipped.isNotEmpty) {
      return 'Added ${added.length} • ${skipped.length} already in "$playlistName"';
    }
    return added.length == 1
        ? 'Added to "$playlistName"'
        : 'Added ${added.length} tracks to "$playlistName"';
  }

  factory AddTracksResult.fromJson(Map<String, dynamic> json) {
    final playlistJson = json['playlist'];
    return AddTracksResult(
      added: _intList(json['added']),
      skipped: _intList(json['skipped']),
      playlist: playlistJson is Map<String, dynamic>
          ? Playlist.fromJson(playlistJson)
          : null,
    );
  }
}

List<int> _intList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((e) {
        if (e is int) return e;
        if (e is num) return e.toInt();
        if (e is String) return int.tryParse(e);
        return null;
      })
      .whereType<int>()
      .toList();
}

class PlaylistService {
  final ApiClient _api;

  PlaylistService({required ApiClient api}) : _api = api;

  Future<PlaylistsResponse> getPlaylists({
    int limit = 50,
    int offset = 0,
    String? q,
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{'limit': limit, 'offset': offset};
    if (q != null && q.trim().isNotEmpty) query['q'] = q.trim();
    if (sort != null && sort.isNotEmpty) query['sort'] = sort;
    if (order != null && order.isNotEmpty) query['order'] = order;

    final response = await _api.get<Map<String, dynamic>>(
      '/playlists',
      queryParameters: query,
    );

    final data = response.data!;
    final playlistsJson =
        data['playlists'] as List? ?? data['data'] as List? ?? [];
    final playlists = playlistsJson.map((p) => Playlist.fromJson(p)).toList();

    return PlaylistsResponse(
      playlists: playlists,
      total: data['total'] as int? ?? playlists.length,
      offset: data['offset'] as int? ?? offset,
      limit: data['limit'] as int? ?? limit,
    );
  }

  Future<Playlist> getPlaylist(int id) async {
    final response = await _api.get<Map<String, dynamic>>('/playlists/$id');
    return Playlist.fromJson(response.data!);
  }

  Future<Playlist> createPlaylist({
    required String name,
    String? description,
    String? coverUrl,
    bool? isPublic,
  }) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/playlists',
      data: {
        'name': name,
        if (description != null && description.isNotEmpty)
          'description': description,
        if (coverUrl != null && coverUrl.isNotEmpty) 'coverUrl': coverUrl,
        if (isPublic != null) 'isPublic': isPublic,
      },
    );
    return Playlist.fromJson(response.data!);
  }

  Future<Playlist> updatePlaylist(
    int id, {
    String? name,
    String? description,
    String? coverUrl,
    bool? isPublic,
  }) async {
    final response = await _api.put<Map<String, dynamic>>(
      '/playlists/$id',
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (isPublic != null) 'isPublic': isPublic,
      },
    );
    return Playlist.fromJson(response.data!);
  }

  Future<void> deletePlaylist(int id) async {
    await _api.delete('/playlists/$id');
  }

  /// Adds [trackIds] and returns the backend's added/skipped report so callers
  /// can show duplicate feedback ("Already in this playlist").
  Future<AddTracksResult> addTracks(int playlistId, List<int> trackIds) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/playlists/$playlistId/tracks',
      data: {'trackIds': trackIds},
    );
    final data = response.data;
    if (data == null) {
      return AddTracksResult(added: trackIds, skipped: const []);
    }
    return AddTracksResult.fromJson(data);
  }

  Future<void> removeTrack(int playlistId, int trackId) async {
    await _api.delete('/playlists/$playlistId/tracks/$trackId');
  }

  /// Removes [trackIds] in a single POST /playlists/{id}/tracks/batch-remove
  /// call and returns the updated playlist.
  Future<Playlist> batchRemoveTracks(
    int playlistId,
    List<int> trackIds,
  ) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/playlists/$playlistId/tracks/batch-remove',
      data: {'trackIds': trackIds},
    );
    return Playlist.fromJson(response.data!);
  }

  Future<void> reorderTrack(
    int playlistId, {
    required int trackId,
    required int newPosition,
  }) async {
    await _api.put(
      '/playlists/$playlistId/tracks/reorder',
      data: {
        'trackId': trackId,
        'newPosition': newPosition,
      },
    );
  }
}
