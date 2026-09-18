import 'dart:async';

import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'support/fake_voice.dart';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/features/player/widgets/mini_player.dart';
import 'package:open_music_player/features/playlists/add_to_playlist.dart';

import 'support/recording_playlist_service.dart';

void main() {
  group('pending playback with real engine', () {
    late _PendingFixture fixture;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      fixture = _PendingFixture();
    });

    for (final width in [390.0, 1200.0]) {
      testWidgets('cold start is accessible at 3x text, width $width',
          (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await fixture.mount(tester, scale: 3);
        final semantics = tester.ensureSemantics();

        expect(find.text('Starting playback…'), findsNothing);
        final start = fixture.playback.playTrack(_pendingTrack(1));
        await _pumpUntil(tester, () => fixture.requests.length == 1);
        expect(find.text('Starting playback…'), findsOneWidget);
        expect(find.text('Track 1'), findsNothing);
        expect(fixture.playback.currentItem, isNull);
        expect(
            tester
                .getSemantics(find.text('Starting playback…'))
                .getSemanticsData()
                .flagsCollection
                .isLiveRegion,
            isTrue);
        semantics.dispose();
        expect(find.byTooltip('Cancel playback'), findsOneWidget);
        expect(tester.takeException(), isNull);
        fixture.complete(0);
        await _finish(tester, start);
        expect(find.text('Starting playback…'), findsNothing);
        expect(find.text('Track 1'), findsOneWidget);
        expect(find.byTooltip('Pause'), findsOneWidget);
        await fixture.close(tester);
      });
    }

    for (final stop in [false, true]) {
      testWidgets('cancel during signed resolution: stop=$stop',
          (tester) async {
        await fixture.mount(tester);
        final start = fixture.playback.playQueue([_pendingTrack(1)]);
        await _pumpUntil(tester, () => fixture.requests.length == 1);
        if (stop) {
          await _finish(tester, fixture.playback.stop());
        } else {
          await tester.tap(find.byTooltip('Cancel playback'));
          await tester.pump();
        }
        expect(find.text('Starting playback…'), findsNothing);
        fixture.complete(0);
        await _finish(tester, start);
        expect(fixture.playback.currentItem, isNull);
        expect(fixture.clock.playCalls, 0);
        await fixture.close(tester);
      });
    }

    testWidgets('signed error clears feedback and preserves playback error',
        (tester) async {
      await fixture.mount(tester);
      final start = fixture.playback.playTrack(_pendingTrack(1));
      await _pumpUntil(tester, () => fixture.requests.length == 1);
      final asserted =
          expectLater(start, throwsA(isA<SignedAudioUrlException>()));
      fixture.requests[0].result.completeError(const SignedAudioUrlException(
          code: 'UNAVAILABLE', message: 'No audio available'));
      await _finish(tester, asserted);
      expect(find.text('Starting playback…'), findsNothing);
      expect(fixture.playback.playbackError,
          'Could not prepare a signed playback URL.');
      expect(fixture.clock.playCalls, 0);
      await fixture.close(tester);
    });

    for (final newestFirst in [false, true]) {
      testWidgets('latest wins without stale title: newestFirst=$newestFirst',
          (tester) async {
        await fixture.mount(tester);
        final original = fixture.playback.playTrack(_pendingTrack(1));
        await _pumpUntil(tester, () => fixture.requests.length == 1);
        fixture.complete(0);
        await _finish(tester, original);
        expect(find.text('Track 1'), findsOneWidget);
        final a = fixture.playback.playTrack(_pendingTrack(2));
        await _pumpUntil(tester, () => fixture.requests.length == 2);
        final b = fixture.playback.playTrack(_pendingTrack(3));
        await _pumpUntil(tester, () => fixture.requests.length == 3);
        expect(find.text('Track 1'), findsNothing);
        expect(find.text('Track 2'), findsNothing);
        expect(find.text('Starting playback…'), findsOneWidget);
        fixture.complete(newestFirst ? 2 : 1);
        await _finish(tester, newestFirst ? b : a);
        if (!newestFirst) {
          expect(find.text('Starting playback…'), findsOneWidget);
        }
        fixture.complete(newestFirst ? 1 : 2);
        await _finish(tester, Future.wait([a, b]));
        expect(find.text('Track 3'), findsOneWidget);
        expect(find.text('Track 2'), findsNothing);
        expect(find.text('Starting playback…'), findsNothing);
        expect(fixture.clock.playCalls, 2);
        await fixture.close(tester);
      });
    }

    for (final entry in ['track', 'queue', 'mix', 'enqueue', 'playNext']) {
      testWidgets('real initial clear is pending and cancellable: $entry',
          (tester) async {
        await fixture.mount(tester);
        fixture.clock.gate = Completer<void>();
        final start = switch (entry) {
          'track' => fixture.playback.playTrack(_pendingTrack(1)),
          'queue' => fixture.playback.playQueue([_pendingTrack(1)]),
          'mix' => fixture.playback.playMixPlan(
              [_pendingTrack(1)],
              MixPlan(
                id: 'pending-plan',
                schemaVersion: 1,
                name: 'Pending plan',
                clips: [
                  MixPlanClip(
                      clipId: 'clip-1',
                      queueItemId: 'queue-1',
                      trackId: '1',
                      sourceStartMs: 0,
                      sourceEndMs: 60000,
                      timelineStartMs: 0)
                ],
                summary: const MixPlanSummary(
                    clipCount: 1, trackIds: ['1'], durationMs: 60000),
                version: 1,
                createdAt: DateTime.utc(2026),
                updatedAt: DateTime.utc(2026),
              )),
          'enqueue' => fixture.playback.enqueue(_pendingTrack(1)),
          _ => fixture.playback.playNext(_pendingTrack(1)),
        };
        await _pumpUntil(tester, () => fixture.clock.seekBlocked);
        expect(fixture.requests, isEmpty);
        expect(find.text('Starting playback…'), findsOneWidget);
        await tester.tap(find.byTooltip('Cancel playback'));
        await tester.pump();
        expect(find.text('Starting playback…'), findsNothing);
        fixture.clock.gate!.complete();
        await _finish(tester, start);
        expect(fixture.requests, isEmpty);
        expect(fixture.playback.isResolvingSignedUrl, isFalse);
        expect(fixture.clock.playCalls, 0);
        await fixture.close(tester);
      });
    }

    testWidgets('initial clear stays pending through resolution then starts',
        (tester) async {
      await fixture.mount(tester);
      fixture.clock.gate = Completer<void>();
      final start = fixture.playback.playTrack(_pendingTrack(1));
      await _pumpUntil(tester, () => fixture.clock.seekBlocked);
      expect(fixture.requests, isEmpty);
      expect(find.text('Starting playback…'), findsOneWidget);
      fixture.clock.gate!.complete();
      await _pumpUntil(tester, () => fixture.requests.length == 1);
      expect(find.text('Starting playback…'), findsOneWidget);
      fixture.complete(0);
      await _finish(tester, start);
      expect(find.text('Starting playback…'), findsNothing);
      expect(find.text('Track 1'), findsOneWidget);
      expect(fixture.clock.playCalls, 1);
      await fixture.close(tester);
    });

    testWidgets('real initial clear failure removes pending and rethrows',
        (tester) async {
      await fixture.mount(tester);
      fixture.clock.gate = Completer<void>();
      final failure = StateError('initial clear failed');
      final start = fixture.playback.playTrack(_pendingTrack(1));
      final asserted = expectLater(start, throwsA(same(failure)));
      await _pumpUntil(tester, () => fixture.clock.seekBlocked);
      expect(find.text('Starting playback…'), findsOneWidget);
      fixture.clock.gate!.completeError(failure);
      await _finish(tester, asserted);
      expect(find.text('Starting playback…'), findsNothing);
      expect(fixture.requests, isEmpty);
      expect(fixture.playback.isResolvingSignedUrl, isFalse);
      await fixture.close(tester);
    });
  });
  testWidgets('mini player grows without overflow at 2x and 3x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _MiniPlayerPlaybackState();
    addTearDown(playback.disposeFake);
    final flutterErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;

    Future<double> pumpAtScale(double scale) async {
      await tester.pumpWidget(
        ListenableProvider<PlaybackState>.value(
          value: playback,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayer(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester
          .getSize(find.byKey(const ValueKey('spotify_like_mini_player')))
          .height;
    }

    try {
      final height2x = await pumpAtScale(2);
      final height3x = await pumpAtScale(3);

      expect(height2x, greaterThan(64));
      expect(height3x, greaterThan(height2x));
      final title = find.text('EVERYTHING I HAVE EVER WANTED');
      final titleElement = tester.element(title);
      expect(Theme.of(titleElement).brightness, Brightness.dark);
      expect(
        _contrastRatio(
          _effectiveTextColor(tester, title),
          AppTheme.surfaceRaised,
        ),
        greaterThanOrEqualTo(4.5),
      );
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Open queue'), findsOneWidget);
      final pauseIcon = tester.widget<Icon>(find.byIcon(Icons.pause));
      expect(
        _contrastRatio(pauseIcon.color!, AppTheme.orange),
        greaterThanOrEqualTo(4.5),
      );
    } finally {
      FlutterError.onError = previousOnError;
    }

    expect(
      flutterErrors.where(
        (error) => error.exceptionAsString().contains('overflowed'),
      ),
      isEmpty,
    );
  });

  group('add to playlist', () {
    Future<void> pumpMiniPlayer(
      WidgetTester tester,
      RecordingPlaylistService service, {
      audio_service.MediaItem? item,
    }) async {
      final playback = _MiniPlayerPlaybackState(item: item);
      addTearDown(playback.disposeFake);
      await tester.pumpWidget(
        ListenableProvider<PlaybackState>.value(
          value: playback,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayer(playlistService: service),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a long press adds the playing track to a playlist',
        (tester) async {
      final service = RecordingPlaylistService(
        playlists: [testPlaylist(5, 'Late night')],
      );

      await pumpMiniPlayer(tester, service);
      await tester.longPress(
        find.byKey(const ValueKey('spotify_like_mini_player')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(addToPlaylistSheetKey), findsOneWidget);
      await tester.tap(find.text('Late night'));
      await tester.pumpAndSettle();

      expect(service.addedTo, [5]);
      expect(service.addedTrackIds, [
        [42]
      ]);
    });

    testWidgets('a local-only track says so instead of opening the picker',
        (tester) async {
      final service = RecordingPlaylistService();

      await pumpMiniPlayer(
        tester,
        service,
        item: const audio_service.MediaItem(
          id: 'local-file',
          title: 'Local only',
          duration: Duration(minutes: 3),
        ),
      );
      await tester.longPress(
        find.byKey(const ValueKey('spotify_like_mini_player')),
      );
      await tester.pumpAndSettle();

      expect(service.listCalls, 0);
      expect(find.byKey(addToPlaylistSheetKey), findsNothing);
      expect(
          find.text('This track is not in your library yet'), findsOneWidget);
    });
  });
}

// Pump fake time only until the awaited operation completes. pumpAndSettle
// cannot settle the pending spinner or the engine's periodic timers.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue,
      reason: 'Operation did not complete within 2s fake time');
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, Future<dynamic> operation) async {
  var done = false;
  Object? failure;
  final observed = operation.then<void>((_) {
    done = true;
  }, onError: (Object error) {
    failure = error;
    done = true;
  });
  await _pumpUntil(tester, () => done);
  await observed;
  if (failure != null) throw failure!;
}

Map<String, dynamic> _pendingTrack(int id) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': 60,
    };

class _PendingFixture {
  // Construct stream controllers inside testWidgets fake-async, not setUp.
  late final clock = _PendingClock();
  final requests =
      <({List<int> ids, Completer<Map<String, dynamic>> result})>[];
  late final engine = PlaybackEngine.withClock(
      clock: clock, voiceFactory: () => FakeVoice('pending-test'));
  late final playback = PlaybackState(engine,
      signedAudioUrlService: SignedAudioUrlService.withRequester((body) {
    final result = Completer<Map<String, dynamic>>();
    requests.add((ids: (body['trackIds'] as List).cast<int>(), result: result));
    return result.future;
  }));

  void complete(int index) {
    final request = requests[index];
    request.result.complete({
      'urls': [
        for (final id in request.ids)
          {
            'trackId': id,
            'url': 'https://example.com/$id.mp3',
            'expiresAt': DateTime.utc(2100).toIso8601String(),
          }
      ],
      'unavailable': <Map<String, dynamic>>[],
    });
  }

  Future<void> mount(WidgetTester tester, {double scale = 1}) =>
      tester.pumpWidget(
        ListenableProvider<PlaybackState>.value(
          value: playback,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: const Scaffold(
                body: Align(
                    alignment: Alignment.bottomCenter, child: MiniPlayer())),
          ),
        ),
      );

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Stream cancellation futures need the real event loop to drain; only
    // teardown uses runAsync. Behavior above advances bounded fake time.
    // Stop the pool before closing its injected clock streams.
    await tester
        .runAsync(() => engine.pool.stop().timeout(const Duration(seconds: 2)));
    playback.dispose();
    await tester.pump();
    await tester
        .runAsync(() => clock.dispose().timeout(const Duration(seconds: 2)));
    await tester.pump();
  }
}

class _PendingClock extends DefaultTimelineClock {
  _PendingClock() : super(now: () => DateTime.utc(2026));
  Completer<void>? gate;
  bool seekBlocked = false;
  int playCalls = 0;

  @override
  Future<void> seek(int globalMs) async {
    final pending = gate;
    if (pending != null) {
      seekBlocked = true;
      try {
        await pending.future;
      } finally {
        gate = null;
      }
    }
    await super.seek(globalMs);
  }

  @override
  Future<void> play() async {
    playCalls++;
    await super.play();
  }
}

Color _effectiveTextColor(WidgetTester tester, Finder finder) {
  final element = tester.element(finder);
  final text = tester.widget<Text>(finder);
  return text.style?.color ?? DefaultTextStyle.of(element).style.color!;
}

double _contrastRatio(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground
      : background;
  final darker = identical(lighter, foreground) ? background : foreground;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}

class _MiniPlayerPlaybackState extends Fake implements PlaybackState {
  _MiniPlayerPlaybackState({audio_service.MediaItem? item})
      : _item = item ?? _defaultItem;

  static const _defaultItem = audio_service.MediaItem(
    id: '42',
    title: 'EVERYTHING I HAVE EVER WANTED',
    artist: 'Tiffany Day',
    duration: Duration(minutes: 3),
  );

  final ChangeNotifier _notifier = ChangeNotifier();
  final audio_service.MediaItem _item;

  @override
  bool get hasTrack => true;

  @override
  audio_service.MediaItem get currentItem => _item;

  @override
  Duration get duration => const Duration(minutes: 3);

  @override
  Duration get position => const Duration(minutes: 1);

  @override
  bool get isPlaying => true;

  @override
  bool get isResolvingSignedUrl => false;

  @override
  PlaybackContext get playbackContext => const PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'all the things i desire',
        id: 'playlist-42',
      );

  @override
  Future<void> togglePlayPause() async {}

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  void disposeFake() => _notifier.dispose();
}
