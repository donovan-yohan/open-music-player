import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:provider/provider.dart';

/// A LibraryService whose local-browse methods return stubbed data, so the
/// artist/album screens can be rendered without any HTTP.
class _FakeLibraryService extends LibraryService {
  _FakeLibraryService({this.result, this.pending}) : super(ApiClient());

  final List<Track>? result;
  final Completer<List<Track>>? pending;

  String? capturedArtist;
  String? capturedAlbum;

  Future<List<Track>> _respond() {
    if (pending != null) return pending!.future;
    return Future.value(result ?? const <Track>[]);
  }

  @override
  Future<List<Track>> getLibraryByArtist(String artist, {int limit = 500}) {
    capturedArtist = artist;
    return _respond();
  }

  @override
  Future<List<Track>> getLibraryByAlbum(String album, {int limit = 500}) {
    capturedAlbum = album;
    return _respond();
  }
}

/// Hands every local-browse call its own completer, so overlapping loads can
/// be resolved out of order.
class _SequencedLibraryService extends LibraryService {
  _SequencedLibraryService() : super(ApiClient());

  final List<Completer<List<Track>>> calls = [];

  @override
  Future<List<Track>> getLibraryByArtist(String artist, {int limit = 500}) {
    final completer = Completer<List<Track>>();
    calls.add(completer);
    return completer.future;
  }
}

Track _track({required int id, String? title, bool? isLiked}) => Track(
      id: id,
      identityHash: 'h$id',
      title: title ?? 'Track $id',
      artist: 'Artist',
      album: 'Album',
      durationMs: 200000,
      isLiked: isLiked,
      createdAt: DateTime(2020),
      updatedAt: DateTime(2020),
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

/// Starts two overlapping loads on a mounted [LocalBrowseView] and returns
/// their futures, oldest first. The pull-to-refresh callback is a tear-off
/// bound to the state, so it keeps working while the spinner replaces the
/// list that exposed it.
List<Future<void>> _startOverlappingLoads(WidgetTester tester) {
  final refresh =
      tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh;
  final stale = refresh();
  final fresh = refresh();
  return [stale, fresh];
}

void main() {
  testWidgets('shows a loading spinner while the fetch is in flight',
      (tester) async {
    final fake = _FakeLibraryService(pending: Completer<List<Track>>());
    await tester.pumpWidget(
      _wrap(LocalArtistScreen(artist: 'AC/DC', libraryService: fake)),
    );
    await tester.pump(); // let initState kick off the load

    expect(find.byKey(const ValueKey('local_browse_loading')), findsOneWidget);
  });

  testWidgets('renders the track list with Play + Shuffle actions',
      (tester) async {
    final fake = _FakeLibraryService(
      result: [_track(id: 1, title: 'A'), _track(id: 2, title: 'B')],
    );
    await tester.pumpWidget(
      _wrap(LocalArtistScreen(artist: 'AC/DC', libraryService: fake)),
    );
    await tester.pumpAndSettle();

    expect(fake.capturedArtist, 'AC/DC');
    expect(find.byKey(const ValueKey('local_browse_list')), findsOneWidget);
    expect(find.byKey(const ValueKey('local_browse_play')), findsOneWidget);
    expect(find.byKey(const ValueKey('local_browse_shuffle')), findsOneWidget);
    expect(find.byKey(const ValueKey('local_track_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('local_track_2')), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('Shuffle launch does not enable persistent playback shuffle',
      (tester) async {
    final fake = _FakeLibraryService(
      result: [
        _track(id: 1),
        _track(id: 2),
        _track(id: 3),
      ],
    );
    final playback = _RecordingPlaybackState();
    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: _wrap(
          LocalArtistScreen(artist: 'AC/DC', libraryService: fake),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local_browse_shuffle')));
    await tester.pump();

    expect(playback.playQueueCalls, 1);
    expect(
      playback.playedQueue!.map((track) => track['id']).toSet(),
      {1, 2, 3},
    );
    expect(playback.toggleShuffleCalls, 0);
    expect(playback.shuffleEnabled, isFalse);
  });

  testWidgets('renders an empty state when there are no tracks',
      (tester) async {
    final fake = _FakeLibraryService(result: const []);
    await tester.pumpWidget(
      _wrap(LocalAlbumScreen(album: 'Back in Black', libraryService: fake)),
    );
    await tester.pumpAndSettle();

    expect(fake.capturedAlbum, 'Back in Black');
    expect(find.byKey(const ValueKey('local_browse_empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('local_browse_list')), findsNothing);
  });

  testWidgets('renders an error state with a working Retry that reloads',
      (tester) async {
    var calls = 0;
    final fake = _RetryFake(onCall: () => calls++);
    await tester.pumpWidget(
      _wrap(LocalArtistScreen(artist: 'X', libraryService: fake)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('local_browse_error')), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2); // Retry re-invokes the loader
  });

  testWidgets('an older load resolving last cannot clobber the newer result',
      (tester) async {
    final fake = _SequencedLibraryService();
    final liked = LikedTracksState(fake);
    await tester.pumpWidget(
      ChangeNotifierProvider<LikedTracksState>.value(
        value: liked,
        child: _wrap(LocalArtistScreen(artist: 'AC/DC', libraryService: fake)),
      ),
    );
    await tester.pump();

    // Settle the initial load so the list — and its refresh seam — is mounted.
    fake.calls[0].complete([_track(id: 1)]);
    await tester.pump();

    final loads = _startOverlappingLoads(tester);
    await tester.pump();
    expect(fake.calls.length, 3);

    // The newer request answers first, then the older one lands late.
    fake.calls[2].complete([_track(id: 3, isLiked: true)]);
    await tester.pump();
    await loads[1];
    fake.calls[1].complete([_track(id: 2, isLiked: true)]);
    await tester.pump();
    await loads[0];
    await tester.pump();

    expect(find.byKey(const ValueKey('local_track_3')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local_track_2')),
      findsNothing,
      reason: 'the stale response must not replace the newer track list',
    );
    expect(liked.isLiked(3), isTrue);
    expect(
      liked.isLiked(2),
      isNull,
      reason: 'the stale response must not seed liked state',
    );
  });

  testWidgets('an older load failing last cannot flip a newer success to error',
      (tester) async {
    final fake = _SequencedLibraryService();
    await tester.pumpWidget(
      _wrap(LocalArtistScreen(artist: 'AC/DC', libraryService: fake)),
    );
    await tester.pump();

    fake.calls[0].complete([_track(id: 1)]);
    await tester.pump();

    final loads = _startOverlappingLoads(tester);
    await tester.pump();

    fake.calls[2].complete([_track(id: 3)]);
    await tester.pump();
    await loads[1];
    fake.calls[1].completeError(StateError('stale boom'));
    await tester.pump();
    await loads[0];
    await tester.pump();

    expect(find.byKey(const ValueKey('local_browse_error')), findsNothing);
    expect(find.byKey(const ValueKey('local_track_3')), findsOneWidget);
  });
}

/// Always errors, counting each load so the Retry wiring can be asserted.
class _RetryFake extends LibraryService {
  _RetryFake({required this.onCall}) : super(ApiClient());
  final VoidCallback onCall;

  @override
  Future<List<Track>> getLibraryByArtist(String artist, {int limit = 500}) {
    onCall();
    return Future.error(StateError('boom'));
  }
}

class _RecordingPlaybackState extends Fake implements PlaybackState {
  int playQueueCalls = 0;
  int toggleShuffleCalls = 0;
  List<Map<String, dynamic>>? playedQueue;
  bool _shuffleEnabled = false;

  @override
  bool get shuffleEnabled => _shuffleEnabled;

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    playQueueCalls++;
    playedQueue = tracks;
  }

  @override
  Future<void> toggleShuffle() async {
    toggleShuffleCalls++;
    _shuffleEnabled = !_shuffleEnabled;
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
