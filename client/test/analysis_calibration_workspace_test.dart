import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/widgets/analysis_calibration_waveform.dart';
import 'package:open_music_player/widgets/analysis_correction_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('waveform preview consumes one effective marker projection', () {
    final track = _track();
    const beats = [100, 600, 1100, 1600];
    const downbeats = [600];

    final waveform = calibrationWaveformDataForTrack(
      track: track,
      beatsMs: beats,
      downbeatsMs: downbeats,
    );

    expect(waveform.beatsMs, beats);
    expect(waveform.downbeatsMs, downbeats);
    expect(waveform.frames, isNotEmpty);
    expect(track.analysis?.summary?.beatGrid?.beatsMs, isNot(beats));
  });

  testWidgets('adaptive presenter keeps mobile sheet and bounds desktop dialog',
      (tester) async {
    Future<void> openAt(double width, double height) async {
      tester.view
        ..physicalSize = Size(width, height)
        ..devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showAnalysisCorrectionEditor(
                context: context,
                track: _track(),
              ),
              child: const Text('Edit timing'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit timing'));
      await tester.pumpAndSettle();
    }

    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await openAt(900, 760);
    expect(
      find.byKey(const ValueKey('analysis_correction_sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('analysis_correction_desktop_dialog')),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    for (final viewport in const [
      (width: 1024.0, height: 768.0),
      (width: 1440.0, height: 900.0),
    ]) {
      await openAt(viewport.width, viewport.height);
      final workspace = find.byKey(
        const ValueKey('analysis_correction_desktop_workspace'),
      );
      final dialog = find.byKey(
        const ValueKey('analysis_correction_desktop_dialog'),
      );
      expect(workspace, findsOneWidget);
      expect(dialog, findsOneWidget);
      expect(
        find.byKey(const ValueKey('analysis_correction_anchor')),
        findsNothing,
        reason: 'desktop common flow must not require raw milliseconds',
      );
      expect(
        tester.getSize(workspace).width,
        lessThanOrEqualTo(
          (viewport.width - 48).clamp(0, 1240).toDouble(),
        ),
      );
      expect(
        tester
            .getCenter(
              find.byKey(const ValueKey('analysis_workspace_waveform')),
            )
            .dx,
        lessThan(
          tester
              .getCenter(
                find.byKey(const ValueKey('analysis_correction_bpm')),
              )
              .dx,
        ),
        reason: 'desktop calibration stays a two-pane workspace',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(workspace, findsNothing);
    }
  });

  testWidgets(
      'desktop keyboard uses shared tap projection, phase undo, and transport',
      (tester) async {
    final tapTimes = <int>[0, 500];
    final previews = <AnalysisClickAuditionPreview>[];
    TrackAnalysisOverrides? saved;
    var transportToggles = 0;
    await _pumpDesktopWorkspace(
      tester,
      track: _track(),
      tapClockMs: () => tapTimes.removeAt(0),
      clickAudition: AnalysisClickAuditionConfiguration(
        onPreviewChanged: previews.add,
      ),
      onPlayPause: () async => transportToggles++,
      onSave: (overrides) async {
        saved = overrides;
        return null;
      },
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_bpm')),
          )
          .controller
          ?.text,
      '120',
    );
    expect(previews.last.sourceBeatsMs, isNotEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_meter')),
      '4',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await tester.pump();
    expect(find.text('Beat 2 is 1'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Beat 1 is 1'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(previews.last.beatClicksEnabled, isTrue);
    expect(transportToggles, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(saved?.manualTiming?.bpm, 120);
  });

  testWidgets('unmodified shortcuts do not steal focused text input',
      (tester) async {
    final previews = <AnalysisClickAuditionPreview>[];
    var transportToggles = 0;
    await _pumpDesktopWorkspace(
      tester,
      track: _track(),
      clickAudition: AnalysisClickAuditionConfiguration(
        onPreviewChanged: previews.add,
      ),
      onPlayPause: () async => transportToggles++,
    );

    final metadata = find.byKey(
      const ValueKey('analysis_workspace_separate_metadata'),
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();
    final keyField = find.byKey(const ValueKey('analysis_correction_key'));
    await tester.ensureVisible(keyField);
    await tester.tap(keyField);
    await tester.pump();
    final editable = tester.widget<EditableText>(
      find.descendant(of: keyField, matching: find.byType(EditableText)),
    );
    editable.controller.selection = TextSelection.collapsed(
      offset: editable.controller.text.length,
    );
    expect(
      editable.focusNode.hasFocus,
      isTrue,
    );
    final previewCount = previews.length;

    for (final input in const [
      (LogicalKeyboardKey.keyT, 't'),
      (LogicalKeyboardKey.keyM, 'm'),
      (LogicalKeyboardKey.bracketLeft, '['),
      (LogicalKeyboardKey.bracketRight, ']'),
      (LogicalKeyboardKey.space, ' '),
    ]) {
      final handled = await tester.sendKeyEvent(
        input.$1,
        character: input.$2,
      );
      expect(
        handled,
        isFalse,
        reason: '${input.$2} must fall through to the focused text editor',
      );
      final nextText = '${editable.controller.text}${input.$2}';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: nextText,
          selection: TextSelection.collapsed(offset: nextText.length),
        ),
      );
      await tester.pump();
    }

    expect(
      editable.controller.text,
      'D minortm[] ',
      reason: 'focused fields must receive plain workspace shortcut keys',
    );
    expect(previews, hasLength(previewCount));
    expect(transportToggles, 0);
    expect(find.text('Beat 1 is 1'), findsOneWidget);
    expect(find.textContaining('1 taps'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final resetHandled = await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyR,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      resetHandled,
      isTrue,
      reason: 'Ctrl+R is consumed so the browser cannot reload the workspace',
    );
    expect(
      find.byKey(const ValueKey('analysis_workspace_reset_pending')),
      findsNothing,
      reason: 'reset must not replace a focused field draft',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final undoHandled = await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyZ,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      undoHandled,
      isTrue,
      reason: 'Ctrl+Z is handled by the focused text editing shortcuts',
    );
    expect(find.text('Beat 1 is 1'), findsOneWidget);
  });

  testWidgets('reset is staged, undoable, and preserves non-timing overrides',
      (tester) async {
    TrackAnalysisOverrides? saved;
    await _pumpDesktopWorkspace(
      tester,
      track: _track(),
      onSave: (overrides) async {
        saved = overrides;
        return null;
      },
    );

    await tester.tap(
      find.byKey(const ValueKey('analysis_correction_reset')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analysis_workspace_reset_pending')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_bpm')),
          )
          .controller
          ?.text,
      '100',
    );

    await tester.tap(find.byKey(const ValueKey('analysis_correction_undo')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('analysis_workspace_reset_pending')),
      findsNothing,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_bpm')),
          )
          .controller
          ?.text,
      '110',
    );

    await tester.tap(
      find.byKey(const ValueKey('analysis_correction_reset')),
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    expect(saved?.manualTiming, isNull);
    expect(saved?.musicalKey, 'D minor');
  });

  testWidgets('set current beat reads the live source position at action time',
      (tester) async {
    final playhead = ValueNotifier<int?>(null);
    addTearDown(playhead.dispose);
    tester.view
      ..physicalSize = const Size(1180, 760)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalysisCorrectionSheet(
            track: _track(),
            desktopWorkspace: true,
            liveSourcePositionMs: () => playhead.value,
            playbackListenable: playhead,
          ),
        ),
      ),
    );
    await tester.pump();

    final setCurrent = find.byKey(
      const ValueKey('analysis_correction_set_current_downbeat'),
    );
    expect(tester.widget<OutlinedButton>(setCurrent).onPressed, isNull);

    playhead.value = 1050;
    await tester.pump();
    expect(tester.widget<OutlinedButton>(setCurrent).onPressed, isNotNull);
    await tester.tap(setCurrent);
    await tester.pump();
    expect(find.text('Beat 3 is 1'), findsOneWidget);
  });

  testWidgets(
      'analysis refresh republishes latest markers without playback-tick churn',
      (tester) async {
    final initial = _generatedTrack(const [100, 600, 1100, 1600]);
    final resolvedTrack = ValueNotifier<QueueTrack>(initial);
    final playhead = ValueNotifier<int?>(null);
    final previews = <AnalysisClickAuditionPreview>[];
    addTearDown(resolvedTrack.dispose);
    addTearDown(playhead.dispose);
    tester.view
      ..physicalSize = const Size(1180, 760)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnalysisCorrectionSheet(
            track: initial,
            desktopWorkspace: true,
            liveSourcePositionMs: () => playhead.value,
            playbackListenable: playhead,
            analysisListenable: resolvedTrack,
            trackResolver: () => resolvedTrack.value,
            clickAudition: AnalysisClickAuditionConfiguration(
              onPreviewChanged: previews.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(previews.last.sourceBeatsMs, [100, 600, 1100, 1600]);

    final previewCount = previews.length;
    playhead.value = 900;
    await tester.pump();
    expect(
      previews,
      hasLength(previewCount),
      reason: 'playhead ticks rebuild observation only',
    );

    resolvedTrack.value = _generatedTrack(
      const [200, 700, 1200, 1700, 2200],
      bpm: 130,
    );
    await tester.pump();
    expect(previews, hasLength(previewCount + 1));
    expect(previews.last.sourceBeatsMs, [200, 700, 1200, 1700, 2200]);

    await tester.tap(
      find.byKey(const ValueKey('analysis_correction_reset')),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_bpm')),
          )
          .controller
          ?.text,
      '130',
      reason: 'reset uses the latest resolved generated analysis',
    );
  });

  testWidgets('validation and failed persistence keep the desktop draft',
      (tester) async {
    await _pumpDesktopWorkspace(
      tester,
      track: _track(),
      onSave: (_) async => 'Conflict: review the latest analysis.',
    );

    final bpm = find.byKey(const ValueKey('analysis_correction_bpm'));
    await tester.enterText(bpm, '500');
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pump();
    expect(find.text('BPM must be between 30 and 300.'), findsOneWidget);

    await tester.enterText(bpm, '130');
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('analysis_correction_desktop_workspace')),
      findsOneWidget,
    );
    expect(find.text('Conflict: review the latest analysis.'), findsOneWidget);
    expect(tester.widget<TextField>(bpm).controller?.text, '130');
  });

  testWidgets(
      'conflict refresh exposes competing base and rebases only clean fields',
      (tester) async {
    late final ValueNotifier<QueueTrack> authoritativeTrack;
    authoritativeTrack = ValueNotifier<QueueTrack>(_track());
    addTearDown(authoritativeTrack.dispose);
    var saveCalls = 0;
    TrackAnalysisOverrides? resaved;
    await _pumpDesktopWorkspace(
      tester,
      track: authoritativeTrack.value,
      analysisListenable: authoritativeTrack,
      trackResolver: () => authoritativeTrack.value,
      onSave: (overrides) async {
        saveCalls++;
        if (saveCalls == 1) {
          authoritativeTrack.value = _competingTrack();
          return 'Conflict: review revision 2.';
        }
        resaved = overrides;
        return 'Keep open for assertions.';
      },
    );

    final bpm = find.byKey(const ValueKey('analysis_correction_bpm'));
    await tester.tap(
      find.byKey(const ValueKey('analysis_correction_half_bpm')),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('analysis_correction_undo')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.enterText(bpm, '130');
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();
    final metadata = find.byKey(
      const ValueKey('analysis_workspace_separate_metadata'),
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(bpm).controller?.text, '130');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_meter')),
          )
          .controller
          ?.text,
      '3',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('analysis_correction_key')),
          )
          .controller
          ?.text,
      'E minor',
    );
    expect(
      find.byKey(const ValueKey('analysis_workspace_authoritative_base')),
      findsOneWidget,
    );
    expect(find.textContaining('BPM 125'), findsOneWidget);
    expect(find.textContaining('key E minor'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('analysis_correction_undo')),
          )
          .onPressed,
      isNull,
      reason: 'Undo must not restore snapshots from the pre-conflict base.',
    );

    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    expect(saveCalls, 2);
    expect(resaved?.manualTiming?.bpm, 130);
    expect(resaved?.manualTiming?.beatAnchorMs, 200);
    expect(resaved?.manualTiming?.beatsPerBar, 3);
    expect(resaved?.musicalKey, 'E minor');
  });

  testWidgets('key-only legacy save preserves every timing compatibility fact',
      (tester) async {
    TrackAnalysisOverrides? saved;
    await _pumpDesktopWorkspace(
      tester,
      track: _legacyTimingTrack(),
      onSave: (overrides) async {
        saved = overrides;
        return 'Keep open for assertions.';
      },
    );
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Inactive'), findsNothing);
    expect(find.text('manual_override'), findsWidgets);
    final metadata = find.byKey(
      const ValueKey('analysis_workspace_separate_metadata'),
    );
    await tester.ensureVisible(metadata);
    await tester.tap(metadata);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_key')),
      'B minor',
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pumpAndSettle();

    expect(saved?.timingMutation, AnalysisTimingMutation.preserve);
    expect(saved?.bpm, 121);
    expect(saved?.beatGridOffsetMs, 17);
    expect(saved?.beatsMs, [17, 513, 1009]);
    expect(saved?.downbeatsMs, [17]);
    expect(saved?.musicalKey, 'B minor');
  });

  testWidgets('metadata-only manual revision is inactive in source card',
      (tester) async {
    final base = _track();
    await _pumpDesktopWorkspace(
      tester,
      track: base.copyWith(
        analysis: TrackAnalysis.fromJson(
          status: 'analyzed',
          summary: base.analysis?.generatedSummary?.toJson(),
          overrides: {
            'manual_timing_override': {
              'revision': 4,
              'updated_at': '2026-07-26T12:00:00Z',
            },
          },
        ),
      ),
    );

    expect(find.text('Inactive'), findsOneWidget);
    expect(find.text('Active'), findsNothing);
    expect(find.text('Generated timing'), findsOneWidget);
  });

  testWidgets('desktop cancel discards an unsaved draft without persistence',
      (tester) async {
    var saveCalls = 0;
    tester.view
      ..physicalSize = const Size(1024, 768)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showAnalysisCorrectionEditor(
              context: context,
              track: _track(),
              onSave: (_) async {
                saveCalls++;
                return null;
              },
            ),
            child: const Text('Edit timing'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit timing'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_bpm')),
      '137',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(saveCalls, 0);
    expect(
      find.byKey(const ValueKey('analysis_correction_desktop_workspace')),
      findsNothing,
    );
    expect(find.text('Edit timing'), findsOneWidget);
  });

  testWidgets('pending save blocks route pop until persistence resolves',
      (tester) async {
    final save = Completer<String?>();
    await _pumpDesktopWorkspace(
      tester,
      track: _track(),
      onSave: (_) => save.future,
    );
    await tester.enterText(
      find.byKey(const ValueKey('analysis_correction_bpm')),
      '131',
    );
    await tester.tap(find.byKey(const ValueKey('analysis_correction_save')));
    await tester.pump();

    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);

    save.complete('Review the conflict.');
    await tester.pumpAndSettle();
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);
  });

  testWidgets('field focus creates one undo transaction across type and blur',
      (tester) async {
    await _pumpDesktopWorkspace(tester, track: _track());
    final bpm = find.byKey(const ValueKey('analysis_correction_bpm'));
    final original = tester.widget<TextField>(bpm).controller!.text;

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.enterText(bpm, '133');
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('analysis_correction_undo')));
    await tester.pump();

    expect(tester.widget<TextField>(bpm).controller?.text, original);
  });
}

Future<void> _pumpDesktopWorkspace(
  WidgetTester tester, {
  required QueueTrack track,
  int Function()? tapClockMs,
  AnalysisClickAuditionConfiguration? clickAudition,
  Future<String?> Function(TrackAnalysisOverrides overrides)? onSave,
  Future<void> Function()? onPlayPause,
  Listenable? analysisListenable,
  QueueTrack Function()? trackResolver,
}) async {
  tester.view
    ..physicalSize = const Size(1180, 760)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnalysisCorrectionSheet(
          track: track,
          desktopWorkspace: true,
          currentSourcePositionMs: 1050,
          tapClockMs: tapClockMs,
          clickAudition: clickAudition,
          onSave: onSave,
          onPlayPause: onPlayPause,
          analysisListenable: analysisListenable,
          trackResolver: trackResolver,
        ),
      ),
    ),
  );
  await tester.pump();
}

QueueTrack _track() {
  return QueueTrack(
    id: '42',
    queueItemId: 'queue-42',
    playbackTrackId: '42',
    title: 'Desktop calibration fixture',
    duration: 12,
    addedAt: DateTime.utc(2026, 7, 26),
    analysis: TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {
          'value': 100,
          'confidence': 0.84,
          'provenance': 'generated',
        },
        'beat_grid': {
          'bpm': 100,
          'offset_ms': 100,
          'beats_ms': [100, 700, 1300, 1900, 2500, 3100, 3700, 4300],
          'confidence': 0.79,
          'provenance': 'generated',
        },
        'downbeats': {
          'positions_ms': [100, 2500],
          'confidence': 0.72,
          'provenance': 'generated',
        },
        'waveform': {
          'peaks': [0.1, 0.4, 0.8, 0.3, 0.6, 0.2],
        },
      },
      overrides: {
        'manual_timing_override': {
          'bpm': 110,
          'beat_anchor_ms': 100,
          'beats_per_bar': 4,
          'downbeat_phase_index': 0,
          'provenance': 'manual_override',
        },
        'key': {'value': 'D minor'},
      },
    ),
  );
}

QueueTrack _generatedTrack(List<int> beatsMs, {double bpm = 120}) {
  return QueueTrack(
    id: '42',
    queueItemId: 'queue-42',
    playbackTrackId: '42',
    title: 'Generated calibration fixture',
    duration: 12,
    addedAt: DateTime.utc(2026, 7, 26),
    analysis: TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': bpm},
        'beat_grid': {
          'bpm': bpm,
          'offset_ms': beatsMs.first,
          'beats_ms': beatsMs,
        },
        'waveform': {
          'peaks': [0.1, 0.4, 0.8, 0.3, 0.6, 0.2],
        },
      },
    ),
  );
}

QueueTrack _competingTrack() {
  final base = _track();
  return base.copyWith(
    analysis: TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: base.analysis?.generatedSummary?.toJson(),
      overrides: {
        'manual_timing_override': {
          'bpm': 125,
          'beat_anchor_ms': 200,
          'beats_per_bar': 3,
          'downbeat_phase_index': 1,
          'revision': 2,
          'provenance': 'manual_override',
        },
        'key': {'value': 'E minor'},
      },
      overrideRevision: 2,
    ),
  );
}

QueueTrack _legacyTimingTrack() {
  final base = _track();
  return base.copyWith(
    analysis: TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: base.analysis?.generatedSummary?.toJson(),
      overrides: {
        'bpm': {'value': 121, 'provenance': 'manual_override'},
        'beat_grid': {
          'offset_ms': 17,
          'beats_ms': [17, 513, 1009],
          'provenance': 'manual_override',
        },
        'downbeats': {
          'positions_ms': [17],
          'provenance': 'manual_override',
        },
        'key': {'value': 'A minor'},
      },
    ),
  );
}
