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
