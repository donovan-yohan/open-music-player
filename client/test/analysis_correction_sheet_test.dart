import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/audition_output_route_monitor.dart';
import 'package:open_music_player/core/models/settings_model.dart';
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
    expect(typed.toJson()['manual_timing_v2'], {
      'schema_version': 2,
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

  test('typed and tapped BPM produce the same audible preview', () {
    const effective = TrackAnalysisSummary(
      bpm: AnalysisValue(value: 100),
      beatGrid: BeatGridSummary(
        bpm: 100,
        offsetMs: 100,
        beatsMs: [100, 700, 1300, 1900, 2500, 3100, 3700],
      ),
      downbeats: DownbeatSummary(positionsMs: [700, 3100]),
    );
    const overrides = TrackAnalysisOverrides(
      manualTiming: ManualTimingOverride(
        bpm: 100,
        beatAnchorMs: 100,
        beatsPerBar: 4,
        downbeatPhaseIndex: 1,
      ),
    );
    final tappedBpm = bpmFromTapTimes([0, 500, 1000, 1500]);

    AnalysisTimingAuditionProjection project(double? bpm) =>
        analysisTimingAuditionProjection(
          effectiveSummary: effective,
          existingOverrides: overrides,
          bpm: bpm,
          beatAnchorMs: 100,
          bpmDirty: true,
        );

    final typed = project(120);
    final tapped = project(tappedBpm);
    expect(tapped.sourceBeatsMs, typed.sourceBeatsMs);
    expect(tapped.sourceDownbeatsMs, typed.sourceDownbeatsMs);
    expect(tapped.beatsPerBar, 4);
    expect(tapped.downbeatPhaseIndex, 1);
  });

  test('phase-only audible preview rotates accents without moving beats', () {
    const beats = [100, 600, 1100, 1600, 2100, 2600, 3100, 3600];
    final preview = analysisTimingAuditionProjection(
      effectiveSummary: const TrackAnalysisSummary(
        beatGrid: BeatGridSummary(beatsMs: beats),
        downbeats: DownbeatSummary(positionsMs: [100, 2100]),
      ),
      existingOverrides: const TrackAnalysisOverrides(
        manualTiming: ManualTimingOverride(
          beatsPerBar: 4,
          downbeatPhaseIndex: 0,
        ),
      ),
      beatsPerBar: 4,
      downbeatPhaseIndex: 2,
      phaseDirty: true,
    );

    expect(preview.sourceBeatsMs, beats);
    expect(preview.sourceDownbeatsMs, [1100, 3100]);
  });

  test('unknown meter suppresses generated downbeat accents', () {
    final track = QueueTrack(
      id: '1',
      title: 'Unknown meter',
      duration: 30,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'beat_grid': {
            'beats_ms': [100, 600, 1100, 1600],
          },
          'downbeats': {
            'positions_ms': [100],
          },
        },
      ),
    );

    final preview = analysisTimingAuditionProjectionForTrack(track);
    expect(preview.sourceBeatsMs, [100, 600, 1100, 1600]);
    expect(preview.beatsPerBar, isNull);
    expect(preview.sourceDownbeatsMs, isEmpty);
  });

  test('half/double audible previews preserve anchor, meter, and phase', () {
    const effective = TrackAnalysisSummary(
      bpm: AnalysisValue(value: 120),
      beatGrid: BeatGridSummary(
        bpm: 120,
        offsetMs: 87,
        beatsMs: [87, 587, 1087, 1587, 2087, 2587, 3087, 3587],
      ),
      downbeats: DownbeatSummary(positionsMs: [1587, 3587]),
    );
    const overrides = TrackAnalysisOverrides(
      manualTiming: ManualTimingOverride(
        bpm: 120,
        beatAnchorMs: 87,
        beatsPerBar: 4,
        downbeatPhaseIndex: 3,
      ),
    );

    for (final bpm in [60.0, 240.0]) {
      final preview = analysisTimingAuditionProjection(
        effectiveSummary: effective,
        existingOverrides: overrides,
        bpm: bpm,
        beatAnchorMs: 87,
        bpmDirty: true,
      );
      expect(preview.summary.beatGrid?.offsetMs, 87);
      expect(preview.beatsPerBar, 4);
      expect(preview.downbeatPhaseIndex, 3);
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
    'audition controls and calibration stay independent of route hints',
    (tester) async {
      TrackAnalysisOverrides? saved;
      final previews = <AnalysisClickAuditionPreview>[];
      final volumeWrites = <double>[];
      final accentWrites = <bool>[];
      final offsetWrites = <(ClickAuditionOutputRoute, int)>[];
      final routeListenable = ValueNotifier(
        AuditionOutputRouteObservation.fromConnectedOutputs([
          const AuditionOutputDevice(
            id: 'speaker',
            route: ClickAuditionOutputRoute.speaker,
          ),
        ]),
      );
      final track = QueueTrack(
        id: '1',
        queueItemId: 'queue-occurrence-1',
        title: 'Audition fixture',
        duration: 30,
        addedAt: DateTime.utc(2026, 7, 26),
        analysis: TrackAnalysis.fromJson(
          status: 'analyzed',
          summary: {
            'bpm': {'value': 120},
            'beat_grid': {
              'bpm': 120,
              'offset_ms': 100,
              'beats_ms': [100, 600, 1100, 1600, 2100, 2600, 3100, 3600],
            },
          },
          overrides: {
            'manual_timing_override': {
              'beats_per_bar': 4,
              'downbeat_phase_index': 0,
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
                  clickAudition: AnalysisClickAuditionConfiguration(
                    initialRoute: routeListenable.value,
                    routeListenable: routeListenable,
                    outputOffsetForRoute: (route) =>
                        route == ClickAuditionOutputRoute.speaker ? -25 : 0,
                    onPreviewChanged: previews.add,
                    onVolumeChanged: volumeWrites.add,
                    onDownbeatAccentsChanged: accentWrites.add,
                    onOutputOffsetChanged: (route, offsetMs) =>
                        offsetWrites.add((route, offsetMs)),
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(previews, isNotEmpty);
      expect(previews.last.beatClicksEnabled, isFalse);
      expect(previews.last.downbeatAccentsEnabled, isTrue);
      expect(previews.last.outputOffsetMs, 0);
      expect(
        find.textContaining('active media route unconfirmed'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Active media route unavailable; choose the output you hear.',
        ),
        findsOneWidget,
      );
      final calibrationOutput = find.byKey(
        const ValueKey('analysis_correction_calibration_output'),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<ClickAuditionOutputRoute>>(
              calibrationOutput,
            )
            .initialValue,
        ClickAuditionOutputRoute.unknown,
      );

      final previewCountBeforeConnectedHint = previews.length;
      routeListenable.value =
          AuditionOutputRouteObservation.fromConnectedOutputs([
        const AuditionOutputDevice(
          id: 'headphones',
          route: ClickAuditionOutputRoute.bluetooth,
        ),
      ]);
      await tester.pump();
      expect(previews, hasLength(previewCountBeforeConnectedHint));
      expect(previews.last.outputOffsetMs, 0);
      expect(
        tester
            .widget<DropdownButtonFormField<ClickAuditionOutputRoute>>(
              calibrationOutput,
            )
            .initialValue,
        ClickAuditionOutputRoute.unknown,
      );

      final master =
          find.byKey(const ValueKey('analysis_correction_beat_clicks'));
      tester.widget<SwitchListTile>(master).onChanged!(true);
      await tester.pump();
      expect(previews.last.beatClicksEnabled, isTrue);
      expect(previews.last.downbeatAccentsEnabled, isTrue);

      final accents =
          find.byKey(const ValueKey('analysis_correction_downbeat_accents'));
      tester.widget<SwitchListTile>(accents).onChanged!(false);
      await tester.pump();
      expect(accentWrites, [false]);
      expect(previews.last.beatClicksEnabled, isTrue);
      expect(previews.last.downbeatAccentsEnabled, isFalse);

      tester.widget<SwitchListTile>(master).onChanged!(false);
      await tester.pump();
      tester.widget<SwitchListTile>(accents).onChanged!(true);
      await tester.pump();
      expect(accentWrites, [false, true]);
      expect(previews.last.beatClicksEnabled, isFalse);
      expect(previews.last.downbeatAccentsEnabled, isTrue);
      tester.widget<SwitchListTile>(master).onChanged!(true);
      await tester.pump();
      expect(previews.last.beatClicksEnabled, isTrue);
      expect(previews.last.downbeatAccentsEnabled, isTrue);

      final volumeFinder =
          find.byKey(const ValueKey('analysis_correction_audition_volume'));
      tester.widget<Slider>(volumeFinder).onChanged!(0.55);
      await tester.pump();
      expect(volumeWrites, [0.55]);
      expect(previews.last.volume, 0.55);

      tester
          .widget<DropdownButtonFormField<ClickAuditionOutputRoute>>(
            calibrationOutput,
          )
          .onChanged!(ClickAuditionOutputRoute.speaker);
      await tester.pump();
      expect(previews.last.outputOffsetMs, -25);

      final offsetFinder =
          find.byKey(const ValueKey('analysis_correction_output_offset'));
      final previewCountBeforeDrag = previews.length;
      tester.widget<Slider>(offsetFinder).onChanged!(-75);
      await tester.pump();
      tester.widget<Slider>(offsetFinder).onChanged!(-100);
      await tester.pump();
      tester.widget<Slider>(offsetFinder).onChanged!(-125);
      await tester.pump();
      expect(offsetWrites, isEmpty);
      expect(previews, hasLength(previewCountBeforeDrag));
      expect(previews.last.outputOffsetMs, -25);
      expect(find.textContaining('125 ms earlier'), findsOneWidget);

      tester.widget<Slider>(offsetFinder).onChangeEnd!(-125);
      await tester.pump();
      expect(
        offsetWrites,
        [(ClickAuditionOutputRoute.speaker, -125)],
      );
      expect(previews.last.outputOffsetMs, -125);
      expect(previews, hasLength(previewCountBeforeDrag + 1));

      final reset = find.byKey(
        const ValueKey('analysis_correction_output_offset_reset'),
      );
      tester.widget<TextButton>(reset).onPressed!();
      await tester.pump();
      expect(
        offsetWrites,
        [
          (ClickAuditionOutputRoute.speaker, -125),
          (ClickAuditionOutputRoute.speaker, 0),
        ],
      );
      expect(previews.last.outputOffsetMs, 0);
      expect(
        find.text('Output offset: aligned (0 ms)'),
        findsOneWidget,
      );

      final previewCountBeforeInvalidInput = previews.length;
      await tester.enterText(
        find.byKey(const ValueKey('analysis_correction_bpm')),
        'not-a-number',
      );
      await tester.pump();
      expect(previews, hasLength(previewCountBeforeInvalidInput));
      await tester.enterText(
        find.byKey(const ValueKey('analysis_correction_bpm')),
        '130',
      );
      await tester.pump();
      expect(previews, hasLength(previewCountBeforeInvalidInput + 1));

      await tester.enterText(
        find.byKey(const ValueKey('analysis_correction_meter')),
        '3',
      );
      await tester.pump();
      expect(previews.last.sourceDownbeatsMs, isEmpty);
      expect(previews.last.downbeatAccentsEnabled, isFalse);
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('analysis_correction_phase_right')),
          )
          .onPressed!();
      await tester.pump();
      expect(previews.last.sourceDownbeatsMs, isNotEmpty);
      expect(previews.last.downbeatAccentsEnabled, isTrue);

      final save = find.byKey(const ValueKey('analysis_correction_save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      final payload = saved!.toJson(includeServerMetadata: false);
      expect(payload, contains('manual_timing_override'));
      expect(payload.toString(), isNot(contains('clickAudition')));
      expect(payload.toString(), isNot(contains('outputOffset')));
      expect(payload.toString(), isNot(contains('volume')));
      routeListenable.dispose();
    },
  );

  testWidgets('confirmed active route initializes its calibration profile',
      (tester) async {
    final previews = <AnalysisClickAuditionPreview>[];
    final track = QueueTrack(
      id: '1',
      title: 'Confirmed route fixture',
      duration: 30,
      addedAt: DateTime.utc(2026, 7, 26),
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'beat_grid': {
            'beats_ms': [100, 600, 1100, 1600],
          },
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showAnalysisCorrectionSheet(
              context: context,
              track: track,
              clickAudition: AnalysisClickAuditionConfiguration(
                initialRoute:
                    AuditionOutputRouteObservation.confirmedActiveRoute(
                  ClickAuditionOutputRoute.speaker,
                ),
                outputOffsetForRoute: (route) =>
                    route == ClickAuditionOutputRoute.speaker ? -40 : 0,
                onPreviewChanged: previews.add,
              ),
            ),
            child: const Text('Edit'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(previews.last.outputOffsetMs, -40);
    expect(
      tester
          .widget<DropdownButtonFormField<ClickAuditionOutputRoute>>(
            find.byKey(
              const ValueKey('analysis_correction_calibration_output'),
            ),
          )
          .initialValue,
      ClickAuditionOutputRoute.speaker,
    );
    expect(
      find.byKey(
        const ValueKey('analysis_correction_output_route_guidance'),
      ),
      findsNothing,
    );
    expect(find.text('Device speaker (active media route)'), findsOneWidget);

    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
        .onPressed!();
    await tester.pumpAndSettle();
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
    expect(request['manual_timing_v2'], {'schema_version': 2});
    expect(
        request['key'], {'value': 'D minor', 'provenance': 'manual_override'});
    expect(request, isNot(contains('bpm')));
    expect(request, isNot(contains('beat_grid')));
    expect(request, isNot(contains('downbeats')));
  });
}
