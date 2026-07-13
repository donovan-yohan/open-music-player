import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/player/player_screen.dart';

void main() {
  testWidgets('player controls fit at a 320px mobile viewport', (tester) async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    await binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() async {
      await binding.setSurfaceSize(null);
    });

    final flutterErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                child: PlaybackControls(
                  isPlaying: false,
                  shuffleEnabled: false,
                  loopMode: LoopMode.off,
                  onShuffle: () {},
                  onPrevious: () {},
                  onPlayPause: () {},
                  onNext: () {},
                  onLoop: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previousOnError;
    }

    final overflowErrors = flutterErrors.where(
      (error) => error.exceptionAsString().contains('overflowed'),
    );
    expect(overflowErrors, isEmpty);

    final buttons = find.byType(IconButton);
    expect(buttons, findsNWidgets(5));
    for (final element in buttons.evaluate()) {
      final size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('player controls use theme roles and keep callbacks wired', (
    tester,
  ) async {
    for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: PlaybackControls(
              isPlaying: false,
              shuffleEnabled: true,
              loopMode: LoopMode.all,
              onShuffle: () => calls.add('shuffle'),
              onPrevious: () => calls.add('previous'),
              onPlayPause: () => calls.add('play'),
              onNext: () => calls.add('next'),
              onLoop: () => calls.add('loop'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surface = theme.colorScheme.surface;
      for (final icon in [
        Icons.shuffle,
        Icons.skip_previous,
        Icons.skip_next,
        Icons.repeat,
      ]) {
        final color = tester.widget<Icon>(find.byIcon(icon)).color!;
        expect(
          _contrastRatio(color, surface),
          greaterThanOrEqualTo(3),
          reason: '${theme.brightness.name} $icon: $color on $surface',
        );
      }

      final playSurface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player_play_pause_surface')),
      );
      final playBackground = (playSurface.decoration as BoxDecoration).color!;
      final playIcon = tester.widget<Icon>(find.byIcon(Icons.play_arrow));
      expect(
        _contrastRatio(playIcon.color!, playBackground),
        greaterThanOrEqualTo(3),
      );

      for (final icon in [
        Icons.shuffle,
        Icons.skip_previous,
        Icons.play_arrow,
        Icons.skip_next,
        Icons.repeat,
      ]) {
        await tester.tap(find.byIcon(icon));
      }
      expect(calls, ['shuffle', 'previous', 'play', 'next', 'loop']);
    }
  });
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter =
      firstLuminance > secondLuminance ? firstLuminance : secondLuminance;
  final darker =
      firstLuminance > secondLuminance ? secondLuminance : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
