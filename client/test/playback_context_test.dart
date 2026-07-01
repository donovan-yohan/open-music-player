import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/features/player/widgets/playback_context_label.dart';

void main() {
  group('PlaybackContext model', () {
    test('value equality across kind/label/id', () {
      const a = PlaybackContext(
        kind: PlaybackContextKind.album,
        label: 'Back in Black',
        id: 'r-1',
      );
      const b = PlaybackContext(
        kind: PlaybackContextKind.album,
        label: 'Back in Black',
        id: 'r-1',
      );
      const different = PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'Back in Black',
        id: 'r-1',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(different)));
    });

    test('id is optional', () {
      const ctx =
          PlaybackContext(kind: PlaybackContextKind.library, label: 'Library');
      expect(ctx.id, isNull);
      expect(ctx.label, 'Library');
    });
  });

  group('PlaybackContextLabel widget', () {
    testWidgets('renders "Playing from <label>" when a context is set',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PlaybackContextLabel(
              PlaybackContext(
                kind: PlaybackContextKind.album,
                label: 'Discovery',
              ),
            ),
          ),
        ),
      );

      expect(find.text('Playing from Discovery'), findsOneWidget);
      expect(find.byKey(const ValueKey('playing_from_label')), findsOneWidget);
    });

    testWidgets('collapses to nothing when the context is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: PlaybackContextLabel(null)),
        ),
      );

      expect(find.byKey(const ValueKey('playing_from_label')), findsNothing);
      expect(find.textContaining('Playing from'), findsNothing);
    });
  });
}
