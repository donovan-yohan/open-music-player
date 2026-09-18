import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';
import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

TrackAnalysis _analysis() =>
    TrackAnalysis.fromJson(status: 'analyzed', summary: {
      'bpm': {'value': 128},
      'key': {'value': 'Am'},
      'camelot': {'value': '8A'},
    });

void main() {
  for (final width in [320.0, 390.0, 480.0, 800.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets(
          'compact metadata row $width at $scale retains geometry across selection',
          (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playback = FakePlayback()..set(makeSnapshot(id: null));
        addTearDown(playback.dispose);
        await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
            value: playback,
            child: MaterialApp(
                home: Scaffold(
                    body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: TrackTile(
                  trackId: 'A',
                  title: 'A long readable title',
                  artist: 'A long readable artist',
                  duration: '3:38',
                  analysis: _analysis()),
            )))));
        final row = find.byType(TrackTile);
        final height = tester.getSize(row).height;
        final title = tester.getRect(find.text('A long readable title'));
        final artist = tester.getRect(find.text('A long readable artist'));
        final metadata =
            tester.getRect(find.byKey(const ValueKey('song_metadata_chips')));
        final actions =
            tester.getRect(find.byKey(const ValueKey('track_tile_actions')));
        expect(title.width, greaterThanOrEqualTo(64));
        expect(artist.left, title.left);
        expect(metadata.left, greaterThanOrEqualTo(title.right));
        expect(actions.right, closeTo(width - 16, 0.01));
        expect(find.text('128 BPM'), findsOneWidget);
        expect(find.text('8A'), findsOneWidget);
        if (scale == 1) {
          expect(height, 72);
          expect(metadata.center.dy, closeTo(actions.center.dy, 0.01));
          expect(
              metadata.center.dy, inInclusiveRange(title.top, artist.bottom));
        } else {
          // Enlarged labels grow/wrap, never scale down inside their solid pills.
          for (final entry in <(Key, String)>[
            (const ValueKey('song_metadata_bpm_chip'), '128 BPM'),
            (const ValueKey('song_metadata_key_chip'), '8A'),
          ]) {
            final fill = find.descendant(
                of: find.byKey(entry.$1), matching: find.byType(Container));
            final rect = tester.getRect(fill);
            final text = tester.getRect(find.text(entry.$2));
            final decoration =
                tester.widget<Container>(fill).decoration! as BoxDecoration;
            expect(rect.height, greaterThan(18));
            expect(text.left, greaterThanOrEqualTo(rect.left));
            expect(text.top, greaterThanOrEqualTo(rect.top));
            expect(text.right, lessThanOrEqualTo(rect.right));
            expect(text.bottom, lessThanOrEqualTo(rect.bottom));
            expect(decoration.color, isNotNull);
            expect(decoration.border, isNull);
          }
        }
        for (final playing in [true, false]) {
          playback.set(makeSnapshot(playing: playing));
          await tester.pump();
          expect(tester.getSize(row).height, height);
          expect(
              tester.getRect(find.byKey(const ValueKey('track_tile_actions'))),
              actions);
          expect(find.text('Now playing'), findsNothing);
          expect(find.byIcon(playing ? Icons.equalizer : Icons.pause),
              findsOneWidget);
          expect(
              find.byWidgetPredicate((w) =>
                  w is Semantics &&
                  w.properties.label ==
                      (playing ? 'Now playing' : 'Paused here')),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      });
    }
  }
}
