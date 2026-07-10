import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

TrackAnalysis _analysis() => TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': 128},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
      },
    );

void main() {
  testWidgets('active track tile surfaces a now-playing badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Get Your Wish',
            artist: 'Porter Robinson',
            album: 'Nurture',
            duration: '3:38',
            isCurrent: true,
            activeLabel: 'Now playing',
          ),
        ),
      ),
    );

    expect(find.text('Get Your Wish'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.byIcon(Icons.equalizer), findsOneWidget);
  });

  testWidgets('keeps metadata as a compact trailing group on narrow rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'A deliberately long song title for a narrow phone',
            artist: 'An artist with a deliberately long name',
            duration: '3:38',
            analysis: _analysis(),
          ),
        ),
      ),
    );

    final metadata = find.byKey(const ValueKey('song_metadata_chips'));
    final metadataRect = tester.getRect(metadata);
    final titleRect = tester.getRect(
      find.text('A deliberately long song title for a narrow phone'),
    );
    final artistRect = tester.getRect(
      find.text('An artist with a deliberately long name'),
    );
    final durationRect = tester.getRect(find.text('3:38'));

    expect(metadataRect.left, greaterThan(titleRect.left));
    expect(titleRect.right, lessThanOrEqualTo(metadataRect.left));
    expect(artistRect.right, lessThanOrEqualTo(metadataRect.left));
    expect(metadataRect.right, lessThan(durationRect.left));
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byKey(const ValueKey('song_metadata_bpm_chip')),
              matching: find.byType(Container),
            ),
          )
          .height,
      18,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('enlarged text stays inside solid pills on a generic song row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: TrackTile(
              title: 'Accessible metadata row',
              artist: 'Scaled artist',
              duration: '3:38',
              analysis: _analysis(),
            ),
          ),
        ),
      ),
    );

    for (final entry in <(Key, String)>[
      (const ValueKey('song_metadata_bpm_chip'), '128 BPM'),
      (const ValueKey('song_metadata_key_chip'), '8A'),
    ]) {
      final chip = find.byKey(entry.$1);
      final fill = find.descendant(of: chip, matching: find.byType(Container));
      final fillRect = tester.getRect(fill);
      final textRect = tester.getRect(find.text(entry.$2));
      final decoration =
          tester.widget<Container>(fill).decoration! as BoxDecoration;

      expect(fillRect.height, greaterThan(18));
      expect(textRect.left, greaterThanOrEqualTo(fillRect.left));
      expect(textRect.top, greaterThanOrEqualTo(fillRect.top));
      expect(textRect.right, lessThanOrEqualTo(fillRect.right));
      expect(textRect.bottom, lessThanOrEqualTo(fillRect.bottom));
      expect(decoration.color, isNotNull);
      expect(decoration.border, isNull);
    }
    expect(tester.takeException(), isNull);
  });
}
