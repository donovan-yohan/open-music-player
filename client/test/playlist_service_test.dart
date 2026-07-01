import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/token_storage_backend.dart';

/// Captures the method/path/query/body dio was asked to send and returns a
/// canned JSON body, so we can assert routing + params without a real HTTP
/// call (mirrors the capturing-ApiClient pattern used elsewhere).
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.reply);

  final Map<String, dynamic> reply;
  RequestOptions? captured;
  Object? capturedBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    capturedBody = options.data;
    return ResponseBody.fromString(
      jsonEncode(reply),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

PlaylistService _service(_CapturingAdapter adapter) {
  final api = ApiClient(
    storage: SecureStorage(tokenStorage: _MemoryTokenStorage()),
    dio: Dio()..httpClientAdapter = adapter,
  );
  return PlaylistService(api: api);
}

Map<String, dynamic> _playlistJson({
  int id = 1,
  int trackCount = 0,
}) =>
    {
      'id': id,
      'name': 'Road trip',
      'coverUrl': 'http://x/cover.jpg',
      'isPublic': true,
      'trackCount': trackCount,
      'durationMs': 0,
      'createdAt': '2026-06-29T01:59:00Z',
      'updatedAt': '2026-06-29T01:59:01Z',
    };

void main() {
  group('getPlaylists routes q/sort/order', () {
    test('forwards q/sort/order query params', () async {
      final adapter = _CapturingAdapter({
        'data': [_playlistJson()],
        'total': 1,
        'limit': 50,
        'offset': 0,
      });

      await _service(adapter).getPlaylists(
        q: '  chill  ',
        sort: 'track_count',
        order: 'desc',
      );

      final query = adapter.captured!.uri.queryParameters;
      expect(adapter.captured!.method, 'GET');
      expect(adapter.captured!.uri.path, endsWith('/playlists'));
      expect(query['q'], 'chill'); // trimmed
      expect(query['sort'], 'track_count');
      expect(query['order'], 'desc');
    });

    test('omits blank q', () async {
      final adapter = _CapturingAdapter({
        'data': <Map<String, dynamic>>[],
        'total': 0,
        'limit': 50,
        'offset': 0,
      });

      await _service(adapter).getPlaylists(q: '   ');

      expect(adapter.captured!.uri.queryParameters.containsKey('q'), isFalse);
    });
  });

  group('create/update send coverUrl + isPublic', () {
    test('createPlaylist includes coverUrl and isPublic', () async {
      final adapter = _CapturingAdapter(_playlistJson());

      await _service(adapter).createPlaylist(
        name: 'Road trip',
        coverUrl: 'http://x/cover.jpg',
        isPublic: true,
      );

      final body = adapter.capturedBody as Map<String, dynamic>;
      expect(adapter.captured!.method, 'POST');
      expect(adapter.captured!.uri.path, endsWith('/playlists'));
      expect(body['name'], 'Road trip');
      expect(body['coverUrl'], 'http://x/cover.jpg');
      expect(body['isPublic'], true);
    });

    test('updatePlaylist includes coverUrl and isPublic', () async {
      final adapter = _CapturingAdapter(_playlistJson());

      await _service(adapter).updatePlaylist(
        7,
        name: 'Renamed',
        coverUrl: '',
        isPublic: false,
      );

      final body = adapter.capturedBody as Map<String, dynamic>;
      expect(adapter.captured!.method, 'PUT');
      expect(adapter.captured!.uri.path, endsWith('/playlists/7'));
      expect(body['coverUrl'], '');
      expect(body['isPublic'], false);
    });
  });

  group('addTracks / batchRemove', () {
    test('addTracks POSTs trackIds and parses added/skipped report', () async {
      final adapter = _CapturingAdapter({
        'added': [10],
        'skipped': [11],
        'playlist': _playlistJson(trackCount: 2),
      });

      final result = await _service(adapter).addTracks(3, [10, 11]);

      final body = adapter.capturedBody as Map<String, dynamic>;
      expect(adapter.captured!.method, 'POST');
      expect(adapter.captured!.uri.path, endsWith('/playlists/3/tracks'));
      expect(body['trackIds'], [10, 11]);
      expect(result.added, [10]);
      expect(result.skipped, [11]);
      expect(result.playlist?.trackCount, 2);
    });

    test('batchRemoveTracks hits the batch-remove endpoint once', () async {
      final adapter = _CapturingAdapter(_playlistJson(trackCount: 1));

      final updated = await _service(adapter).batchRemoveTracks(5, [1, 2, 3]);

      final body = adapter.capturedBody as Map<String, dynamic>;
      expect(adapter.captured!.method, 'POST');
      expect(
        adapter.captured!.uri.path,
        endsWith('/playlists/5/tracks/batch-remove'),
      );
      expect(body['trackIds'], [1, 2, 3]);
      expect(updated.trackCount, 1);
    });
  });
}

class _MemoryTokenStorage implements TokenStorageBackend {
  String? accessToken;
  String? refreshToken;
  bool biometricUnlockEnabled = false;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<bool> hasTokens() async =>
      refreshToken != null && refreshToken!.isNotEmpty;

  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    biometricUnlockEnabled = enabled;
  }

  @override
  Future<bool> isBiometricUnlockEnabled() async => biometricUnlockEnabled;
}
