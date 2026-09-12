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
import 'package:open_music_player/core/discovery/discovery_models.dart';
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

  testWidgets('an unimported result imports first, then adds once it has an id',
      (tester) async {
    final playlists = _FakePlaylistService(
      playlists: [_playlist(9, 'Late night')],
    );
    final queueApi = _ImportingQueueApiClient();
    await _pumpSearch(
      tester,
      playlistService: playlists,
      queueApiClient: queueApi,
    );
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();

    // The action is live on every row; it names the import it will run.
    expect(tester.widget<ListTile>(find.byKey(_resultAddKey)).enabled, isTrue);
    expect(find.text('Imports this result first'), findsOneWidget);

    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();

    // The playlist is captured before the wait, not after it.
    expect(find.byKey(addToPlaylistSheetKey), findsOneWidget);
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    expect(queueApi.addedDecisionIds, ['decision-1']);
    expect(playlists.addedTrackIds, isEmpty);
    expect(
      find.byKey(const ValueKey('discover_playlist_sequence_notice')),
      findsOneWidget,
    );

    // The download finishes and the queue item gains its library track id.
    queueApi.completeImport(77);
    await _drainPoll(tester);

    expect(playlists.addedTo, [9]);
    expect(playlists.addedTrackIds, [
      [77]
    ]);
    expect(find.byKey(addToPlaylistSuccessKey), findsOneWidget);
  });

  testWidgets('a failed import says the track was not added', (tester) async {
    final playlists = _FakePlaylistService(
      playlists: [_playlist(9, 'Late night')],
    );
    final queueApi = _ImportingQueueApiClient();
    await _pumpSearch(
      tester,
      playlistService: playlists,
      queueApiClient: queueApi,
    );
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    queueApi.failImport();
    await _drainPoll(tester);

    expect(playlists.addedTrackIds, isEmpty);
    expect(
      find.byKey(const ValueKey('discover_playlist_import_failed')),
      findsOneWidget,
    );
  });

  testWidgets('an add that fails after a good import reports the failure',
      (tester) async {
    final playlists = _FakePlaylistService(
      playlists: [_playlist(9, 'Late night')],
      failAdd: true,
    );
    final queueApi = _ImportingQueueApiClient();
    await _pumpSearch(
      tester,
      playlistService: playlists,
      queueApiClient: queueApi,
    );
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    queueApi.completeImport(77);
    await _drainPoll(tester);

    expect(find.byKey(addToPlaylistFailureKey), findsOneWidget);
    expect(find.byKey(addToPlaylistSuccessKey), findsNothing);
  });

  testWidgets('an import that never reaches the queue gives up and says so',
      (tester) async {
    final playlists = _FakePlaylistService(
      playlists: [_playlist(9, 'Late night')],
    );
    // A queue that never accepts the import, standing in for a source-selection
    // path that fails without throwing at the call site.
    await _pumpSearch(
      tester,
      playlistService: playlists,
      queueApiClient: EmptyQueueApiClient(),
      importWaitPolls: 2,
    );
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    await _drainPoll(tester);

    expect(playlists.addedTrackIds, isEmpty);
    expect(
      find.byKey(const ValueKey('discover_playlist_import_failed')),
      findsOneWidget,
    );
  });

  testWidgets('leaving Discover mid-import drops the wait without crashing',
      (tester) async {
    final playlists = _FakePlaylistService(
      playlists: [_playlist(9, 'Late night')],
    );
    final queueApi = _ImportingQueueApiClient();
    await _pumpSearch(
      tester,
      playlistService: playlists,
      queueApiClient: queueApi,
    );
    await _search(tester);

    await tester.tap(find.byKey(_resultMoreKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_resultAddKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    // Replace the screen while the import is still running.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    queueApi.completeImport(77);
    await _drainPoll(tester);

    expect(tester.takeException(), isNull);
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

    expect(find.text('Imports this result first'), findsNothing);
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
  int importWaitPolls = 30,
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
        home: SearchScreen(
          playlistService: playlistService,
          importWaitPolls: importWaitPolls,
        ),
      ),
    ),
  );
}

/// Advances past the screen's 2s queue poll and lets its async refresh land.
Future<void> _drainPoll(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump();
  }
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

/// A queue whose import starts without a library track id and gains one only
/// when the download completes — the real sequence a Discover result follows.
class _ImportingQueueApiClient extends EmptyQueueApiClient {
  final List<String> addedDecisionIds = [];
  bool _queued = false;
  int? _trackId;
  bool _failed = false;

  void completeImport(int trackId) => _trackId = trackId;

  void failImport() => _failed = true;

  @override
  Future<QueueState> getQueue() async => _state();

  @override
  Future<SourceDecisionQueueResponse> addSourceDecisionToQueue({
    required String sourceDecisionId,
    String position = 'last',
  }) async {
    addedDecisionIds.add(sourceDecisionId);
    _queued = true;
    return SourceDecisionQueueResponse(
      queue: _state(),
      downloadJobId: 'job-1',
      idempotent: false,
    );
  }

  QueueState _state() {
    if (!_queued) return QueueState.empty();
    return QueueState(
      tracks: [
        QueueTrack(
          id: 'queue-item-uuid',
          playbackTrackId: _trackId?.toString(),
          sourceCandidateId: 'youtube:123',
          sourceUrl: 'https://youtube.com/watch?v=123',
          title: 'Porter Robinson - Sad Machine',
          duration: 272,
          addedAt: DateTime.utc(2026),
          queueStatus: _failed
              ? TrackQueueStatus.failed
              : _trackId == null
                  ? TrackQueueStatus.downloading
                  : TrackQueueStatus.playable,
        ),
      ],
      currentIndex: 0,
    );
  }
}

class _FakePlaylistService extends PlaylistService {
  _FakePlaylistService({this.playlists = const [], this.failAdd = false})
      : super(api: ApiClient());

  final List<Playlist> playlists;
  final bool failAdd;
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
    if (failAdd) throw StateError('add rejected');
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
        'selectionSessionId': 'session-1',
        'recommendedCandidateId': 'youtube:123',
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

    if (options.method == 'POST' && options.path == '/source-selections') {
      return _jsonResponse({
        'id': 'decision-1',
        'sessionId': 'session-1',
        'selectedCandidateId': 'youtube:123',
        'recommendedCandidateId': 'youtube:123',
        'action': 'selected',
        'origin': 'discovery',
        'selectedCandidate': {
          'candidateId': 'youtube:123',
          'provider': 'youtube',
          'sourceId': '123',
          'sourceUrl': 'https://youtube.com/watch?v=123',
          'title': 'Porter Robinson - Sad Machine',
          'downloadable': true,
          'playable': false,
        },
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
