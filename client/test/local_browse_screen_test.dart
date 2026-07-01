import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/shared/models/track.dart';

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

Track _track({required int id, String? title}) => Track(
      id: id,
      identityHash: 'h$id',
      title: title ?? 'Track $id',
      artist: 'Artist',
      album: 'Album',
      durationMs: 200000,
      createdAt: DateTime(2020),
      updatedAt: DateTime(2020),
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

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
