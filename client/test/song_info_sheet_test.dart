import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/player/widgets/song_info_sheet.dart';
import 'package:open_music_player/models/track_analysis.dart';

TrackAnalysis _analyzed({
  Object? bpm = 128,
  Object? key = 'A minor',
  Object? camelot = '8A',
  Object? energy = 0.72,
}) {
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: {
      if (bpm != null) 'bpm': {'value': bpm},
      if (key != null) 'key': {'value': key},
      if (camelot != null) 'camelot': {'value': camelot},
      if (energy != null) 'energy': {'value': energy},
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Future<TrackAnalysis> Function() loader,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SongInfoSheet(
          title: 'Highway to Hell',
          artist: 'AC/DC',
          analysisLoader: loader,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('buildSongInfoDisplay', () {
    test('present analysis exposes tempo, key + camelot, and energy', () {
      final display = buildSongInfoDisplay(_analyzed());

      expect(display.hasData, isTrue);
      final values = {for (final r in display.rows) r.label: r.value};
      expect(values['Tempo'], '128 BPM');
      expect(values['Key'], 'A minor (8A)');
      expect(values['Energy'], '72%');
    });

    test('null analysis is unavailable, not a crash', () {
      final display = buildSongInfoDisplay(null);

      expect(display.hasData, isFalse);
      expect(display.unavailableMessage, contains('unavailable'));
    });

    test('pending analysis reports progress rather than data', () {
      final display = buildSongInfoDisplay(
        TrackAnalysis.fromJson(status: 'pending'),
      );

      expect(display.hasData, isFalse);
      expect(display.unavailableMessage, contains('progress'));
    });

    test('key alone (no camelot) still renders', () {
      final display = buildSongInfoDisplay(
        _analyzed(bpm: null, camelot: null, energy: null),
      );

      final values = {for (final r in display.rows) r.label: r.value};
      expect(values['Key'], 'A minor');
    });
  });

  group('SongInfoSheet widget', () {
    testWidgets('renders analysis values when present', (tester) async {
      await _pump(tester, () async => _analyzed());

      expect(find.text('Highway to Hell'), findsOneWidget);
      expect(find.text('128 BPM'), findsOneWidget);
      expect(find.text('A minor (8A)'), findsOneWidget);
      expect(find.text('72%'), findsOneWidget);
    });

    testWidgets('shows unavailable state when the loader throws',
        (tester) async {
      await _pump(tester, () async => throw StateError('analyzer disabled'));

      expect(find.textContaining('unavailable'), findsOneWidget);
      expect(find.text('128 BPM'), findsNothing);
    });

    testWidgets('shows unavailable state for an empty/failed analysis',
        (tester) async {
      await _pump(
        tester,
        () async => TrackAnalysis.fromJson(status: 'failed'),
      );

      expect(find.textContaining('failed'), findsOneWidget);
    });
  });
}
