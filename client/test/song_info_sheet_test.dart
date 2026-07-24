import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/player/widgets/song_info_sheet.dart';
import 'package:open_music_player/models/track_analysis.dart';

TrackAnalysis _analyzed({
  Object? bpm = 128,
  Object? key = 'A minor',
  Object? camelot = '8A',
  Object? energy = 0.72,
  Object? loudness = -11.4,
}) {
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: {
      if (bpm != null) 'bpm': {'value': bpm},
      if (key != null) 'key': {'value': key},
      if (camelot != null) 'camelot': {'value': camelot},
      if (energy != null) 'energy': {'value': energy},
      if (loudness != null) 'loudness': {'integrated_lufs': loudness},
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Future<TrackAnalysis> Function() loader, {
  String? sourceQuality,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SongInfoSheet(
          title: 'Highway to Hell',
          artist: 'AC/DC',
          sourceQuality: sourceQuality,
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
      expect(values['Loudness'], '-11.4 LUFS');
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

    testWidgets('renders truthful source quality with unavailable analysis', (
      tester,
    ) async {
      await _pump(
        tester,
        () async => throw StateError('analyzer disabled'),
        sourceQuality: 'MP3 · 137 kbps · 44.1 kHz · 2 channels · 3.2 MB',
      );

      expect(
        find.byKey(const ValueKey('song_info_source_quality')),
        findsOneWidget,
      );
      expect(
        find.text('MP3 · 137 kbps · 44.1 kHz · 2 channels · 3.2 MB'),
        findsOneWidget,
      );
      expect(find.textContaining('unavailable'), findsOneWidget);
    });

    testWidgets('omits the source row when metadata is absent', (tester) async {
      await _pump(tester, () async => _analyzed());

      expect(
        find.byKey(const ValueKey('song_info_source_quality')),
        findsNothing,
      );
      expect(find.text('Source'), findsNothing);
    });

    testWidgets('full quality sheet scrolls at narrow width and 3x text',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(3),
            ),
            child: Scaffold(
              body: SongInfoSheet(
                title: 'Highway to Hell',
                artist: 'AC/DC',
                sourceQuality:
                    'MP3 · 137 kbps · 44.1 kHz · 2 channels · 3.2 MB',
                analysisLoader: () async => _analyzed(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('song_info_source_quality')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -300));
      await tester.pump();
      expect(find.text('-11.4 LUFS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows unavailable state when the loader throws', (
      tester,
    ) async {
      await _pump(tester, () async => throw StateError('analyzer disabled'));

      expect(find.textContaining('unavailable'), findsOneWidget);
      expect(find.text('128 BPM'), findsNothing);
    });

    testWidgets('shows unavailable state for an empty/failed analysis', (
      tester,
    ) async {
      await _pump(tester, () async => TrackAnalysis.fromJson(status: 'failed'));

      expect(find.textContaining('failed'), findsOneWidget);
    });

    testWidgets('shows refresh state for stale analysis', (tester) async {
      await _pump(tester, () async => TrackAnalysis.fromJson(status: 'stale'));

      expect(find.textContaining('refreshed'), findsOneWidget);
    });
  });
}
