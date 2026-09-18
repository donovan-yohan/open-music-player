import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/shared/models/models.dart';

/// Home feed regression for a play-history row whose track is not in the
/// caller's library.
///
/// The feed is built from play *events*, which outlive library membership, so
/// it can offer a row that `/playback/urls` will refuse (it gates on
/// `IsTrackInLibrary` and answers with a deliberately opaque 404, pinned by the
/// backend's `TestPlaybackURLIssuanceHidesNonOwnedTrackExistence`). That
/// refusal is a whole-batch failure, so before this fix one unowned row made
/// every tap in its section fail — including taps on playable siblings.
///
/// These tests are discriminating in three separate ways:
///
/// * a tap on an *owned* row in a mixed section must submit a queue that
///   excludes the unowned id (the sibling must not block it), and must start at
///   the tapped row's position *after* filtering (identity, not raw index);
/// * a tap on an *unowned* row must explain itself as "not in your library"
///   and submit nothing — not the transport copy "no longer available", which
///   would be a false diagnosis;
/// * a genuine transport failure on a fully-owned section must still surface,
///   so the earlier snackbar fix is retained rather than traded away.
void main() {
  testWidgets(
      'a tapped owned row queues only playable siblings, starting at '
      'that row by identity', (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback();
    await _pumpHome(
      tester,
      playback: playback,
      recent: [
        _track(47, 'Unowned First', inLibrary: false),
        _track(44, 'Owned A', inLibrary: true),
        _track(51, 'Owned B', inLibrary: true),
      ],
      top: const [],
    );

    // Tap the row at list index 1. After filtering it is index 0, but the
    // point of the assertion below is that the *tapped track* is the one
    // queued, not that some arithmetic coincidentally matched.
    await tester.tap(find.text('Owned A'));
    await tester.pumpAndSettle();

    expect(playback.queuedIds, [44, 51],
        reason: 'the unowned sibling must be excluded from the submitted batch '
            '(one unowned id fails the whole /playback/urls request)');
    expect(playback.startIndex, 0,
        reason: 'the tapped row is position 0 of the filtered queue');
  });

  testWidgets('the index is adjusted by identity, not by the raw tapped index',
      (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback();
    await _pumpHome(
      tester,
      playback: playback,
      recent: [
        _track(44, 'Owned A', inLibrary: true),
        _track(47, 'Unowned Middle', inLibrary: false),
        _track(51, 'Owned B', inLibrary: true),
      ],
      top: const [],
    );

    // Tapped at index 2 of the rendered section, which is index 1 of the
    // filtered queue. Carrying the raw index across would start on Owned B
    // instead of Owned A — silently the wrong song.
    await tester.tap(find.text('Owned B'));
    await tester.pumpAndSettle();

    expect(playback.queuedIds, [44, 51]);
    expect(playback.startIndex, 1,
        reason: 'filtering shifted the tapped row to index 1; the raw tapped '
            'index would have been 2');
  });

  testWidgets(
      'tapping an unowned row says it is not in the library and '
      'queues nothing', (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback();
    await _pumpHome(
      tester,
      playback: playback,
      recent: [
        _track(44, 'Owned A', inLibrary: true),
        _track(47, 'Unowned Row', inLibrary: false),
      ],
      top: const [],
    );

    await tester.tap(find.text('Unowned Row'));
    await tester.pumpAndSettle();

    expect(playback.queuedIds, isNull,
        reason: 'nothing may be submitted for a track the server will refuse');
    expect(find.text(homeNotInLibraryMessage), findsOneWidget,
        reason: 'the tap must explain itself; silently doing nothing is the '
            'reported symptom');
    expect(find.text('This track is no longer available.'), findsNothing,
        reason: 'nothing failed here — the transport-level copy would be a '
            'false diagnosis of a membership gap');
  });

  testWidgets('an unowned row is visibly marked and offers no swipe-to-queue',
      (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback();
    await _pumpHome(
      tester,
      playback: playback,
      recent: [
        _track(44, 'Owned A', inLibrary: true),
        _track(47, 'Unowned Row', inLibrary: false),
      ],
      top: const [],
    );

    expect(find.text('Owned A'), findsOneWidget);
    expect(find.text('Unowned Row'), findsOneWidget,
        reason: 'the history row stays visible; history is an audit log');
    expect(find.byKey(const ValueKey('home_not_in_library_47')), findsOneWidget,
        reason: 'an unowned row must not render identically to a playable one');
    expect(find.text('Not in your library'), findsOneWidget);
    // The owned row keeps its ordinary artist subtitle.
    expect(find.text('Artist 44'), findsOneWidget);
  });

  testWidgets('a transport failure on an all-owned section still reports',
      (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback(
      error: 'This track is no longer available.',
      throwOnPlay: true,
    );
    await _pumpHome(
      tester,
      playback: playback,
      recent: [_track(44, 'Owned A', inLibrary: true)],
      top: const [],
    );

    await tester.tap(find.text('Owned A'));
    await tester.pumpAndSettle();

    expect(playback.queuedIds, [44]);
    expect(find.text('This track is no longer available.'), findsOneWidget,
        reason: 'a real signed-URL failure must stay visible — the snackbar '
            'behavior is retained, not replaced');
  });

  testWidgets('the top-tracks section gets the same treatment as recent',
      (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback();
    await _pumpHome(
      tester,
      playback: playback,
      recent: const [],
      top: [
        _track(47, 'Unowned Top', inLibrary: false),
        _track(44, 'Owned Top', inLibrary: true),
      ],
    );

    await tester.tap(find.text('Owned Top'));
    await tester.pumpAndSettle();

    expect(playback.queuedIds, [44],
        reason: 'recent and top are two separate queries; a fix in only one '
            'leaves the other tap doing nothing');
    expect(playback.startIndex, 0);
  });

  testWidgets(
      'a row with no inLibrary claim keeps playing (library/local '
      'payloads must not regress)', (tester) async {
    _useTallViewport(tester);
    final playback = _RecordingPlayback();
    await _pumpHome(
      tester,
      playback: playback,
      recent: [_track(44, 'Unannotated', inLibrary: null)],
      top: const [],
    );

    await tester.tap(find.text('Unannotated'));
    await tester.pumpAndSettle();

    expect(playback.queuedIds, [44],
        reason: 'an absent capability signal is not a denial; only an explicit '
            'false may restrict playback');
  });
}

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required _RecordingPlayback playback,
  required List<Track> recent,
  required List<Track> top,
}) async {
  await tester.pumpWidget(
    ListenableProvider<PlaybackState>.value(
      value: playback,
      child: MaterialApp(
        home: HomeScreen(
          homeService: _FeedHomeService(recent: recent, top: top),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Track _track(int id, String title, {required bool? inLibrary}) => Track(
      id: id,
      identityHash: 'track-$id',
      title: title,
      artist: 'Artist $id',
      durationMs: 180000,
      artworkKind: TrackArtworkKind.none,
      inLibrary: inLibrary,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

/// Records exactly what Home asked playback to do, and can fail the way a
/// signed-URL refusal does.
class _RecordingPlayback extends Fake implements PlaybackState {
  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot.empty();
  _RecordingPlayback({this.error, this.throwOnPlay = false});

  final String? error;
  final bool throwOnPlay;

  List<int>? queuedIds;
  int? startIndex;

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    // Record the batch *before* failing: the point of the throwing case is that
    // the section was submitted and then failed, so the submission itself must
    // still be observable.
    queuedIds = [for (final track in tracks) track['id'] as int];
    this.startIndex = startIndex;
    if (throwOnPlay) {
      throw const SignedAudioUrlException(
        code: 'TRACK_NOT_FOUND',
        message: 'track not found',
      );
    }
  }

  @override
  String? get playbackError => error;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

/// Serves the two Home feeds from fixed lists, so no HTTP is involved.
class _FeedHomeService extends HomeService {
  _FeedHomeService({required this.recent, required this.top})
      : super(_UnusedApiClient());

  final List<Track> recent;
  final List<Track> top;

  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async => recent;

  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async => top;

  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      const [];
}

/// Never called; the feed is stubbed above.
class _UnusedApiClient extends ApiClient {
  @override
  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    Duration? receiveTimeout,
  }) async {
    throw StateError('Home feed is stubbed in this test: $path');
  }
}
