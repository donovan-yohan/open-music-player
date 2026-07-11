import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/widgets/queue_item.dart';

TrackAnalysis _analysis() => TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': 128},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
      },
    );

Track _track() => Track(
      id: 'responsive-row',
      title: 'A long queue title that must retain usable row width',
      artist: 'A long queue artist that must retain usable row width',
      duration: 218,
      addedAt: DateTime.utc(2026),
      analysis: _analysis(),
    );

void main() {
  testWidgets('narrow QueueItem includes reorder handle at 2x and 3x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final track = _track();
    for (final scale in [2.0, 3.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: QueueItem(
                track: track,
                reorderHandle: _productionReorderHandle(track),
              ),
            ),
          ),
        ),
      );

      final trailing = tester.getRect(
        find.byKey(const ValueKey('queue_item_metadata_trailing')),
      );
      final metadata = tester.getRect(
        find.byKey(const ValueKey('song_metadata_chips')),
      );
      final titleRect = tester.getRect(find.text(track.title));
      final artistRect = tester.getRect(find.text(track.artist!));
      final status = tester.getRect(
        find.byKey(ValueKey('queue_status_${track.id}')),
      );

      expect(find.text('128 BPM'), findsOneWidget);
      expect(find.text('8A'), findsOneWidget);
      expect(find.text('Playable'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(ValueKey('reorder_handle_${track.id}')))
            .width,
        44,
      );
      expect(trailing.width, lessThanOrEqualTo((320 - 32) * 0.32 + 0.01));
      expect(metadata.right, closeTo(trailing.right, 0.01));
      expect(titleRect.width, greaterThanOrEqualTo(64));
      expect(artistRect.width, greaterThanOrEqualTo(64));
      expect(titleRect.right, lessThanOrEqualTo(trailing.left));
      expect(artistRect.right, lessThanOrEqualTo(trailing.left));
      for (final key in const [
        ValueKey('song_metadata_bpm_chip'),
        ValueKey('song_metadata_key_chip'),
      ]) {
        expect(
          tester.getSize(find.byKey(key)).width,
          lessThan((320 - 32) * 0.32),
        );
      }
      expect(status.width, lessThanOrEqualTo(320 - 32 - 52));
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
    }
  });
}

Widget _productionReorderHandle(Track track) {
  return Semantics(
    key: ValueKey('reorder_handle_${track.id}'),
    container: true,
    explicitChildNodes: true,
    label: 'Reorder ${track.title}',
    hint: 'Drag vertically to move this queued track',
    child: const SizedBox(
      width: 44,
      height: 48,
      child: Center(child: Icon(Icons.drag_handle)),
    ),
  );
}
