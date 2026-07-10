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

TrackAnalysis _analysisForKey(String musicalKey, String camelot) =>
    TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': 128},
        'key': {'value': musicalKey},
        'camelot': {'value': camelot},
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
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: 20,
                child: SongMetadataChips(analysis: _analysis()),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('141.2 BPM'), findsOneWidget);
    expect(find.text('11A'), findsOneWidget);
    expect(find.text('F#m'), findsNothing);
  });

  testWidgets('centers labels inside stable metadata pills', (tester) async {
    final container = await _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: 20,
                child: SongMetadataChips(analysis: _analysis()),
              ),
            ),
          ),
        ),
      ),
    );

    for (final entry in <(Key, String)>[
      (const ValueKey('song_metadata_bpm_chip'), '141.2 BPM'),
      (const ValueKey('song_metadata_key_chip'), '11A'),
    ]) {
      final chipCenter = tester.getCenter(find.byKey(entry.$1));
      final labelCenter = tester.getCenter(find.text(entry.$2));
      expect((chipCenter.dy - labelCenter.dy).abs(), lessThan(0.5));
      expect(tester.getSize(find.byKey(entry.$1)).height, 20);
    }
  });

  testWidgets('compact pills stay centered at dense timeline height', (
    tester,
  ) async {
    final container = await _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: 18,
                child: SongMetadataChips(
                  analysis: _analysis(),
                  singleLine: true,
                  compact: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final chip = find.byKey(const ValueKey('song_metadata_bpm_chip'));
    expect(tester.getSize(chip).height, 18);
    expect(
      (tester.getCenter(chip).dy - tester.getCenter(find.text('141.2 BPM')).dy)
          .abs(),
      lessThan(0.5),
    );
  });

  testWidgets('maps Camelot neighbors around a stable color wheel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Column(
            children: [
              SongMetadataChips(analysis: _analysisForKey('F#m', '11A')),
              SongMetadataChips(analysis: _analysisForKey('B', '11B')),
              SongMetadataChips(analysis: _analysisForKey('Bm', '10A')),
            ],
          ),
        ),
      ),
    );

    BoxDecoration decorationFor(String label) {
      final chip = find.ancestor(
        of: find.text(label),
        matching: find.byKey(const ValueKey('song_metadata_key_chip')),
      );
      final container = find.descendant(
        of: chip,
        matching: find.byType(Container),
      );
      return tester.widget<Container>(container).decoration! as BoxDecoration;
    }

    final minor11 = decorationFor('11A');
    final major11 = decorationFor('11B');
    final minor10 = decorationFor('10A');
    final hue11A = HSVColor.fromColor(minor11.color!).hue;
    final hue11B = HSVColor.fromColor(major11.color!).hue;
    final hue10A = HSVColor.fromColor(minor10.color!).hue;

    expect(hue11A, closeTo(hue11B, 0.01));
    expect((hue11A - hue10A).abs(), closeTo(30, 0.5));
    expect(minor11.color, isNot(major11.color));
    expect(minor11.color!.a, 1);
    expect(minor11.border, isNull);
  });

  testWidgets('uses opaque solid fills without outline borders',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SongMetadataChips(analysis: _analysis())),
      ),
    );

    for (final label in ['141.2 BPM', '11A']) {
      final chip = find.ancestor(
        of: find.text(label),
        matching: find.byKey(
          label == '141.2 BPM'
              ? const ValueKey('song_metadata_bpm_chip')
              : const ValueKey('song_metadata_key_chip'),
        ),
      );
      final container = find.descendant(
        of: chip,
        matching: find.byType(Container),
      );
      final decoration =
          tester.widget<Container>(container).decoration! as BoxDecoration;
      expect(decoration.color!.a, 1);
      expect(decoration.border, isNull);
    }
  });

  testWidgets('all Camelot pills meet text contrast in light and dark themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      for (var number = 1; number <= 12; number++) {
        for (final suffix in ['A', 'B']) {
          final camelot = '$number$suffix';
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(
                body: Center(
                  child: SongMetadataChips(
                    analysis: _analysisForKey('F minor', camelot),
                  ),
                ),
              ),
            ),
          );

          final chip = find.ancestor(
            of: find.text(camelot),
            matching: find.byKey(const ValueKey('song_metadata_key_chip')),
          );
          final container = find.descendant(
            of: chip,
            matching: find.byType(Container),
          );
          final decoration =
              tester.widget<Container>(container).decoration! as BoxDecoration;
          final foreground =
              tester.widget<Text>(find.text(camelot)).style!.color!;
          final contrast = _contrastRatio(foreground, decoration.color!);
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '$camelot ${brightness.name} contrast was $contrast',
          );
        }
      }
    }
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

  testWidgets(
    'keeps compact trailing metadata visible and right aligned at 135px',
    (tester) async {
      final container = await _container();
      const availableWidth = 135.0;
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SizedBox(
                  width: availableWidth,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SongMetadataChips(
                      analysis: _analysis(),
                      singleLine: true,
                      compact: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final group = tester.getRect(
        find.byKey(const ValueKey('song_metadata_chips')),
      );
      expect(group.right, closeTo(availableWidth, 0.01));
      for (final entry in <(Key, String)>[
        (const ValueKey('song_metadata_bpm_chip'), '141.2 BPM'),
        (const ValueKey('song_metadata_key_chip'), '11A'),
      ]) {
        final chip = find.byKey(entry.$1);
        final chipRect = tester.getRect(chip);
        expect(find.text(entry.$2), findsOneWidget);
        expect(chipRect.right, lessThanOrEqualTo(group.right));
        expect(chipRect.width, lessThan(availableWidth));
        expect(tester.getSize(chip).height, greaterThanOrEqualTo(18));
        expect(
          (tester.getCenter(chip).dy - tester.getCenter(find.text(entry.$2)).dy)
              .abs(),
          lessThan(0.5),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

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
    expect(labels.camelot, '6A');
  });

  test('BPM formatter removes a decimal after rounding to an integer', () {
    expect(SongMetadataFormatter.formatBpm(120.95), '121 BPM');
    expect(SongMetadataFormatter.formatBpm(138.08), '138 BPM');
    expect(SongMetadataFormatter.formatBpm(141.18), '141.2 BPM');
  });
}

double _contrastRatio(Color foreground, Color background) {
  final lighter = foreground.computeLuminance() > background.computeLuminance()
      ? foreground.computeLuminance()
      : background.computeLuminance();
  final darker = foreground.computeLuminance() > background.computeLuminance()
      ? background.computeLuminance()
      : foreground.computeLuminance();
  return (lighter + 0.05) / (darker + 0.05);
}
