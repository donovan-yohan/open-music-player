import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/playlists/add_tracks_sheet.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:provider/provider.dart' as provider;

/// An open playlist has to be fillable from the playlist itself: the library
/// picker is the only in-screen path that reaches arbitrary tracks, so these
/// tests drive it end to end — open, pick, add, report, refresh.
const _appBarActionKey = ValueKey('playlist_add_tracks_action');
const _emptyStateActionKey = ValueKey('playlist_empty_add_tracks');

void main() {
  testWidgets('the app-bar action opens the library picker', (tester) async {
    final library = _FakeLibrary(_libraryTracks(3));
    await _pumpDetail(tester, library: library);

    expect(find.byKey(addTracksSheetKey), findsNothing);
    await tester.tap(find.byKey(_appBarActionKey));
    await tester.pumpAndSettle();

    expect(find.byKey(addTracksSheetKey), findsOneWidget);
    expect(find.text('Add tracks'), findsOneWidget);
    expect(
      find.text('Pick tracks from your library to add to "Late Night".'),
      findsOneWidget,
    );
    // The picker asks for the library, not for this playlist's own tracks.
    expect(library.requests, [(limit: 20, offset: 0, query: null)]);
  });

  testWidgets('an empty playlist offers the picker instead of advice',
      (tester) async {
    final service = _StubPlaylistService(tracks: const []);
    await _pumpDetail(tester, service: service);

    final action = find.byKey(_emptyStateActionKey);
    expect(action, findsOneWidget);
    expect(find.text('Add tracks from your library'), findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byKey(addTracksSheetKey), findsOneWidget);
  });

  testWidgets('picking tracks adds them and refreshes the playlist',
      (tester) async {
    final service = _StubPlaylistService(tracks: const []);
    await _pumpDetail(tester, service: service);

    await tester.tap(find.byKey(_emptyStateActionKey));
    await tester.pumpAndSettle();

    // Nothing selected yet, so the confirm button cannot be pressed.
    expect(
      tester.widget<FilledButton>(find.byKey(addTracksConfirmKey)).onPressed,
      isNull,
    );

    await tester.tap(find.byKey(addTracksRowKey(101)));
    await tester.tap(find.byKey(addTracksRowKey(103)));
    await tester.pumpAndSettle();
    expect(find.text('Add 2 tracks'), findsOneWidget);

    await tester.tap(find.byKey(addTracksConfirmKey));
    await tester.pumpAndSettle();

    // Records hold the id list by identity, so the parts are compared.
    expect(service.added.single.playlistId, 7);
    expect(service.added.single.trackIds, [101, 103]);
    expect(find.text('Added 2 tracks to "Late Night"'), findsOneWidget);
    // Second load is the refresh, and the rows it returned are on screen
    // without the user leaving and coming back.
    expect(service.loads, 2);
    expect(find.text('Library 101'), findsOneWidget);
    expect(find.text('Library 103'), findsOneWidget);
  });

  testWidgets('searching the library narrows what the picker offers',
      (tester) async {
    final library = _FakeLibrary(_libraryTracks(3));
    await _pumpDetail(tester, library: library);

    await tester.tap(find.byKey(_appBarActionKey));
    await tester.pumpAndSettle();

    library.tracks = [_track(202, 'Nightcall')];
    await tester.enterText(find.byKey(addTracksSearchFieldKey), 'night');
    // The query is debounced, so nothing is asked for until it settles.
    expect(library.requests.length, 1);
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(library.requests.last, (limit: 20, offset: 0, query: 'night'));
    expect(find.text('Nightcall'), findsOneWidget);
    expect(find.text('Library 101'), findsNothing);
  });

  testWidgets('scrolling the picker pages the library', (tester) async {
    final library = _FakeLibrary(_libraryTracks(25));
    await _pumpDetail(tester, library: library);

    await tester.tap(find.byKey(_appBarActionKey));
    await tester.pumpAndSettle();
    expect(library.requests.length, 1);

    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(library.requests.last, (limit: 20, offset: 20, query: null));

    // The second page is only reachable once it has arrived.
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(find.byKey(addTracksRowKey(125)), findsOneWidget);
  });

  testWidgets('the backend duplicate report is what the user is told',
      (tester) async {
    // The playlist changed under the open sheet, so a track the picker
    // offered comes back skipped. The backend's report is the authority.
    final service = _StubPlaylistService(
      tracks: const [],
      addResult: const AddTracksResult(added: [], skipped: [101]),
    );
    await _pumpDetail(tester, service: service);

    await _pickFirstTrack(tester, _emptyStateActionKey);

    expect(find.text('Already in this playlist'), findsOneWidget);
  });

  testWidgets('a partial add reports both halves', (tester) async {
    final service = _StubPlaylistService(
      tracks: const [],
      addResult: const AddTracksResult(added: [101], skipped: [103]),
    );
    await _pumpDetail(tester, service: service);

    await tester.tap(find.byKey(_emptyStateActionKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(addTracksRowKey(101)));
    await tester.tap(find.byKey(addTracksRowKey(103)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(addTracksConfirmKey));
    await tester.pumpAndSettle();

    expect(
      find.text('Added 1 • 1 already in "Late Night"'),
      findsOneWidget,
    );
  });

  testWidgets('tracks already in the playlist are shown as done',
      (tester) async {
    final service = _StubPlaylistService(tracks: [_track(101, 'Library 101')]);
    await _pumpDetail(tester, service: service);

    await tester.tap(find.byKey(_appBarActionKey));
    await tester.pumpAndSettle();

    final alreadyRow = find.byKey(addTracksRowKey(101));
    expect(
      find.descendant(of: alreadyRow, matching: find.byType(Checkbox)),
      findsNothing,
    );
    await tester.tap(alreadyRow);
    await tester.pumpAndSettle();

    // Tapping it selects nothing, so the confirm button stays inert.
    expect(find.text('Select tracks to add'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(addTracksRowKey(102)),
        matching: find.byType(Checkbox),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a failed add reports itself and leaves the playlist alone',
      (tester) async {
    final service = _StubPlaylistService(
      tracks: const [],
      addFailure: StateError('offline'),
    );
    await _pumpDetail(tester, service: service);

    await _pickFirstTrack(tester, _emptyStateActionKey);

    expect(
      find.text('Could not add to this playlist. Try again.'),
      findsOneWidget,
    );
    // No refresh: the write never landed, so there is nothing new to show.
    expect(service.loads, 1);
  });

  testWidgets('a library that will not load offers a retry', (tester) async {
    final library = _FakeLibrary(_libraryTracks(2), failures: 1);
    await _pumpDetail(tester, library: library);

    await tester.tap(find.byKey(_appBarActionKey));
    await tester.pumpAndSettle();

    expect(find.byKey(addTracksErrorKey), findsOneWidget);
    expect(
        find.text('Could not load your library. Try again.'), findsOneWidget);

    await tester.tap(find.byKey(addTracksRetryKey));
    await tester.pumpAndSettle();

    expect(find.byKey(addTracksErrorKey), findsNothing);
    expect(find.text('Library 101'), findsOneWidget);
  });

  testWidgets('backing out of the picker adds nothing', (tester) async {
    final service = _StubPlaylistService(tracks: const []);
    await _pumpDetail(tester, service: service);

    await tester.tap(find.byKey(_emptyStateActionKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(addTracksRowKey(101)));
    await tester.pumpAndSettle();

    // Tapping the barrier is the ordinary way out of a modal sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(addTracksSheetKey), findsNothing);
    expect(service.added, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });
}

Future<void> _pickFirstTrack(
    WidgetTester tester, ValueKey<String> opener) async {
  await tester.tap(find.byKey(opener));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(addTracksRowKey(101)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(addTracksConfirmKey));
  await tester.pumpAndSettle();
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  _StubPlaylistService? service,
  _FakeLibrary? library,
}) async {
  await tester.pumpWidget(
    provider.ListenableProvider<PlaybackState>.value(
      value: _FakePlayback(),
      child: MaterialApp(
        home: PlaylistDetailScreen(
          playlistId: 7,
          playlistService: service ?? _StubPlaylistService(tracks: const []),
          libraryTrackLoader: (library ?? _FakeLibrary(_libraryTracks(3))).load,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Track> _libraryTracks(int count) => [
      for (var i = 0; i < count; i++) _track(101 + i, 'Library ${101 + i}'),
    ];

Track _track(int id, String title) => Track(
      id: id,
      identityHash: 'h$id',
      title: title,
      artist: 'Artist $id',
      durationMs: 200000,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

/// Stands in for `LibraryService.getLibraryPage`, recording exactly what the
/// picker asked for so search and paging are checked at the request, not just
/// at the rendered rows.
class _FakeLibrary {
  _FakeLibrary(this.tracks, {this.failures = 0});

  List<Track> tracks;
  int failures;

  final List<({int limit, int offset, String? query})> requests = [];

  Future<({List<Track> tracks, int total})> load({
    required int limit,
    required int offset,
    String? query,
  }) async {
    requests.add((limit: limit, offset: offset, query: query));
    if (failures > 0) {
      failures--;
      throw StateError('offline');
    }
    final page = tracks.skip(offset).take(limit).toList();
    return (tracks: page, total: tracks.length);
  }
}

class _StubPlaylistService extends PlaylistService {
  _StubPlaylistService({
    required this.tracks,
    this.addResult,
    this.addFailure,
  }) : super(api: ApiClient(storage: SecureStorage()));

  /// Mutable so a successful add can be reflected by the refresh that follows
  /// it, which is the behavior under test.
  List<Track> tracks;
  final AddTracksResult? addResult;
  final Object? addFailure;

  final List<({int playlistId, List<int> trackIds})> added = [];
  int loads = 0;

  @override
  Future<Playlist> getPlaylist(int id) async {
    loads++;
    return Playlist(
      id: id,
      name: 'Late Night',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      trackCount: tracks.length,
      tracks: [...tracks],
    );
  }

  @override
  Future<AddTracksResult> addTracks(int playlistId, List<int> trackIds) async {
    if (addFailure != null) throw addFailure!;
    added.add((playlistId: playlistId, trackIds: trackIds));
    final result =
        addResult ?? AddTracksResult(added: trackIds, skipped: const []);
    tracks = [
      ...tracks,
      for (final id in result.added) _track(id, 'Library $id'),
    ];
    return result;
  }
}

class _FakePlayback extends Fake implements PlaybackState {
  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot.empty();
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
