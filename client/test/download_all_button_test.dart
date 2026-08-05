import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart' as core_api;
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/library/liked_songs_screen.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:open_music_player/shared/widgets/download_button.dart';
import 'package:provider/provider.dart';

Track _track(int id) => Track(
      id: id,
      identityHash: 'h$id',
      title: 'Track $id',
      artist: 'Artist',
      durationMs: 200000,
      isLiked: true,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

DownloadedTrack _completed(int id) => DownloadedTrack(
      trackId: id,
      localPath: '/tmp/$id.mp3',
      fileSizeBytes: 100,
      status: DownloadStatus.completed,
      downloadedAt: DateTime.utc(2026),
    );

/// Stubs only the collection-level surface [DownloadAllButton] reads, and
/// records what a tap asked for. Anything else is an explicit failure.
class _FakeDownloadState extends ChangeNotifier implements DownloadState {
  _FakeDownloadState({
    List<DownloadedTrack> completed = const [],
    Set<int> downloading = const {},
  })  : _completed = completed,
        _downloading = downloading;

  List<DownloadedTrack> _completed;
  Set<int> _downloading;

  final requestedBatches = <List<int>>[];

  void update({
    List<DownloadedTrack>? completed,
    Set<int>? downloading,
  }) {
    _completed = completed ?? _completed;
    _downloading = downloading ?? _downloading;
    notifyListeners();
  }

  @override
  List<DownloadedTrack> get downloads => _completed;

  @override
  Set<int> get downloadedTrackIds => {for (final d in _completed) d.trackId};

  @override
  bool isDownloading(int trackId) => _downloading.contains(trackId);

  @override
  Future<void> downloadTracks(Iterable<Track> tracks) async {
    requestedBatches.add([for (final track in tracks) track.id]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
}

Future<void> _pumpButton(
  WidgetTester tester,
  _FakeDownloadState state,
  List<Track> tracks,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<DownloadState>.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(body: DownloadAllButton(tracks: tracks)),
      ),
    ),
  );
  await tester.pump();
}

TextButton _button(WidgetTester tester) => tester.widget<TextButton>(
      find.byKey(const ValueKey('download_all_button')),
    );

void main() {
  group('aggregate', () {
    final tracks = [_track(1), _track(2), _track(3)];

    test('collapses per-track state into one status', () {
      DownloadAllAggregate aggregate(
        List<DownloadedTrack> completed,
        Set<int> downloading,
      ) =>
          DownloadAllAggregate.of(
            _FakeDownloadState(completed: completed, downloading: downloading),
            tracks,
          );

      expect(aggregate(const [], const {}).status, DownloadAllStatus.none);
      expect(
        aggregate([_completed(1)], const {}).status,
        DownloadAllStatus.partial,
      );
      expect(
        aggregate([_completed(1)], {2}).status,
        DownloadAllStatus.inProgress,
      );
      expect(
        aggregate([_completed(1), _completed(2), _completed(3)], const {})
            .status,
        DownloadAllStatus.complete,
      );
      expect(
        DownloadAllAggregate.of(_FakeDownloadState(), const []).status,
        DownloadAllStatus.empty,
      );
    });

    test('counts only what a tap would still have to fetch', () {
      final aggregate = DownloadAllAggregate.of(
        _FakeDownloadState(completed: [_completed(1)], downloading: {2}),
        tracks,
      );
      expect(aggregate.total, 3);
      expect(aggregate.downloaded, 1);
      expect(aggregate.inProgress, 1);
      expect(aggregate.remaining, 1);
    });
  });

  testWidgets('offers the whole collection when nothing is downloaded',
      (tester) async {
    final state = _FakeDownloadState();
    final tracks = [_track(1), _track(2), _track(3)];
    await _pumpButton(tester, state, tracks);

    expect(find.text('Download all'), findsOneWidget);
    expect(_button(tester).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('download_all_button')));
    await tester.pump();

    expect(state.requestedBatches, [
      [1, 2, 3]
    ]);
  });

  testWidgets('reports the remaining count once some tracks are on disk',
      (tester) async {
    final state = _FakeDownloadState(completed: [_completed(1)]);
    await _pumpButton(tester, state, [_track(1), _track(2), _track(3)]);

    expect(find.text('Download 2 more'), findsOneWidget);
    expect(_button(tester).onPressed, isNotNull);
  });

  testWidgets('goes inert while a transfer is running, then reports done',
      (tester) async {
    final state = _FakeDownloadState(downloading: {1, 2, 3});
    final tracks = [_track(1), _track(2), _track(3)];
    await _pumpButton(tester, state, tracks);

    expect(find.text('Downloading 0/3'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      _button(tester).onPressed,
      isNull,
      reason: 'a re-tap mid-transfer must not be able to queue more jobs',
    );

    // A tap on the disabled button changes nothing.
    await tester.tap(
      find.byKey(const ValueKey('download_all_button')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(state.requestedBatches, isEmpty);

    state.update(
      completed: [_completed(1), _completed(2), _completed(3)],
      downloading: const {},
    );
    await tester.pump();

    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(_button(tester).onPressed, isNull);
  });

  testWidgets('renders nothing for an empty collection', (tester) async {
    await _pumpButton(tester, _FakeDownloadState(), const []);
    expect(find.byKey(const ValueKey('download_all_button')), findsNothing);
  });

  testWidgets('renders nothing when no DownloadState is provided',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadAllButton(tracks: [_track(1)])),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('download_all_button')), findsNothing);
  });

  testWidgets('playlist detail mounts the collection download action',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final downloads = _FakeDownloadState();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadState>.value(value: downloads),
          ListenableProvider<PlaybackState>.value(value: _FakePlayback()),
        ],
        child: MaterialApp(
          home: PlaylistDetailScreen(
            playlistId: 7,
            playlistService: _StubPlaylistService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('playlist_download_all'));
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pump();

    expect(downloads.requestedBatches, [
      [1, 2]
    ]);
  });

  testWidgets('Liked Songs mounts the collection download action',
      (tester) async {
    final downloads = _FakeDownloadState();
    final library = _LikedLibraryService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DownloadState>.value(value: downloads),
          ChangeNotifierProvider<LikedTracksState>(
            create: (_) => LikedTracksState(library),
          ),
          ListenableProvider<PlaybackState>.value(value: _FakePlayback()),
        ],
        child: MaterialApp(home: LikedSongsScreen(libraryService: library)),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('liked_songs_download_all'));
    expect(button, findsOneWidget);

    await tester.tap(button);
    await tester.pump();

    expect(downloads.requestedBatches, [
      [1, 2]
    ]);
  });
}

class _LikedLibraryService extends LibraryService {
  _LikedLibraryService() : super(ApiClient());

  @override
  Future<({List<Track> tracks, int total})> getLikedSongs({
    int limit = 200,
    int offset = 0,
    String? sort,
    String? order,
  }) async =>
      (tracks: [_track(1), _track(2)], total: 2);
}

class _StubPlaylistService extends PlaylistService {
  _StubPlaylistService() : super(api: core_api.ApiClient(storage: SecureStorage()));

  @override
  Future<Playlist> getPlaylist(int id) async => Playlist(
        id: id,
        name: 'Mix',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: [_track(1), _track(2)],
      );
}

class _FakePlayback extends Fake implements PlaybackState {
  @override
  MediaItem? get currentItem => null;

  @override
  PlaybackContext? get playbackContext => null;

  @override
  bool get isPlaying => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
