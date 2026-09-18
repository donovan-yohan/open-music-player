import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

Finder _action(String id) => find.byKey(ValueKey('action_$id'));

FocusNode _focus(WidgetTester tester, String id) => Focus.of(tester.element(
      find.descendant(of: _action(id), matching: find.byIcon(Icons.favorite)),
    ));

Future<void> _pump(WidgetTester tester, FakePlayback playback, bool metadata,
    List<String> activated) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(playback.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
    value: playback,
    child: MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(
            textScaler: TextScaler.linear(metadata ? 1 : 2),
          ),
          child: Column(children: [
            for (final id in ['A', 'B'])
              TrackTile(
                trackId: id,
                title: 'Track $id',
                artist: 'Artist $id',
                duration: '3:38',
                analysis: metadata
                    ? TrackAnalysis.fromJson(status: 'analyzed', summary: {
                        'bpm': {'value': 128},
                        'camelot': {'value': '8A'},
                      })
                    : null,
                action: IconButton(
                  key: ValueKey('action_$id'),
                  icon: const Icon(Icons.favorite),
                  onPressed: () => activated.add(id),
                ),
                onTap: () => activated.add('row_$id'),
                onMorePressed: () => activated.add('more_$id'),
              ),
          ]),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final metadata in [true, false]) {
    final layout = metadata ? 'metadata normal' : 'no metadata enlarged';
    for (final id in ['A', 'B']) {
      testWidgets('$layout action $id retains element focus and keyboard',
          (tester) async {
        final playback = FakePlayback()..set(makeSnapshot(id: null));
        final activated = <String>[];
        await _pump(tester, playback, metadata, activated);
        final element = tester.element(_action(id));
        final node = _focus(tester, id);
        node.requestFocus();
        await tester.pump();
        expect(node.hasFocus, isTrue);
        for (final selected in ['A', 'B', null]) {
          playback.set(makeSnapshot(id: selected));
          await tester.pump();
          expect(tester.element(_action(id)), same(element));
          expect(_focus(tester, id), same(node));
          expect(node.hasFocus, isTrue);
          final before = activated.length;
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(activated.length, before + 1);
          expect(activated.last, id);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
      testWidgets('$layout action $id completes held pointer across A B clear',
          (tester) async {
        final playback = FakePlayback()..set(makeSnapshot(id: null));
        final activated = <String>[];
        await _pump(tester, playback, metadata, activated);
        // One real press per transition, plus a press spanning the whole cycle.
        for (final sequence in <List<String?>>[
          ['A'],
          ['B'],
          [null],
          ['A', 'B', null],
        ]) {
          final before = activated.length;
          final gesture = await tester.startGesture(
            tester.getCenter(_action(id)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          for (final selected in sequence) {
            playback.set(makeSnapshot(id: selected));
            await tester.pump();
          }
          await gesture.up();
          await tester.pump();
          expect(activated.length, before + 1);
          expect(activated.last, id);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
