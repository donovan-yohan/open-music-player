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
}
