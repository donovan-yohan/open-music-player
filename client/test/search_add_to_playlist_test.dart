import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/playlists/add_to_playlist.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/shared/models/playlist.dart';
import 'package:provider/provider.dart';

import 'support/mock_dio_client.dart';

const _resultMoreKey = ValueKey('discover_result_more_youtube:123');
const _resultAddKey = ValueKey('discover_add_to_playlist_youtube:123');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('the queue action reads as a queue action, not a playlist one',
      (tester) async {
    // The compact row is the one that carries the tooltip, so size to it.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpSearch(tester, playlistService: _FakePlaylistService());
    await _search(tester);

    expect(find.byIcon(Icons.queue_music), findsOneWidget);
    expect(find.byTooltip('Add to queue'), findsOneWidget);
    // The playlist icon belongs to the playlist action, which lives behind the
    // row overflow.
    expect(find.byIcon(Icons.playlist_add), findsNothing);
  });

  testWidgets('a result that is not imported yet says so instead of hiding',
      (tester) async {
    final playlists = _FakePlaylistService();
    await _pumpSearch(tester, playlistService: playlists);
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_resultAddKey), findsOneWidget);
    expect(
      find.text('Import this result to add it to a playlist'),
      findsOneWidget,
    );
    expect(tester.widget<ListTile>(find.byKey(_resultAddKey)).enabled, isFalse);

    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();

    expect(find.byKey(addToPlaylistSheetKey), findsNothing);
    expect(playlists.addedTrackIds, isEmpty);
  });

  testWidgets('an imported result adds its library track to a playlist',
      (tester) async {
    final playlists = _FakePlaylistService(
      playlists: [_playlist(9, 'Late night')],
    );
    await _pumpSearch(
      tester,
      playlistService: playlists,
      queueApiClient: _ImportedQueueApiClient(),
    );
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();

    expect(tester.widget<ListTile>(find.byKey(_resultAddKey)).enabled, isTrue);
    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();

    expect(find.byKey(addToPlaylistSheetKey), findsOneWidget);
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    expect(playlists.addedTo, [9]);
    expect(playlists.addedTrackIds, [
      [42]
    ]);
    expect(find.byKey(addToPlaylistSuccessKey), findsOneWidget);
  });
}

Future<void> _pumpSearch(
  WidgetTester tester, {
  required PlaylistService playlistService,
  ApiClient? queueApiClient,
}) async {
  final apiClient = ApiClient(
    storage: SecureStorage(),
    dio: Dio()..httpClientAdapter = _SearchResultAdapter(),
  );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: apiClient),
        ChangeNotifierProvider<QueueProvider>(
          create: (_) => QueueProvider(queueApiClient ?? EmptyQueueApiClient()),
        ),
        ListenableProvider<PlaybackState>.value(value: _FakePlaybackState()),
      ],
      child: MaterialApp(
        home: SearchScreen(playlistService: playlistService),
      ),
    ),
  );
}

Future<void> _search(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'porter robinson');
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  expect(find.text('Porter Robinson - Sad Machine'), findsOneWidget);
}

Playlist _playlist(int id, String name) => Playlist(
      id: id,
      name: name,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      trackCount: 2,
    );

/// A queue that already holds the imported result, keyed by the same source
/// URL the Discover row carries. Its numeric playback id is the library track
/// the playlist API accepts.
class _ImportedQueueApiClient extends EmptyQueueApiClient {
  @override
  Future<QueueState> getQueue() async => QueueState(
        tracks: [
          QueueTrack(
            id: 'queue-item-uuid',
            playbackTrackId: '42',
            sourceUrl: 'https://youtube.com/watch?v=123',
            title: 'Porter Robinson - Sad Machine',
            duration: 272,
            addedAt: DateTime.utc(2026),
          ),
        ],
        currentIndex: 0,
      );
}

class _FakePlaylistService extends PlaylistService {
  _FakePlaylistService({this.playlists = const []}) : super(api: ApiClient());

  final List<Playlist> playlists;
  final List<int> addedTo = [];
  final List<List<int>> addedTrackIds = [];

  @override
  Future<PlaylistsResponse> getPlaylists({
    int limit = 50,
    int offset = 0,
    String? q,
    String? sort,
    String? order,
  }) async {
    return PlaylistsResponse(
      playlists: playlists,
      total: playlists.length,
      offset: 0,
      limit: limit,
    );
  }

  @override
  Future<AddTracksResult> addTracks(int playlistId, List<int> trackIds) async {
    addedTo.add(playlistId);
    addedTrackIds.add(trackIds);
    return AddTracksResult(added: trackIds, skipped: const <int>[]);
  }
}

class _FakePlaybackState extends Fake implements PlaybackState {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool get isResolvingSignedUrl => false;

  @override
  String? get playbackError => null;
}

class _SearchResultAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/discovery/search') {
      return _jsonResponse({
        'query': options.queryParameters['q'] ?? 'porter robinson',
        'results': [
          {
            'candidateId': 'youtube:123',
            'provider': 'youtube',
            'sourceId': '123',
            'sourceUrl': 'https://youtube.com/watch?v=123',
            'title': 'Porter Robinson - Sad Machine',
            'artist': 'Porter Robinson',
            'durationMs': 272000,
            'downloadable': true,
            'playable': false,
          },
        ],
        'providers': [
          {
            'provider': 'youtube',
            'status': 'ok',
            'resultCount': 1,
            'elapsedMs': 12,
          },
        ],
      });
    }

    return _jsonResponse({
      'message': 'unexpected ${options.method} ${options.path}',
    }, statusCode: 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
