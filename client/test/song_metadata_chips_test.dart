import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/song_metadata_chips.dart';

TrackAnalysis _analysis() => TrackAnalysis.fromJson(
  status: 'analyzed',
  summary: {
    'bpm': {'value': 141.18},
    'key': {'value': 'F#m'},
    'camelot': {'value': '11A'},
  },
);

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  testWidgets('defaults to compact Camelot and BPM labels', (tester) async {
    final container = await _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: SongMetadataChips(analysis: _analysis())),
        ),
      ),
    );

    expect(find.text('141.2 BPM'), findsOneWidget);
    expect(find.text('11A'), findsOneWidget);
    expect(find.text('F#m'), findsNothing);
  });

  testWidgets('musical-key preference updates the shared component', (
    tester,
  ) async {
    final container = await _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(body: SongMetadataChips(analysis: _analysis())),
        ),
      ),
    );
    container
        .read(settingsProvider.notifier)
        .setKeyNotation(KeyNotation.musical);
    await tester.pump();

    expect(find.text('F#m'), findsOneWidget);
    expect(find.text('11A'), findsNothing);
  });

  testWidgets('missing analysis renders no placeholder without ProviderScope', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SongMetadataChips(analysis: null)),
      ),
    );

    expect(find.byKey(const ValueKey('song_metadata_chips')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text wraps inside a narrow mobile row without overflow', (
    tester,
  ) async {
    final container = await _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 90,
                child: SongMetadataChips(analysis: _analysis()),
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('song_metadata_bpm_chip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('song_metadata_key_chip')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('override-aware parser feeds the formatter canonical values', () {
    final analysis = trackAnalysisFromTrackJson({
      'analysis_status': 'analyzed',
      'analysis_summary': {
        'bpm': {'value': 120},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
      },
      'analysis_overrides': {
        'bpm': {'value': 128},
        'key': {'value': 'Gm'},
        'camelot': {'value': '6A'},
      },
    });

    final labels = SongMetadataFormatter.labelsFor(
      analysis,
      KeyNotation.camelot,
    );
    expect(labels.bpm, '128 BPM');
    expect(labels.key, '6A');
  });
}
