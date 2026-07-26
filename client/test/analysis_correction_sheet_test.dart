import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/widgets/analysis_correction_sheet.dart';

void main() {
  test('typed and tapped BPM share one normalized timing command', () {
    final typed = manualTimingOverridesFromFields(
      bpm: 120,
      beatAnchorMs: 87,
      beatsPerBar: 4,
      downbeatPhaseIndex: 2,
      phraseLengthBars: 8,
      musicalKey: 'A minor',
      camelot: '8A',
    );
    final tappedBpm = bpmFromTapTimes([0, 500, 1000, 1500]);
    final tapped = manualTimingOverridesFromFields(
      bpm: tappedBpm,
      beatAnchorMs: 87,
      beatsPerBar: 4,
      downbeatPhaseIndex: 2,
      phraseLengthBars: 8,
      musicalKey: 'A minor',
      camelot: '8A',
    );

    expect(tappedBpm, 120);
    expect(tapped.toJson(), typed.toJson());
    expect(typed.toJson()['manual_timing_override'], {
      'bpm': 120.0,
      'beat_anchor_ms': 87,
      'beats_per_bar': 4,
      'downbeat_phase_index': 2,
      'phrase_length_bars': 8,
      'confidence': 1.0,
      'provenance': 'manual_override',
    });
  });

  test('phase rotation preserves every existing beat timestamp', () {
    const originalBeats = [87, 587, 1087, 1587, 2087, 2587, 3087, 3587];
    const original = ManualTimingOverride(
      beatsPerBar: 4,
      downbeatPhaseIndex: 0,
    );

    for (var direction = -8; direction <= 8; direction++) {
      final rotated = rotateDownbeatPhase(original, direction: direction);
      final projected = rotated.applyTo(
        const TrackAnalysisSummary(
          beatGrid: BeatGridSummary(beatsMs: originalBeats),
        ),
      );
      expect(projected.beatGrid?.beatsMs, originalBeats);
      expect(
        projected.downbeats?.positionsMs,
        [
          for (var i = rotated.normalizedDownbeatPhaseIndex!;
              i < originalBeats.length;
              i += 4)
            originalBeats[i]
        ],
      );
    }
  });

  test('set current beat selects nearest existing beat phase only', () {
    const beats = [100, 600, 1100, 1600, 2100];
    final timing = setCurrentBeatAsDownbeat(
      const ManualTimingOverride(beatsPerBar: 4, downbeatPhaseIndex: 0),
      existingBeatsMs: beats,
      currentMs: 1040,
    );

    expect(timing.downbeatPhaseIndex, 2);
    expect(beats, [100, 600, 1100, 1600, 2100]);
  });

  test('unknown meter never manufactures downbeats', () {
    final timing = manualTimingOverridesFromFields(
      bpm: 120,
      beatAnchorMs: 100,
      downbeatPhaseIndex: 2,
    ).manualTiming!;
    final projected = timing.applyTo(
      const TrackAnalysisSummary(
        beatGrid: BeatGridSummary(beatsMs: [100, 600, 1100, 1600]),
      ),
    );

    expect(timing.normalizedDownbeatPhaseIndex, isNull);
    expect(projected.downbeats, isNull);
  });

  test('half and double BPM preserve anchor and phase facts', () {
    const original = ManualTimingOverride(
      bpm: 120,
      beatAnchorMs: 87,
      beatsPerBar: 4,
      downbeatPhaseIndex: 3,
    );

    final half = scaleManualBpm(original, .5);
    final doubled = scaleManualBpm(original, 2);

    expect(half.bpm, 60);
    expect(doubled.bpm, 240);
    for (final timing in [half, doubled]) {
      expect(timing.beatAnchorMs, 87);
      expect(timing.downbeatPhaseIndex, 3);
    }
  });

  test('timing facts clear only downbeats invalidated by their projection', () {
    const base = TrackAnalysisSummary(
      beatGrid: BeatGridSummary(
        bpm: 120,
        offsetMs: 100,
        beatsMs: [100, 600, 1100, 1600, 2100],
      ),
      downbeats: DownbeatSummary(positionsMs: [100, 2100]),
    );

    for (final timing in const [
      ManualTimingOverride(bpm: 120),
      ManualTimingOverride(beatAnchorMs: 100),
      ManualTimingOverride(beatsPerBar: 4),
    ]) {
      expect(timing.applyTo(base).downbeats, isNull);
    }

    for (final timing in const [
      ManualTimingOverride(phraseLengthBars: 8),
      ManualTimingOverride(revision: 3),
    ]) {
      expect(timing.applyTo(base).downbeats?.positionsMs, [100, 2100]);
    }
  });

  testWidgets('editor keeps anchor, meter, phase, and phrase controls separate',
      (tester) async {
    final track = QueueTrack(
      id: '1',
      title: 'Fixture',
      duration: 120,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'beat_grid': {
            'beats_ms': [100, 600, 1100, 1600]
          },
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalysisCorrectionSheet(
            track: track,
            currentSourcePositionMs: 1040,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('analysis_correction_anchor')),
      findsOneWidget,
    );
    final anchorField = tester.widget<TextField>(
      find.byKey(const ValueKey('analysis_correction_anchor')),
    );
    expect(anchorField.controller?.text, '100');
    expect(find.byKey(const ValueKey('analysis_correction_meter')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey('analysis_correction_phrase_length_bars')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_meter')),
      '4',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('analysis_correction_set_current_downbeat')),
    );
    await tester.pump();

    expect(find.text('Downbeat phase: beat 3'), findsOneWidget);
  });

  testWidgets('generated timing shown in the editor is not saved unchanged',
      (tester) async {
    final track = QueueTrack(
      id: '1',
      title: 'Generated fixture',
      duration: 120,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 128},
          'beat_grid': {
            'offset_ms': 100,
            'beats_ms': [100, 569, 1038, 1507],
          },
          'key': {'value': 'A minor'},
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: AnalysisCorrectionSheet(track: track))),
    );

    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('analysis_correction_error')),
      findsOneWidget,
    );
    expect(find.text('Enter at least one correction.'), findsOneWidget);
  });

  testWidgets('BPM-only save persists the displayed generated anchor',
      (tester) async {
    TrackAnalysisOverrides? saved;
    final track = QueueTrack(
      id: '1',
      title: 'Generated anchor fixture',
      duration: 120,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 128},
          'beat_grid': {
            'offset_ms': 100,
            'beats_ms': [100, 569, 1038, 1507],
          },
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              saved = await showAnalysisCorrectionSheet(
                context: context,
                track: track,
              );
            },
            child: const Text('Edit'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_bpm')),
      '130',
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    expect(saved?.manualTiming?.bpm, 130);
    expect(saved?.manualTiming?.beatAnchorMs, 100);
  });

  testWidgets('phase correction keeps generated BPM and anchor out of the save',
      (tester) async {
    TrackAnalysisOverrides? saved;
    final track = QueueTrack(
      id: '1',
      title: 'Phase fixture',
      duration: 120,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 128},
          'beat_grid': {
            'offset_ms': 100,
            'beats_ms': [100, 569, 1038, 1507],
          },
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              saved = await showAnalysisCorrectionSheet(
                context: context,
                track: track,
                currentSourcePositionMs: 1040,
              );
            },
            child: const Text('Edit'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_meter')),
      '4',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('analysis_correction_set_current_downbeat')),
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    expect(saved?.manualTiming?.bpm, isNull);
    expect(saved?.manualTiming?.beatAnchorMs, isNull);
    expect(saved?.manualTiming?.beatsPerBar, 4);
    expect(saved?.manualTiming?.downbeatPhaseIndex, 2);
  });

  testWidgets(
      'key-only save migrates legacy timing without replaying compact markers',
      (tester) async {
    TrackAnalysisOverrides? saved;
    final legacyBeats = List<int>.generate(129, (index) => 100 + index * 500);
    final track = QueueTrack(
      id: '1',
      title: 'Legacy fixture',
      duration: 120,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'beat_grid': {'beats_ms': legacyBeats},
        },
        overrides: {
          'bpm': {'value': 120},
          'beat_grid': {'beats_ms': legacyBeats},
          'downbeats': {
            'positions_ms': [100, 2100]
          },
          'key': {'value': 'A minor'},
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              saved = await showAnalysisCorrectionSheet(
                context: context,
                track: track,
              );
            },
            child: const Text('Edit'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_key')),
      'D minor',
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    final request = saved!.toJson(includeServerMetadata: false);
    expect(request['manual_timing_override'], isEmpty);
    expect(
        request['key'], {'value': 'D minor', 'provenance': 'manual_override'});
    expect(request, isNot(contains('bpm')));
    expect(request, isNot(contains('beat_grid')));
    expect(request, isNot(contains('downbeats')));
  });
}
