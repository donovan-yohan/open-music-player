import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart' as core_api;
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/downloads/downloads_screen.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:provider/provider.dart';

Track _track(int id, {bool? isLiked}) => Track(
      id: id,
      identityHash: 'h$id',
      title: 'Track $id',
      artist: 'Artist',
      album: 'Album',
      durationMs: 200000,
      isLiked: isLiked,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

/// Records the persistence calls a heart makes, and returns library rows.
class _LikeLibraryService extends LibraryService {
  _LikeLibraryService({this.browseTracks = const []}) : super(ApiClient());

  final List<Track> browseTracks;
  final likedIds = <int>[];
  final unlikedIds = <int>[];

  @override
  Future<void> like(int trackId) async => likedIds.add(trackId);

  @override
  Future<void> unlike(int trackId) async => unlikedIds.add(trackId);

  @override
  Future<List<Track>> getLibraryByArtist(String artist,
          {int limit = 500}) async =>
      browseTracks;
}

class _StubPlaylistService extends PlaylistService {
  _StubPlaylistService(this.tracks)
      : super(api: core_api.ApiClient(storage: SecureStorage()));

  final List<Track> tracks;

  @override
  Future<Playlist> getPlaylist(int id) async => Playlist(
        id: id,
        name: 'Mix',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: tracks,
      );
}

class _StubHomeService extends HomeService {
  _StubHomeService(this.tracks) : super(ApiClient());

  final List<Track> tracks;

  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async => tracks;

  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async =>
      const [];

  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      const [];
}

class _StubDownloadState extends ChangeNotifier implements DownloadState {
  _StubDownloadState(this._downloads);

  final List<DownloadedTrack> _downloads;

  @override
  List<DownloadedTrack> get downloads => _downloads;

  @override
  bool get isLoading => false;

  @override
  int get downloadCount => _downloads.length;

  @override
  String get formattedTotalSize => '1 MB';

  @override
  Future<void> deleteDownload(int trackId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not stubbed');
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

/// Mobile-narrow viewport: any row that cannot fit its new heart overflows,
/// and a RenderFlex overflow fails the test.
void _useNarrowViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _wrap({
  required Widget child,
  required LikedTracksState liked,
  DownloadState? downloads,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<LikedTracksState>.value(value: liked),
      ListenableProvider<PlaybackState>.value(value: _FakePlayback()),
      if (downloads != null)
        ChangeNotifierProvider<DownloadState>.value(value: downloads),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('playlist detail rows expose a working heart', (tester) async {
    _useNarrowViewport(tester);
    final library = _LikeLibraryService();
    final liked = LikedTracksState(library);

    await tester.pumpWidget(
      _wrap(
        liked: liked,
        child: PlaylistDetailScreen(
          playlistId: 7,
          playlistService: _StubPlaylistService([_track(1), _track(2)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final heart = find.byKey(const ValueKey('playlist_like_1'));
    expect(heart, findsOneWidget);
    expect(find.byKey(const ValueKey('playlist_like_2')), findsOneWidget);

    await tester.tap(heart);
    await tester.pumpAndSettle();

    // Playlist payloads carry no `is_liked`, so an unknown row still toggles.
    expect(liked.isLiked(1), isTrue);
    expect(library.likedIds, [1]);
    expect(
      tester.widget<IconButton>(heart).icon,
      isA<Icon>().having((i) => i.icon, 'icon', Icons.favorite),
    );
  });

  testWidgets('local artist rows seed from is_liked and unlike back',
      (tester) async {
    _useNarrowViewport(tester);
    final library = _LikeLibraryService(
      browseTracks: [_track(1, isLiked: true), _track(2, isLiked: false)],
    );
    final liked = LikedTracksState(library);

    await tester.pumpWidget(
      _wrap(
        liked: liked,
        child: LocalArtistScreen(artist: 'Artist', libraryService: library),
      ),
    );
    await tester.pumpAndSettle();

    // The library listing annotates liked state, so the load seeds it.
    expect(liked.isLiked(1), isTrue);
    expect(liked.isLiked(2), isFalse);

    final heart = find.byKey(const ValueKey('local_browse_like_1'));
    expect(heart, findsOneWidget);

    await tester.tap(heart);
    await tester.pumpAndSettle();

    expect(liked.isLiked(1), isFalse);
    expect(library.unlikedIds, [1]);
  });

  testWidgets('home rotation rows expose a working heart', (tester) async {
    _useNarrowViewport(tester);
    final library = _LikeLibraryService();
    final liked = LikedTracksState(library);

    await tester.pumpWidget(
      _wrap(
        liked: liked,
        child: HomeScreen(homeService: _StubHomeService([_track(1)])),
      ),
    );
    await tester.pumpAndSettle();

    final heart = find.byKey(const ValueKey('home_like_1'));
    expect(heart, findsOneWidget);

    await tester.tap(heart);
    await tester.pumpAndSettle();

    expect(liked.isLiked(1), isTrue);
    expect(library.likedIds, [1]);
  });

  testWidgets('downloads rows expose a working heart', (tester) async {
    _useNarrowViewport(tester);
    final library = _LikeLibraryService();
    final liked = LikedTracksState(library);
    final downloads = _StubDownloadState([
      DownloadedTrack(
        trackId: 1,
        localPath: '/tmp/1.mp3',
        fileSizeBytes: 1000,
        status: DownloadStatus.completed,
        downloadedAt: DateTime.utc(2026),
        track: _track(1),
      ),
    ]);

    await tester.pumpWidget(
      _wrap(
        liked: liked,
        downloads: downloads,
        child: const DownloadsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    final heart = find.byKey(const ValueKey('downloads_like_1'));
    expect(heart, findsOneWidget);

    await tester.tap(heart);
    await tester.pumpAndSettle();

    expect(liked.isLiked(1), isTrue);
    expect(library.likedIds, [1]);
  });

  testWidgets('a toggle on one surface is visible on another immediately',
      (tester) async {
    _useNarrowViewport(tester);
    final library = _LikeLibraryService(
      browseTracks: [_track(1, isLiked: false)],
    );
    final liked = LikedTracksState(library);

    // Two surfaces rendering the same track, sharing one LikedTracksState.
    await tester.pumpWidget(
      _wrap(
        liked: liked,
        child: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: HomeScreen(homeService: _StubHomeService([_track(1)])),
              ),
              Expanded(
                child: LocalArtistScreen(
                  artist: 'Artist',
                  libraryService: library,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Icon iconOf(String key) =>
        tester.widget<IconButton>(find.byKey(ValueKey(key))).icon as Icon;

    expect(iconOf('home_like_1').icon, Icons.favorite_border);
    expect(iconOf('local_browse_like_1').icon, Icons.favorite_border);

    await tester.tap(find.byKey(const ValueKey('home_like_1')));
    await tester.pumpAndSettle();

    expect(liked.isLiked(1), isTrue);
    expect(iconOf('home_like_1').icon, Icons.favorite);
    expect(
      iconOf('local_browse_like_1').icon,
      Icons.favorite,
      reason: 'every heart reads the same LikedTracksState value',
    );
  });

  group('LikedTracksState.assume', () {
    test('establishes a value only when none is known', () {
      final state = LikedTracksState(_LikeLibraryService());

      state.assume(1, false);
      expect(state.isLiked(1), isFalse);

      // A known value wins over a later assumption.
      state.assume(1, true);
      expect(state.isLiked(1), isFalse);
    });

    test('an authoritative seed still corrects an assumption', () {
      final state = LikedTracksState(_LikeLibraryService());

      state.assume(1, false);
      state.seed([_track(1, isLiked: true)]);

      expect(state.isLiked(1), isTrue);
    });
  });
}
