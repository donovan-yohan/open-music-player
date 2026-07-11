import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/stacked_waveform_timeline.dart';
import 'package:open_music_player/widgets/timeline_clip_widget.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

Track _track(
  String id,
  String title,
  int duration, {
  TrackAnalysis? analysis,
}) =>
    Track(
      id: id,
      title: title,
      artist: 'Artist $id',
      duration: duration,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: analysis,
    );

Track _analyzedTrack(
  String id,
  String title,
  int duration, {
  double bpm = 120,
  String? key,
  String? camelot,
  double confidence = 0.9,
  double? downbeatConfidence,
  List<int> downbeatsMs = const [0, 4000, 8000, 12000, 16000],
}) =>
    _track(
      id,
      title,
      duration,
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: TrackAnalysisSummary(
          bpm: AnalysisValue(value: bpm, confidence: confidence),
          key: key == null ? null : AnalysisValue(value: key),
          camelot: camelot == null ? null : AnalysisValue(value: camelot),
          downbeats: DownbeatSummary(
            positionsMs: downbeatsMs,
            confidence: downbeatConfidence,
          ),
        ),
      ),
    );

MixClip _mixClip(
  String id,
  int startMs,
  int durationMs, {
  GainEnvelope envelope = const GainEnvelope.flat(),
  ClipTempoMetadata tempo = ClipTempoMetadata.empty,
  String pitchMode = pitchModePreserve,
  PlaybackRateAutomation? rateAutomation,
}) =>
    MixClip(
      placement: TimelineClip.clamped(
        id: 'clip_$id',
        trackId: id,
        sourceDurationMs: durationMs,
        sourceStartMs: 0,
        sourceEndMs: durationMs,
        timelineStartMs: startMs,
      ),
      envelope: envelope,
      tempo: tempo,
      pitchMode: pitchMode,
      rateAutomation: rateAutomation,
    );

Future<void> _pump(
  WidgetTester tester, {
  required Track? previous,
  required Track current,
  required List<Track> upcoming,
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
  ValueChanged<Track>? onMoveEarlier,
  ValueChanged<Track>? onMoveLater,
  TimelineAnalysisEditCallback? onEditAnalysis,
  TimelinePitchModeChangedCallback? onPitchModeChanged,
  BeatSnapMode transitionSnapMode = BeatSnapMode.downbeat,
  ValueChanged<BeatSnapMode>? onTransitionSnapModeChanged,
  TimelineWaveformData Function(Track, int)? waveformFor,
  TimelineClip Function(Track, TimelineClip)? clipFor,
  TimelineModel? timelineModel,
  Set<String> pitchFallbackClipIds = const {},
  Map<String, ClipTempoRuntimeState> clipTempoStates = const {},
  int playheadPositionMs = 0,
  Stream<int>? positionMsStream,
  VoidCallback? onScrubStart,
  ValueChanged<int>? onScrubUpdate,
  Future<void> Function(int)? onScrubEnd,
  TimelineClipEditCallback? onTimelineStartChanged,
  TimelineClipEditCallback? onTrimStartChanged,
  TimelineClipEditCallback? onTrimEndChanged,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: StackedWaveformTimeline(
          previousTrack: previous,
          currentTrack: current,
          upcomingTracks: upcoming,
          peaksFor: (t) => mockWaveformPeaks(t.id),
          waveformFor: waveformFor,
          trimRangeFor: (t) => TrimRange.full(t.durationMs),
          clipFor: clipFor,
          timelineModel: timelineModel,
          pitchFallbackClipIds: pitchFallbackClipIds,
          clipTempoStates: clipTempoStates,
          playheadPositionMs: playheadPositionMs,
          positionMsStream: positionMsStream,
          onScrubStart: onScrubStart,
          onScrubUpdate: onScrubUpdate,
          onScrubEnd: onScrubEnd,
          onTimelineStartChanged: onTimelineStartChanged,
          onTrimStartChanged: onTrimStartChanged,
          onTrimEndChanged: onTrimEndChanged,
          onMoveEarlier: onMoveEarlier,
          onMoveLater: onMoveLater,
          onEditAnalysis: onEditAnalysis,
          onPitchModeChanged: onPitchModeChanged,
          transitionSnapMode: transitionSnapMode,
          onTransitionSnapModeChanged: onTransitionSnapModeChanged,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _pinchZoom(
  WidgetTester tester, {
  double startDistance = 80,
  double endDistance = 190,
}) async {
  final center = tester.getCenter(
    find.byKey(const ValueKey('timeline_pan_surface')),
  );
  final first = await tester.createGesture(pointer: 1);
  final second = await tester.createGesture(pointer: 2);
  await first.down(center - Offset(startDistance / 2, 0));
  await second.down(center + Offset(startDistance / 2, 0));
  await tester.pump();
  await first.moveTo(center - Offset(endDistance / 2, 0));
  await second.moveTo(center + Offset(endDistance / 2, 0));
  await tester.pump();
  await first.up();
  await second.up();
  await tester.pumpAndSettle();
}

TimelineWaveformPainter _waveformPainter(WidgetTester tester, String trackId) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(ValueKey('timeline_waveform_$trackId')),
  );
  return paint.painter! as TimelineWaveformPainter;
}

void main() {
  testWidgets('lane header keeps default-scale BPM text untruncated', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 220,
            child: TimelineLaneHeader(
              track: _analyzedTrack(
                'default-text',
                'EVERYTHING I’VE EVER WANTED',
                180,
                bpm: 184.6,
                key: 'A minor',
                camelot: '9A',
              ),
              role: LaneRole.collapsed,
              statusLabel: 'Later',
              accent: Colors.blue,
            ),
          ),
        ),
      ),
    );

    for (final label in ['184.6 BPM', '9A']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(paragraph.didExceedMaxLines, isFalse, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('lane header constrains metadata chips at 2x text scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              child: TimelineLaneHeader(
                track: _analyzedTrack(
                  'large-text',
                  'A long timeline title',
                  180,
                  bpm: 141.18,
                  key: 'F-sharp minor',
                  camelot: null,
                ),
                role: LaneRole.current,
                statusLabel: 'Current',
                accent: Colors.orange,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('141.2 BPM'), findsOneWidget);
    expect(find.text('F-sharp minor'), findsOneWidget);
    for (final label in ['141.2 BPM', 'F-sharp minor']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(paragraph.didExceedMaxLines, isFalse, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  for (final textScale in [1.3, 1.49, 1.9, 3.0]) {
    testWidgets('lane header stays bounded at ${textScale}x text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: textScale < 1.5 ? 140 : 260,
                child: TimelineLaneHeader(
                  track: _analyzedTrack(
                    'scaled-text-$textScale',
                    'A long timeline title',
                    180,
                    bpm: 141.18,
                    key: 'F-sharp minor',
                    camelot: textScale == 1.3 ? '11A' : null,
                  ),
                  role: LaneRole.current,
                  statusLabel: 'Current',
                  accent: Colors.orange,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('141.2 BPM'), findsOneWidget);
      expect(
        find.text(textScale == 1.3 ? '11A' : 'F-sharp minor'),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byType(TimelineLaneHeader)).height,
        TimelineLaneHeader.heightForTextScale(textScale),
      );
      if (textScale >= 1.3) {
        final headerBounds = tester.getRect(find.byType(TimelineLaneHeader));
        final bpmBounds = tester.getRect(
          find.byKey(const ValueKey('song_metadata_bpm_chip')),
        );
        final keyBounds = tester.getRect(
          find.byKey(const ValueKey('song_metadata_key_chip')),
        );

        for (final chipBounds in [bpmBounds, keyBounds]) {
          expect(chipBounds.left, greaterThanOrEqualTo(headerBounds.left));
          expect(chipBounds.top, greaterThanOrEqualTo(headerBounds.top));
          expect(chipBounds.right, lessThanOrEqualTo(headerBounds.right));
          expect(chipBounds.bottom, lessThanOrEqualTo(headerBounds.bottom));
        }
        if (textScale >= 1.49) {
          expect(keyBounds.top, greaterThan(bpmBounds.top));
        }
        for (final label in [
          '141.2 BPM',
          textScale == 1.3 ? '11A' : 'F-sharp minor',
        ]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(label),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('large-text lane identity hides before its safe width', () {
    for (final textScale in [1.3, 1.49, 2.0, 3.0]) {
      expect(
        TimelineLaneHeader.minimumVisibleWidthForTextScale(textScale),
        greaterThan(120),
      );
    }
  });

  for (final textScale in [1.3, 1.49]) {
    testWidgets(
      'timeline hides sub-120px identity at ${textScale}x text scale',
      (tester) async {
        await _pump(
          tester,
          previous: null,
          current: _analyzedTrack('narrow', 'Narrow identity', 80),
          upcoming: [_analyzedTrack('wide', 'Wide identity', 600)],
          textScaler: TextScaler.linear(textScale),
        );

        expect(
          find.byKey(const ValueKey('timeline_lane_header_narrow')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('timeline_lane_header_wide')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  group('musical snap grid', () {
    final clip = TimelineClip.clamped(
      id: 'clip_t1',
      trackId: 't1',
      sourceDurationMs: 10000,
      sourceStartMs: 0,
      sourceEndMs: 10000,
      timelineStartMs: 0,
    );

    test('source trim snaps to analyzed beat markers', () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 124,
        beatsMs: [120, 604, 1088, 1572],
      );

      expect(
        snapSourceMsToMusicalGrid(
          requestedSourceMs: 620,
          mode: SnapMarkerMode.beat1,
          clip: clip,
          tempo: tempo,
        ),
        604,
      );
    });

    test('four-beat trim snap uses every fourth analyzed beat', () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        beatsMs: [120, 620, 1120, 1620, 2120, 2620, 3120, 3620],
      );

      expect(
        snapSourceMsToMusicalGrid(
          requestedSourceMs: 1980,
          mode: SnapMarkerMode.beat4,
          clip: clip,
          tempo: tempo,
        ),
        2120,
      );
    });

    test('downbeat trim snap prefers analyzed downbeat markers', () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        beatsMs: [0, 500, 1000, 1500, 2000, 2500, 3000, 3500],
        downbeatsMs: [250, 2250, 4250, 6250],
      );

      expect(
        snapSourceMsToMusicalGrid(
          requestedSourceMs: 2380,
          mode: SnapMarkerMode.downbeat,
          clip: clip,
          tempo: tempo,
        ),
        2250,
      );
    });

    test('clip movement snaps with analyzed tempo offset', () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 124,
        beatsMs: [120, 604, 1088, 1572],
      );

      expect(
        snapTimelineStartMsToMusicalGrid(
          requestedStartMs: 1110,
          mode: SnapMarkerMode.beat1,
          clip: clip,
          tempo: tempo,
        ),
        1332,
      );
    });

    test('downbeat movement aligns source downbeat with global phrase grid',
        () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        downbeatsMs: [500, 4500, 8500],
      );

      expect(
        snapTimelineStartMsToMusicalGrid(
          requestedStartMs: 3700,
          mode: SnapMarkerMode.downbeat,
          clip: clip,
          tempo: tempo,
        ),
        3500,
      );
    });

    test('downbeat mode falls back to every fourth beat when downbeats miss',
        () {
      const tempo = ClipTempoMetadata(
        nativeBpm: 120,
        beatsMs: [120, 620, 1120, 1620, 2120, 2620, 3120, 3620],
      );

      expect(
        snapSourceMsToMusicalGrid(
          requestedSourceMs: 1980,
          mode: SnapMarkerMode.downbeat,
          clip: clip,
          tempo: tempo,
        ),
        2120,
      );
    });

    test('free mode preserves requested timing', () {
      expect(
        snapTimelineStartMsToMusicalGrid(
          requestedStartMs: 1110,
          mode: SnapMarkerMode.free,
          clip: clip,
          tempo: ClipTempoMetadata.empty,
        ),
        1110,
      );
      expect(
        snapSourceMsToMusicalGrid(
          requestedSourceMs: 620,
          mode: SnapMarkerMode.free,
          clip: clip,
          tempo: ClipTempoMetadata.empty,
        ),
        620,
      );
    });
  });

  group('mock waveform fixtures', () {
    test('include near-silence and isolated transient spikes', () {
      final peaks = mockWaveformPeaks('t1');

      final lo = peaks.reduce(math.min);
      final hi = peaks.reduce(math.max);
      expect(lo, lessThan(0.12), reason: 'should have a near-silence passage');
      expect(hi, greaterThan(0.9), reason: 'should have a transient spike');

      // A transient = a large jump between adjacent bars.
      var maxDelta = 0.0;
      for (var i = 0; i < peaks.length - 1; i++) {
        maxDelta = math.max(maxDelta, (peaks[i] - peaks[i + 1]).abs());
      }
      expect(
        maxDelta,
        greaterThan(0.6),
        reason: 'adjacent bars should spike, not average out',
      );

      // A uniform averaged strip (all == mean) would lose this structure:
      // require high spread.
      final mean = peaks.reduce((a, b) => a + b) / peaks.length;
      final variance =
          peaks.map((p) => (p - mean) * (p - mean)).reduce((a, b) => a + b) /
              peaks.length;
      expect(
        math.sqrt(variance),
        greaterThan(0.2),
        reason: 'uniform averaged strip should fail',
      );
    });

    test('are deterministic per track id', () {
      expect(mockWaveformPeaks('t1'), mockWaveformPeaks('t1'));
      expect(mockWaveformPeaks('t1'), isNot(mockWaveformPeaks('t2')));
    });

    test('tiny bar counts do not throw and stay normalised', () {
      for (final n in [0, 1, 2]) {
        expect(
          () => mockWaveformPeaks('tiny-$n', barCount: n),
          returnsNormally,
          reason: 'barCount=$n must not invert clamp bounds',
        );
        final peaks = mockWaveformPeaks('tiny-$n', barCount: n);
        expect(peaks.length, n, reason: 'barCount=$n');
        for (final p in peaks) {
          expect(p, inInclusiveRange(0.06, 1.0), reason: 'barCount=$n');
        }
      }
    });
  });

  testWidgets('renders stacked lanes, shared playhead and transition window', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _analyzedTrack('t1', 'Midnight Drive', 20),
      upcoming: [
        _analyzedTrack('t2', 'Paper Planes', 20),
        _analyzedTrack('t3', 'Glass', 20),
      ],
    );

    expect(
      find.byKey(const ValueKey('stacked_waveform_timeline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_playhead')), findsOneWidget);
    expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_options_fab')), findsOneWidget);
    expect(find.textContaining('transition 0:08'), findsWidgets);

    // Current + upcoming lanes each render header, clip and waveform.
    for (final id in ['t1', 't2', 't3']) {
      expect(find.byKey(ValueKey('timeline_lane_header_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('timeline_clip_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('timeline_waveform_$id')), findsOneWidget);
    }

    // Edge teaser chips stay out of the timeline chrome; lane rows carry identity.
    expect(find.byKey(const ValueKey('right_future_teaser')), findsNothing);
    expect(find.byKey(const ValueKey('left_history_teaser')), findsNothing);
  });

  testWidgets('timeline lane shows BPM and Camelot metadata when space allows',
      (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _analyzedTrack(
        't1',
        'Midnight Drive',
        180,
        bpm: 128,
        key: 'Am',
        camelot: '8A',
      ),
      upcoming: [],
    );

    expect(find.text('128 BPM'), findsOneWidget);
    expect(find.text('8A'), findsOneWidget);
  });

  testWidgets('requests denser waveform data as timeline zoom increases', (
    tester,
  ) async {
    final requested = <int>[];
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 1800),
      upcoming: [],
      waveformFor: (track, targetSampleCount) {
        requested.add(targetSampleCount);
        return richWaveformForTrack(track, sampleCount: targetSampleCount);
      },
    );
    final before = requested.reduce(math.max);
    requested.clear();

    final zoomedRequests = <int>[];
    for (var i = 0; i < 4; i++) {
      await _pinchZoom(tester);
      expect(requested, isNotEmpty);
      zoomedRequests.add(requested.reduce(math.max));
      requested.clear();
    }

    expect(zoomedRequests.first, greaterThan(before));
    expect(zoomedRequests.last, greaterThan(4096));
    expect(zoomedRequests.last, lessThanOrEqualTo(65536));
    expect(zoomedRequests, orderedEquals(zoomedRequests.toList()..sort()));
  });

  testWidgets(
    'generates dense fallback waveform data when provider is omitted',
    (tester) async {
      await _pump(
        tester,
        previous: null,
        current: _track('t1', 'Midnight Drive', 1800),
        upcoming: [],
      );
      final before = _waveformPainter(tester, 't1').waveform;

      for (var i = 0; i < 4; i++) {
        await _pinchZoom(tester);
      }
      final after = _waveformPainter(tester, 't1').waveform;

      expect(before, isNotNull);
      expect(before!.frames.length, greaterThanOrEqualTo(512));
      expect(after, isNotNull);
      expect(after!.frames.length, greaterThan(before.frames.length));
      expect(after.frames.length, greaterThan(4096));
      expect(
        after.frames.map((frame) => frame.low).toSet().length,
        greaterThan(8),
      );
      expect(
        after.frames.map((frame) => frame.mid).toSet().length,
        greaterThan(8),
      );
      expect(
        after.frames.map((frame) => frame.high).toSet().length,
        greaterThan(8),
      );
    },
  );

  testWidgets('future lane identity stays pinned before its waveform starts', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Long Now', 600),
      upcoming: [_track('t2', 'Long Next', 600)],
    );

    final header = tester.getRect(
      find.byKey(const ValueKey('timeline_lane_header_t2')),
    );
    final clip = tester.getRect(find.byKey(const ValueKey('timeline_clip_t2')));

    expect(header.left, closeTo(8, 1));
    expect(
      clip.left,
      greaterThan(390),
      reason: 'the future song row is visible before its waveform begins',
    );
  });

  testWidgets('lane identity clips away after the track end scrolls past', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Long Now', 600),
      upcoming: [_track('t2', 'Long Next', 600), _track('t3', 'Late', 600)],
    );

    expect(
      find.byKey(const ValueKey('timeline_lane_header_t1')),
      findsOneWidget,
    );

    await _pinchZoom(tester);
    await tester.drag(
      find.byKey(const ValueKey('timeline_pan_surface')),
      const Offset(-1500, 0),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline_lane_header_t1')), findsNothing);
    expect(
      find.byKey(const ValueKey('timeline_lane_header_t2')),
      findsOneWidget,
    );
  });

  testWidgets('binds the playhead to the live engine position stream', (
    tester,
  ) async {
    final positions = StreamController<int>.broadcast();
    addTearDown(positions.close);
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);
    final model = TimelineModel(
      clips: [_mixClip('t1', 0, 240000), _mixClip('t2', 240000, 240000)],
    );
    var waveformBuilds = 0;

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      timelineModel: model,
      playheadPositionMs: 0,
      positionMsStream: positions.stream,
      waveformFor: (track, targetSampleCount) {
        waveformBuilds++;
        return richWaveformForTrack(track, sampleCount: targetSampleCount);
      },
    );

    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_playhead')),
    );
    final waveformBuildsBeforePosition = waveformBuilds;
    await tester.runAsync(() async {
      positions.add(60000);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    final after = tester.getRect(
      find.byKey(const ValueKey('timeline_playhead')),
    );

    expect(after.left, greaterThan(before.left));
    expect(waveformBuilds, waveformBuildsBeforePosition);
  });

  testWidgets('browse drag scrubs through the engine lifecycle', (
    tester,
  ) async {
    final events = <String>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      timelineModel: TimelineModel(
        clips: [_mixClip('t1', 0, 240000), _mixClip('t2', 240000, 240000)],
      ),
      onScrubStart: () => events.add('begin'),
      onScrubUpdate: (ms) => events.add('update:$ms'),
      onScrubEnd: (ms) async => events.add('end:$ms'),
    );

    await tester.drag(
      find.byKey(const ValueKey('timeline_ruler_scrub_surface')),
      const Offset(140, 0),
    );
    await tester.pumpAndSettle();

    expect(events.first, 'begin');
    expect(events.where((event) => event.startsWith('update:')), isNotEmpty);
    expect(events.last, startsWith('end:'));
  });

  testWidgets('selected track ruler drag scrubs without clearing selection', (
    tester,
  ) async {
    final events = <String>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      timelineModel: TimelineModel(
        clips: [_mixClip('t1', 0, 240000), _mixClip('t2', 240000, 240000)],
      ),
      onScrubStart: () => events.add('begin'),
      onScrubUpdate: (ms) => events.add('update:$ms'),
      onScrubEnd: (ms) async => events.add('end:$ms'),
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline_ruler_scrub_surface')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();

    expect(events.first, 'begin');
    expect(events.where((event) => event.startsWith('update:')), isNotEmpty);
    expect(events.last, startsWith('end:'));
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      findsOneWidget,
    );
  });

  testWidgets('renders real model overlaps with gain-derived feedback', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      timelineModel: TimelineModel(
        clips: [
          _mixClip(
            't1',
            0,
            240000,
            envelope: const GainEnvelope(fadeOutMs: 60000),
          ),
          _mixClip(
            't2',
            180000,
            240000,
            envelope: const GainEnvelope(baseGainDb: -6, fadeInMs: 60000),
          ),
        ],
      ),
      playheadPositionMs: 190000,
    );

    expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
    expect(find.textContaining('gain'), findsWidgets);
    expect(find.byKey(const ValueKey('timeline_gain_t1')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_gain_t2')), findsOneWidget);
  });

  testWidgets(
    'uses corrected track analysis while live clip tempo refresh catches up',
    (tester) async {
      final current = _analyzedTrack(
        't1',
        'Midnight Drive',
        20,
        bpm: 120,
        downbeatsMs: const [0, 4000, 8000, 12000, 16000],
      );
      final next = _analyzedTrack(
        't2',
        'Paper Planes',
        20,
        bpm: 141.18,
        downbeatsMs: const [0, 4000, 8000, 12000, 16000],
      );

      await _pump(
        tester,
        previous: null,
        current: current,
        upcoming: [next],
        timelineModel: TimelineModel(
          clips: [
            _mixClip(
              't1',
              0,
              20000,
              envelope: const GainEnvelope(fadeOutMs: 8000),
            ),
            _mixClip(
              't2',
              12000,
              20000,
              envelope: const GainEnvelope(fadeInMs: 8000),
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('timeline_tempo_t2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('timeline_tempo_t2')),
          matching: find.textContaining('141.2 BPM'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('No next BPM'), findsNothing);
      expect(find.textContaining('No next downbeat'), findsNothing);
    },
  );

  testWidgets('renders every upcoming track as a vertically scrollable lane', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [
        _track('t2', 'Paper Planes', 188),
        _track('t3', 'Glass', 241),
        _track('t4', 'Late Static', 199),
        _track('t5', 'Soft Exit', 220),
      ],
    );

    for (final id in ['t1', 't2', 't3', 't4', 't5']) {
      expect(find.byKey(ValueKey('timeline_lane_header_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('timeline_clip_$id')), findsOneWidget);
    }
  });

  testWidgets('renders previous lane without edge teaser chips', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: _analyzedTrack('t0', 'Opening', 20),
      current: _analyzedTrack('t1', 'Midnight Drive', 20),
      upcoming: [_analyzedTrack('t2', 'Paper Planes', 20)],
    );

    expect(find.byKey(const ValueKey('left_history_teaser')), findsNothing);
    expect(find.byKey(const ValueKey('right_future_teaser')), findsNothing);
    expect(
      find.byKey(const ValueKey('timeline_lane_header_t0')),
      findsOneWidget,
    );
    expect(find.textContaining('ended'), findsNothing);
    expect(find.textContaining('starts in'), findsNothing);
  });

  testWidgets('handles zero-duration current and upcoming tracks', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('z1', 'Zero Now', 0),
      upcoming: [_track('z2', 'Zero Next', 0)],
    );

    expect(
      find.byKey(const ValueKey('stacked_waveform_timeline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_playhead')), findsOneWidget);
  });

  testWidgets('handles short-duration tracks with a previous clip', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: _track('s0', 'Tiny Open', 0),
      current: _track('s1', 'Tiny Now', 1),
      upcoming: [_track('s2', 'Tiny Next', 0)],
    );

    expect(
      find.byKey(const ValueKey('stacked_waveform_timeline')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_playhead')),
      findsNothing,
      reason: 'the fallback playhead is outside this short clip viewport',
    );
  });

  testWidgets(
    'handles one-pixel timeline pane without transition clamp crash',
    (tester) async {
      await _pump(
        tester,
        previous: null,
        current: _analyzedTrack('n1', 'Narrow Now', 20),
        upcoming: [_analyzedTrack('n2', 'Narrow Next', 20)],
        size: const Size(StackedWaveformTimeline.railWidth + 1, 844),
      );

      expect(
        find.byKey(const ValueKey('stacked_waveform_timeline')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
    },
  );

  testWidgets('tap selects a clip and empty tap returns to browse', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
    );

    expect(find.byKey(const ValueKey('timeline_trim_start_t1')), findsNothing);
    expect(find.byKey(const ValueKey('timeline_zoom_in')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      findsOneWidget,
    );

    final surface = tester.getRect(
      find.byKey(const ValueKey('timeline_pan_surface')),
    );
    await tester.tapAt(surface.bottomRight - const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline_trim_start_t1')), findsNothing);
  });

  testWidgets('selected timeline clip exposes analysis correction action', (
    tester,
  ) async {
    Track? edited;
    int? seededDownbeat;
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188)],
      playheadPositionMs: 16000,
      positionMsStream: const Stream<int>.empty(),
      onEditAnalysis: (track, {initialFirstDownbeatMs}) {
        edited = track;
        seededDownbeat = initialFirstDownbeatMs;
      },
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_track_actions_t1')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('timeline_correct_analysis_t1')));
    await tester.pumpAndSettle();

    expect(edited?.id, 't1');
    expect(seededDownbeat, 16000);
  });

  testWidgets('analysis correction action has no seed for inactive clip', (
    tester,
  ) async {
    Track? edited;
    int? seededDownbeat;
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188)],
      playheadPositionMs: 16000,
      positionMsStream: const Stream<int>.empty(),
      onEditAnalysis: (track, {initialFirstDownbeatMs}) {
        edited = track;
        seededDownbeat = initialFirstDownbeatMs;
      },
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_track_actions_t2')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('timeline_correct_analysis_t2')));
    await tester.pumpAndSettle();

    expect(edited?.id, 't2');
    expect(seededDownbeat, isNull);
  });

  testWidgets('overlap bands and selected clips expose tempo diagnostics', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 160);
    final incoming = _track('t2', 'Paper Planes', 160);
    final timeline = TimelineModel(
      clips: [
        _mixClip(
          't1',
          0,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 120,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
            musicalKey: 'A minor',
            camelot: '8A',
          ),
        ),
        _mixClip(
          't2',
          8000,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 124,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
            musicalKey: 'E minor',
            camelot: '9A',
          ),
        ),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      timelineModel: timeline,
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    expect(find.textContaining('Beat locked'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline_tempo_t1')), findsOneWidget);
    expect(find.textContaining('120 BPM'), findsOneWidget);
    expect(find.textContaining('90%'), findsOneWidget);
    expect(find.textContaining('A minor · 8A'), findsOneWidget);
    expect(find.textContaining('4 downbeats'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('timeline_transition_hint_t1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('timeline_transition_hint_t1')),
        matching: find.textContaining('Beat locked'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('selected transition hint surfaces low-confidence beat issues', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 160);
    final incoming = _track('t2', 'Paper Planes', 160);
    final timeline = TimelineModel(
      clips: [
        _mixClip(
          't1',
          0,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 120,
            bpmConfidence: 0.2,
            downbeatsMs: [0, 8000, 16000, 24000],
            camelot: '8A',
          ),
        ),
        _mixClip(
          't2',
          8500,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 124,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
            camelot: '2B',
          ),
        ),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      timelineModel: timeline,
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    final hint = find.byKey(const ValueKey('timeline_transition_hint_t1'));
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.textContaining('Low BPM')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: hint, matching: find.textContaining('Downbeat')),
      findsOneWidget,
    );
  });

  testWidgets('selected transition hint surfaces out-of-range BPM sync', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 160);
    final incoming = _track('t2', 'Paper Planes', 160);
    final timeline = TimelineModel(
      clips: [
        _mixClip(
          't1',
          0,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 60,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
          ),
        ),
        _mixClip(
          't2',
          8000,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 220,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
          ),
        ),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      timelineModel: timeline,
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    final hint = find.byKey(const ValueKey('timeline_transition_hint_t1'));
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.textContaining('Tempo range')),
      findsOneWidget,
    );
  });

  testWidgets('selected transition hint surfaces required pitch lock', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 160);
    final incoming = _track('t2', 'Paper Planes', 160);
    final timeline = TimelineModel(
      clips: [
        _mixClip(
          't1',
          0,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 120,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
          ),
        ),
        _mixClip(
          't2',
          8000,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 130,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
          ),
        ),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      timelineModel: timeline,
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    final hint = find.byKey(const ValueKey('timeline_transition_hint_t1'));
    expect(hint, findsOneWidget);
    expect(
      find.descendant(of: hint, matching: find.textContaining('Pitch lock')),
      findsOneWidget,
    );
  });

  testWidgets('selected lane exposes pitch fallback from live clip state', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 160);
    final timeline = TimelineModel(
      clips: [
        _mixClip(
          't1',
          0,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 120,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
          ),
        ),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: const [],
      timelineModel: timeline,
      pitchFallbackClipIds: const {'clip_t1'},
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('timeline_tempo_t1'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(
        of: chip,
        matching: find.textContaining('Pitch fallback'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('selected lane follows model tempo without rebuilding waveforms',
      (tester) async {
    final positions = StreamController<int>.broadcast();
    addTearDown(positions.close);
    var waveformBuilds = 0;
    final current = _track('t1', 'Midnight Drive', 160);
    final timeline = TimelineModel(
      clips: [
        _mixClip(
          't1',
          0,
          160000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 125,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 8000, 16000, 24000],
          ),
          rateAutomation: const PlaybackRateAutomation(
            baseRate: 1.1,
            pitchMode: pitchModePreserve,
            segments: [
              PlaybackRateSegment(
                startMs: 0,
                endMs: 100000,
                startRate: 0.9,
                endRate: 1.1,
              ),
            ],
          ),
        ),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: const [],
      timelineModel: timeline,
      positionMsStream: positions.stream,
      waveformFor: (track, targetSampleCount) {
        waveformBuilds++;
        return richWaveformForTrack(track, sampleCount: targetSampleCount);
      },
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('timeline_tempo_t1'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(
          of: chip, matching: find.textContaining('Live 112.5 BPM')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.textContaining('0.90x')),
      findsOneWidget,
    );
    final buildsAfterSelection = waveformBuilds;

    await tester.runAsync(() async {
      positions.add(100000);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(
      find.descendant(
          of: chip, matching: find.textContaining('Live 137.5 BPM')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.textContaining('1.10x')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: chip, matching: find.textContaining('Live 112.5 BPM')),
      findsNothing,
    );
    expect(waveformBuilds, buildsAfterSelection);
  });

  testWidgets('live timeline prefers corrected row tempo over stale clip tempo',
      (tester) async {
    final downbeats = List<int>.generate(50, (index) => index * 5000);
    final current = _analyzedTrack(
      't1',
      'Midnight Drive',
      220,
      bpm: 141.18,
      downbeatsMs: downbeats,
    );
    final upcoming = _analyzedTrack(
      't2',
      'Skyline',
      180,
      bpm: 141.18,
      downbeatsMs: downbeats,
    );
    const staleTempo = ClipTempoMetadata(nativeBpm: 90);
    final timeline = TimelineModel(
      clips: [
        _mixClip('t1', 0, 220000, tempo: staleTempo),
        _mixClip('t2', 195000, 180000, tempo: staleTempo),
      ],
    );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [upcoming],
      timelineModel: timeline,
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('timeline_tempo_t2'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.textContaining('141.2 BPM')),
      findsOneWidget,
    );
    expect(find.textContaining('Beat locked'), findsWidgets);
    expect(find.textContaining('No downbeat'), findsNothing);
  });

  testWidgets('selected lane exposes explicit pitch mode choices',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final current = _track('t1', 'Midnight Drive', 240);
    final calls = <({Track track, String pitchMode})>[];

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: const [],
      timelineModel: TimelineModel(
        clips: [
          _mixClip(
            't1',
            0,
            240000,
            pitchMode: pitchModePreserve,
          ),
        ],
      ),
      onPitchModeChanged: (track, pitchMode) {
        calls.add((track: track, pitchMode: pitchMode));
      },
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    final pitchMenu = tester.widget<PopupMenuButton<String>>(
      find.byKey(const ValueKey('timeline_pitch_mode_t1')),
    );
    expect(
      pitchMenu.tooltip,
      'Key lock: preserve pitch while tempo changes',
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('timeline_pitch_mode_semantics_t1')),
          )
          .label,
      contains('Key lock: preserve pitch while tempo changes'),
    );
    await tester.tap(find.byKey(const ValueKey('timeline_pitch_mode_t1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('timeline_pitch_key_lock_t1')),
      findsOneWidget,
    );
    expect(
      find.text('Key lock: preserve pitch while tempo changes'),
      findsOneWidget,
    );
    expect(find.text('Pitch follows tempo'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('timeline_pitch_follows_tempo_t1')),
    );
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.track.id, 't1');
    expect(calls.single.pitchMode, pitchModeFollowTempo);
    semantics.dispose();
  });

  testWidgets('pitch edit holds the per-track busy lock', (tester) async {
    final semantics = tester.ensureSemantics();
    final completion = Completer<void>();
    final calls = <String>[];
    final current = _track('t1', 'Midnight Drive', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: const [],
      timelineModel: TimelineModel(
        clips: [_mixClip('t1', 0, 240000)],
      ),
      onTimelineStartChanged: (_, __) {},
      onPitchModeChanged: (_, pitchMode) async {
        calls.add(pitchMode);
        await completion.future;
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_pitch_mode_t1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_pitch_follows_tempo_t1')),
    );
    await tester.pumpAndSettle();

    expect(calls, [pitchModeFollowTempo]);
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const ValueKey('timeline_pitch_mode_t1')),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('timeline_clip_semantics_t1')),
          )
          .label,
      contains('Saving Midnight Drive timeline edit'),
    );
    await tester.tap(
      find.byKey(const ValueKey('timeline_pitch_mode_t1')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('timeline_pitch_follows_tempo_t1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('timeline_selection_toolbar_t1')),
      findsOneWidget,
    );
    expect(calls, hasLength(1));

    completion.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const ValueKey('timeline_pitch_mode_t1')),
          )
          .enabled,
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('failed pitch edit reports once and releases its busy lock', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: const [],
      timelineModel: TimelineModel(
        clips: [_mixClip('t1', 0, 240000)],
      ),
      onPitchModeChanged: (_, __) async {
        throw StateError('pitch failed');
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_pitch_mode_t1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('timeline_pitch_follows_tempo_t1')),
    );
    await tester.pump();

    expect(tester.takeException(), isA<StateError>());
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.byKey(const ValueKey('timeline_pitch_mode_t1')),
          )
          .enabled,
      isTrue,
    );
  });

  testWidgets('floating options panel controls snap marker mode', (
    tester,
  ) async {
    final changes = <BeatSnapMode>[];
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188)],
      transitionSnapMode: BeatSnapMode.beat1,
      onTransitionSnapModeChanged: changes.add,
    );

    expect(find.byKey(const ValueKey('timeline_options_fab')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline_options_fab')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('timeline_options_panel')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_snap_free')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('timeline_snap_downbeat')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_snap_beat1')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_snap_beat4')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_snap_beat16')), findsOneWidget);
    expect(find.text('Downbeat'), findsOneWidget);
    expect(find.text('1 beat'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline_snap_beat16')));
    await tester.pumpAndSettle();
    expect(changes, [BeatSnapMode.beat16]);
    expect(find.textContaining('16 beats'), findsWidgets);
    expect(
      find.byKey(const ValueKey('timeline_options_zoom_in')),
      findsNothing,
    );
  });

  testWidgets('browse drag pans the zoomed timeline viewport', (tester) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240), _track('t3', 'Glass', 240)],
    );

    await _pinchZoom(tester);

    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    await tester.drag(
      find.byKey(const ValueKey('timeline_pan_surface')),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
    final after = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );

    expect(
      after.left,
      lessThan(before.left),
      reason: 'dragging left should pan later in shared mix time',
    );
  });

  testWidgets('pinch zoom visibly scales the timeline', (tester) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
    );

    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t1')),
    );
    await _pinchZoom(tester);
    final after = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t1')),
    );

    expect(after.width, greaterThan(before.width));
    expect(find.byKey(const ValueKey('timeline_zoom_in')), findsNothing);
  });

  testWidgets('selected clip still allows empty-space timeline panning', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240), _track('t3', 'Glass', 240)],
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      findsOneWidget,
    );

    await _pinchZoom(tester);
    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    final surface = tester.getRect(
      find.byKey(const ValueKey('timeline_pan_surface')),
    );
    final gesture = await tester.startGesture(
      surface.bottomRight - const Offset(96, 24),
    );
    await gesture.moveBy(const Offset(-160, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    final after = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );

    expect(after.left, lessThan(before.left));
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      findsOneWidget,
    );
  });

  testWidgets('browse drag pans zoomed engine timelines with scrub handlers', (
    tester,
  ) async {
    final events = <String>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);
    final later = _track('t3', 'Glass', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next, later],
      timelineModel: TimelineModel.sequential([
        current.id,
        next.id,
        later.id,
      ], sourceDurationMsFor: (_) => 240000),
      onScrubStart: () => events.add('begin'),
      onScrubUpdate: (ms) => events.add('update:$ms'),
      onScrubEnd: (ms) async => events.add('end:$ms'),
    );

    await _pinchZoom(tester);

    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    await tester.drag(
      find.byKey(const ValueKey('timeline_pan_surface')),
      const Offset(-160, 0),
    );
    await tester.pumpAndSettle();
    final after = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );

    expect(
      after.left,
      lessThan(before.left),
      reason: 'lane drag should pan even when engine scrub handlers exist',
    );
    expect(events, isEmpty, reason: 'lane panning must not start scrubbing');
  });

  testWidgets('current track changes clear manual pan and auto-follow', (
    tester,
  ) async {
    final first = _track('t1', 'Midnight Drive', 240);
    final second = _track('t2', 'Paper Planes', 240);
    final third = _track('t3', 'Glass', 240);

    await _pump(
      tester,
      previous: null,
      current: first,
      upcoming: [second, third],
    );

    await _pinchZoom(tester);
    await tester.drag(
      find.byKey(const ValueKey('timeline_pan_surface')),
      const Offset(-300, 0),
    );
    await tester.pumpAndSettle();

    await _pump(tester, previous: first, current: second, upcoming: [third]);

    final currentRect = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    expect(
      currentRect.left,
      inInclusiveRange(
        StackedWaveformTimeline.railWidth + 40,
        StackedWaveformTimeline.railWidth + 100,
      ),
      reason: 'new current clip should auto-follow after playback advances',
    );
    expect(find.byKey(const ValueKey('timeline_playhead')), findsOneWidget);
  });

  testWidgets('current track changes during scrub preserve the viewport', (
    tester,
  ) async {
    final events = <String>[];
    final first = _track('t1', 'Midnight Drive', 240);
    final second = _track('t2', 'Paper Planes', 240);
    final third = _track('t3', 'Glass', 240);

    await _pump(
      tester,
      previous: null,
      current: first,
      upcoming: [second, third],
      onScrubStart: () => events.add('begin'),
      onScrubUpdate: (ms) => events.add('update:$ms'),
      onScrubEnd: (ms) async => events.add('end:$ms'),
    );

    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    final ruler = tester.getRect(
      find.byKey(const ValueKey('timeline_ruler_scrub_surface')),
    );
    final gesture = await tester.startGesture(ruler.center);
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();

    await _pump(
      tester,
      previous: first,
      current: second,
      upcoming: [third],
      onScrubStart: () => events.add('begin'),
      onScrubUpdate: (ms) => events.add('update:$ms'),
      onScrubEnd: (ms) async => events.add('end:$ms'),
      settle: false,
    );

    final during = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    expect(
      during.left,
      closeTo(before.left, 1),
      reason:
          'scrubbing into the next song must not auto-follow and move the pane',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(events.first, 'begin');
  });

  testWidgets('scrub drag only pans when held near a horizontal edge', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);
    final later = _track('t3', 'Glass', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next, later],
      onScrubStart: () {},
      onScrubUpdate: (_) {},
      onScrubEnd: (_) async {},
    );

    final ruler = tester.getRect(
      find.byKey(const ValueKey('timeline_ruler_scrub_surface')),
    );
    final beforeCenter = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    final centerGesture = await tester.startGesture(ruler.center);
    await centerGesture.moveBy(const Offset(80, 0));
    await tester.pump();
    final afterCenter = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    expect(afterCenter.left, closeTo(beforeCenter.left, 1));
    await centerGesture.up();
    await tester.pumpAndSettle();

    final beforeEdge = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    final edgeGesture = await tester.startGesture(
      Offset(ruler.right - 4, ruler.center.dy),
    );
    await edgeGesture.moveBy(const Offset(24, 0));
    await edgeGesture.moveBy(const Offset(24, 0));
    await tester.pump();
    final afterEdge = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );

    expect(
      afterEdge.left,
      lessThan(beforeEdge.left),
      reason: 'edge scrub should reveal later timeline content',
    );

    await edgeGesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('no-op edge pan does not create a manual offset lock', (
    tester,
  ) async {
    final previous = _track('t0', 'Opening', 240);
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);
    final later = _track('t3', 'Glass', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next, later],
    );

    await tester.drag(
      find.byKey(const ValueKey('timeline_pan_surface')),
      const Offset(160, 0),
    );
    await tester.pumpAndSettle();

    await _pump(tester, previous: previous, current: current, upcoming: [next]);

    final currentRect = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t1')),
    );
    expect(
      currentRect.left,
      lessThan(StackedWaveformTimeline.railWidth + 110),
      reason:
          'a clamped no-op drag at the left edge should leave auto-follow on',
    );
    expect(
      currentRect.left,
      greaterThan(StackedWaveformTimeline.railWidth),
      reason: 'auto-follow keeps the current clip inside the visible pane',
    );
  });

  testWidgets('hides the playhead when it is outside the visible pane', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240), _track('t3', 'Glass', 240)],
    );
    expect(find.byKey(const ValueKey('timeline_playhead')), findsOneWidget);

    await tester.drag(
      find.byKey(const ValueKey('timeline_pan_surface')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline_playhead')), findsNothing);
  });

  testWidgets(
    'mobile viewport keeps a panned clip body full-width, not a sliver',
    (tester) async {
      await _pump(
        tester,
        previous: null,
        current: _track('long1', 'Long Now', 600),
        upcoming: [_track('long2', 'Long Next', 600)],
        size: const Size(390, 844),
      );

      await _pinchZoom(tester);
      await tester.drag(
        find.byKey(const ValueKey('timeline_pan_surface')),
        const Offset(-220, 0),
      );
      await tester.pumpAndSettle();

      const paneWidth = 390 - StackedWaveformTimeline.railWidth;
      final currentRect = tester.getRect(
        find.byKey(const ValueKey('timeline_clip_long1')),
      );

      expect(currentRect.left, lessThan(StackedWaveformTimeline.railWidth));
      expect(
        currentRect.width,
        greaterThan(paneWidth),
        reason:
            'the clip keeps its timeline-scaled body while clipped by the viewport',
      );
      expect(
        find.byKey(const ValueKey('timeline_waveform_long1')),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows clearly labeled queue-order moves for upcoming clips', (
    tester,
  ) async {
    final movedEarlier = <String>[];
    final movedLater = <String>[];

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188), _track('t3', 'Glass', 241)],
      onMoveEarlier: (track) => movedEarlier.add(track.id),
      onMoveLater: (track) => movedLater.add(track.id),
    );

    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('timeline_track_actions_t2')));
    await tester.pumpAndSettle();
    expect(find.text('Move earlier in queue'), findsOneWidget);
    expect(find.text('Move later in queue'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline_move_later_t2')));
    await tester.pumpAndSettle();
    expect(movedLater, ['t2']);

    await tester.tap(find.byKey(const ValueKey('timeline_track_actions_t2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_move_earlier_t2')));
    await tester.pumpAndSettle();
    expect(movedEarlier, ['t2']);
  });

  testWidgets('clip drag has an explicit timeline move semantic label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
      onTimelineStartChanged: (_, __) {},
    );

    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('timeline_clip_semantics_t1')),
          )
          .label,
      'Move Midnight Drive in timeline',
    );
    semantics.dispose();
  });

  testWidgets('semantic increase moves an editable clip on the snap grid', (
    tester,
  ) async {
    final starts = <int>[];
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
      onTimelineStartChanged: (_, startMs) => starts.add(startMs),
    );

    final node = tester.getSemantics(
      find
          .ancestor(
            of: find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        type: SemanticsAction.increase,
        viewId: tester.view.viewId,
        nodeId: node.id,
      ),
    );
    await tester.pumpAndSettle();

    expect(starts, hasLength(1));
    expect(starts.single, greaterThan(0));
    semantics.dispose();
  });

  testWidgets('semantic decrease moves an editable incoming clip', (
    tester,
  ) async {
    final starts = <int>[];
    final semantics = tester.ensureSemantics();
    const incomingStartMs = 180000;
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: TimelineModel(
        clips: [
          _mixClip('t1', 0, 240000),
          _mixClip('t2', incomingStartMs, 240000),
        ],
      ),
      onTimelineStartChanged: (track, startMs) {
        if (track.id == 't2') starts.add(startMs);
      },
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey('timeline_clip_semantics_t2')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        type: SemanticsAction.decrease,
        viewId: tester.view.viewId,
        nodeId: node.id,
      ),
    );
    await tester.pumpAndSettle();

    expect(starts, hasLength(1));
    expect(starts.single, lessThan(incomingStartMs));
    semantics.dispose();
  });

  testWidgets('semantic tap selects current lane without moving it', (
    tester,
  ) async {
    final starts = <int>[];
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
      onTimelineStartChanged: (_, startMs) => starts.add(startMs),
      onPitchModeChanged: (_, __) {},
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    final body = find.byKey(const ValueKey('timeline_clip_semantics_t1'));
    final node = tester.getSemantics(body);
    final semanticData = node.getSemanticsData();
    expect(semanticData.hasAction(SemanticsAction.tap), isTrue);
    expect(semanticData.hasAction(SemanticsAction.increase), isTrue);
    expect(semanticData.hasAction(SemanticsAction.decrease), isTrue);
    expect(semanticData.hasAction(SemanticsAction.scrollLeft), isFalse);
    expect(semanticData.hasAction(SemanticsAction.scrollRight), isFalse);
    expect(
      find.byKey(const ValueKey('timeline_selection_toolbar_t1')),
      findsNothing,
    );

    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        type: SemanticsAction.tap,
        viewId: tester.view.viewId,
        nodeId: node.id,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('timeline_pitch_mode_t1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_track_actions_t1')),
      findsOneWidget,
    );
    expect(starts, isEmpty);
    semantics.dispose();
  });

  testWidgets('non-editable clips describe selection rather than movement', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey('timeline_clip_semantics_t1')),
    );
    expect(node.label, 'Select Midnight Drive in timeline');
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.increase),
      isFalse,
    );
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.decrease),
      isFalse,
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  for (final size in [const Size(320, 844), const Size(390, 844)]) {
    testWidgets('large-text controls stay clear at ${size.width.toInt()}px', (
      tester,
    ) async {
      await _pump(
        tester,
        previous: null,
        current: _analyzedTrack('t1', 'Midnight Drive', 214),
        upcoming: const [],
        size: size,
        textScaler: const TextScaler.linear(3),
        onPitchModeChanged: (_, __) {},
        onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
      );
      await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
      await tester.pumpAndSettle();

      final header = tester.getRect(
        find.byKey(const ValueKey('timeline_lane_header_t1')),
      );
      final pitch = tester.getRect(
        find.byKey(const ValueKey('timeline_pitch_mode_t1')),
      );
      final actions = tester.getRect(
        find.byKey(const ValueKey('timeline_track_actions_t1')),
      );
      final region = tester.getRect(
        find.byKey(const ValueKey('timeline_selection_region_t1')),
      );
      final clipBody = tester.getRect(
        find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      );

      for (final rect in [pitch, actions]) {
        expect(rect.width, greaterThanOrEqualTo(40));
        expect(rect.height, greaterThanOrEqualTo(40));
        expect(region.contains(rect.center), isTrue);
        expect(rect.overlaps(header), isFalse);
        expect(rect.overlaps(clipBody), isFalse);
      }
      expect(region.bottom, lessThanOrEqualTo(clipBody.top));
      expect(tester.takeException(), isNull);
    });
  }

  for (final textScale in [1.0, 3.0]) {
    testWidgets(
      'playhead leaves selection controls tappable at ${textScale}x text scale',
      (tester) async {
        final positions = StreamController<int>.broadcast();
        addTearDown(positions.close);
        final scrubEvents = <String>[];
        final pitchModes = <String>[];
        var analysisEdits = 0;
        final current = _track('t1', 'Midnight Drive', 390);

        await _pump(
          tester,
          previous: null,
          current: current,
          upcoming: const [],
          textScaler: TextScaler.linear(textScale),
          timelineModel: TimelineModel(
            clips: [_mixClip('t1', 0, 390000)],
          ),
          playheadPositionMs: 0,
          positionMsStream: positions.stream,
          onScrubStart: () => scrubEvents.add('begin'),
          onScrubUpdate: (ms) => scrubEvents.add('update:$ms'),
          onScrubEnd: (ms) async => scrubEvents.add('end:$ms'),
          onPitchModeChanged: (_, mode) => pitchModes.add(mode),
          onEditAnalysis: (_, {initialFirstDownbeatMs}) => analysisEdits++,
        );
        await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
        await tester.pumpAndSettle();

        Future<void> movePlayheadTo(double globalX) async {
          await tester.runAsync(() async {
            positions.add((globalX * 1000).round());
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump();
        }

        final pitch = find.byKey(const ValueKey('timeline_pitch_mode_t1'));
        final actions = find.byKey(const ValueKey('timeline_track_actions_t1'));
        final selectionRegion = tester.getRect(
          find.byKey(const ValueKey('timeline_selection_region_t1')),
        );

        await movePlayheadTo(tester.getRect(pitch).center.dx);
        final scrubHandle = tester.getRect(
          find.byKey(const ValueKey('timeline_playhead_drag_handle')),
        );
        final badge = tester.getRect(
          find.byKey(const ValueKey('timeline_playhead_time_badge')),
        );
        final rulerPlayhead = tester.getRect(
          find.byKey(const ValueKey('timeline_ruler_playhead')),
        );
        final lanePlayhead = tester.getRect(
          find.byKey(const ValueKey('timeline_playhead')),
        );
        expect(
          scrubHandle.center.dx,
          closeTo(tester.getRect(pitch).center.dx, 1),
        );
        expect(scrubHandle.top, greaterThanOrEqualTo(selectionRegion.bottom));
        expect(badge.overlaps(selectionRegion), isFalse);
        expect(rulerPlayhead.center.dx, closeTo(lanePlayhead.center.dx, 0.1));

        await tester.tap(pitch);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('timeline_pitch_follows_tempo_t1')),
        );
        await tester.pumpAndSettle();
        expect(pitchModes, [pitchModeFollowTempo]);
        expect(scrubEvents, isEmpty);

        await movePlayheadTo(tester.getRect(actions).center.dx);
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey('timeline_playhead_drag_handle')),
              )
              .center
              .dx,
          closeTo(tester.getRect(actions).center.dx, 1),
        );
        await tester.tap(actions);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('timeline_correct_analysis_t1')),
        );
        await tester.pumpAndSettle();
        expect(analysisEdits, 1);
        expect(scrubEvents, isEmpty);

        await tester.drag(
          find.byKey(const ValueKey('timeline_playhead_drag_handle')),
          const Offset(36, 0),
        );
        await tester.pumpAndSettle();
        expect(scrubEvents.first, 'begin');
        expect(
          scrubEvents.where((event) => event.startsWith('update:')),
          isNotEmpty,
        );
        expect(scrubEvents.last, startsWith('end:'));

        scrubEvents.clear();
        await tester.drag(
          find.byKey(const ValueKey('timeline_ruler_scrub_surface')),
          const Offset(-36, 0),
        );
        await tester.pumpAndSettle();
        expect(scrubEvents.first, 'begin');
        expect(
          scrubEvents.where((event) => event.startsWith('update:')),
          isNotEmpty,
        );
        expect(scrubEvents.last, startsWith('end:'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'large-text toolbar stays tappable without intercepting waveform drag',
    (tester) async {
      final starts = <int>[];
      await _pump(
        tester,
        previous: null,
        current: _analyzedTrack('t1', 'Midnight Drive', 214),
        upcoming: const [],
        size: const Size(320, 844),
        textScaler: const TextScaler.linear(3),
        onTimelineStartChanged: (_, startMs) => starts.add(startMs),
        onPitchModeChanged: (_, __) {},
        onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
      );
      await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
      await tester.pumpAndSettle();

      final body = tester.getRect(
        find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      );
      final toolbar = tester.getRect(
        find.byKey(const ValueKey('timeline_selection_toolbar_t1')),
      );
      expect(toolbar.overlaps(body), isFalse);

      await tester.tap(find.byKey(const ValueKey('timeline_pitch_mode_t1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('timeline_pitch_key_lock_t1')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('timeline_pitch_key_lock_t1')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('timeline_track_actions_t1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('timeline_correct_analysis_t1')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('timeline_correct_analysis_t1')),
      );
      await tester.pumpAndSettle();

      final dragBody = tester.getRect(
        find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      );
      await tester.dragFrom(
        Offset(dragBody.right - 72, dragBody.top + 32),
        const Offset(64, 0),
      );
      await tester.pumpAndSettle();

      expect(starts, isNotEmpty);
      expect(starts.last, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('caches waveform slices until the analysis revision changes', (
    tester,
  ) async {
    var calls = 0;
    final first = _track(
      't1',
      'Midnight Drive',
      214,
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    final revised = _track(
      't1',
      'Midnight Drive',
      214,
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        updatedAt: DateTime.utc(2026, 1, 2),
      ),
    );
    TimelineWaveformData waveformFor(Track track, int samples) {
      calls++;
      return richWaveformForTrack(track, sampleCount: samples);
    }

    await _pump(
      tester,
      previous: null,
      current: first,
      upcoming: const [],
      waveformFor: waveformFor,
    );
    final firstCalls = calls;
    await _pump(
      tester,
      previous: null,
      current: first,
      upcoming: const [],
      waveformFor: waveformFor,
    );
    expect(calls, firstCalls);

    await _pump(
      tester,
      previous: null,
      current: revised,
      upcoming: const [],
      waveformFor: waveformFor,
    );
    expect(calls, greaterThan(firstCalls));
  });

  testWidgets('caches dense 131k-frame sources at the visible sample count', (
    tester,
  ) async {
    var calls = 0;
    final denseFrames = List<WaveformFrame>.filled(
      131072,
      const WaveformFrame(peak: 0.8, rms: 0.5, low: 0.2, mid: 0.6, high: 0.9),
    );
    TimelineWaveformData waveformFor(Track track, int samples) {
      calls++;
      return TimelineWaveformData(durationMs: 600000, frames: denseFrames);
    }

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Dense', 600),
      upcoming: const [],
      waveformFor: waveformFor,
    );
    final painter = _waveformPainter(tester, 't1');
    expect(painter.waveform!.frames.length, lessThanOrEqualTo(65536));
    final firstCalls = calls;
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Dense', 600),
      upcoming: const [],
      waveformFor: waveformFor,
    );
    expect(calls, firstCalls);
  });

  testWidgets('evicts the oldest waveform slice when the cache is bounded', (
    tester,
  ) async {
    var calls = 0;
    var sourceStartMs = 0;
    final track = _track('t1', 'Cache bounds', 600);
    final source = TimelineWaveformData(
      durationMs: 600000,
      frames: List<WaveformFrame>.filled(
        2048,
        const WaveformFrame(
          peak: 0.7,
          rms: 0.4,
          low: 0.5,
          mid: 0.6,
          high: 0.3,
        ),
      ),
    );
    TimelineWaveformData waveformFor(Track track, int samples) {
      calls++;
      return source;
    }

    TimelineClip clipFor(Track track, TimelineClip fallback) =>
        fallback.withSourceRange(
          sourceStartMs: sourceStartMs,
          sourceEndMs: sourceStartMs + 300000,
        );

    for (var index = 0; index < 13; index++) {
      sourceStartMs = index * 1000;
      await _pump(
        tester,
        previous: null,
        current: track,
        upcoming: const [],
        waveformFor: waveformFor,
        clipFor: clipFor,
      );
    }
    expect(calls, 13);

    sourceStartMs = 0;
    await _pump(
      tester,
      previous: null,
      current: track,
      upcoming: const [],
      waveformFor: waveformFor,
      clipFor: clipFor,
    );
    expect(calls, 14, reason: 'the thirteenth key evicts the oldest slice');
  });

  testWidgets('snap options change advisory semantics from info to warning', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const lowConfidenceTempo = ClipTempoMetadata(
      nativeBpm: 120,
      bpmConfidence: 0.9,
      downbeatsMs: [0, 4000, 8000, 12000],
      downbeatConfidence: 0.4,
    );
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Outgoing', 20),
      upcoming: [_track('t2', 'Incoming', 20)],
      transitionSnapMode: BeatSnapMode.free,
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
      timelineModel: TimelineModel(
        clips: [
          _mixClip('t1', 0, 20000, tempo: lowConfidenceTempo),
          _mixClip('t2', 8000, 20000, tempo: lowConfidenceTempo),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final hint = find.byKey(const ValueKey('timeline_transition_hint_t2'));
    expect(hint, findsOneWidget);
    expect(
      tester
          .widget<Icon>(find.descendant(of: hint, matching: find.byType(Icon)))
          .icon,
      Icons.sync_alt,
    );
    expect(tester.getSemantics(hint).label, contains('transition info'));

    await tester.tap(find.byKey(const ValueKey('timeline_options_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_snap_beat4')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Icon>(find.descendant(of: hint, matching: find.byType(Icon)))
          .icon,
      Icons.warning_amber_rounded,
    );
    expect(tester.getSemantics(hint).label, contains('transition warning'));
    semantics.dispose();
  });

  testWidgets('snap options keep Free contiguous and lock Beat 4 placement', (
    tester,
  ) async {
    final outgoing = _analyzedTrack(
      't1',
      'Outgoing',
      20,
    );
    final incoming = _analyzedTrack(
      't2',
      'Incoming',
      20,
    );
    await _pump(
      tester,
      previous: null,
      current: outgoing,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
    );

    final freeOutgoing = _waveformPainter(tester, 't1').mixClip!;
    final freeIncoming = _waveformPainter(tester, 't2').mixClip!;
    expect(freeIncoming.timelineStartMs, freeOutgoing.timelineEndMs);

    await tester.tap(find.byKey(const ValueKey('timeline_options_fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeline_snap_beat4')));
    await tester.pumpAndSettle();

    final lockedOutgoing = _waveformPainter(tester, 't1').mixClip!;
    final lockedIncoming = _waveformPainter(tester, 't2').mixClip!;
    expect(lockedIncoming.timelineStartMs, 12000);
    expect(
        lockedIncoming.timelineStartMs, lessThan(lockedOutgoing.timelineEndMs));
  });

  testWidgets('phone first swipe moves an unselected incoming clip', (
    tester,
  ) async {
    final starts = <int>[];
    const initialIncomingStartMs = 180000;
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      size: const Size(390, 844),
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: TimelineModel(
        clips: [
          _mixClip('t1', 0, 240000),
          _mixClip('t2', initialIncomingStartMs, 240000),
        ],
      ),
      onTimelineStartChanged: (track, startMs) {
        if (track.id == 't2') starts.add(startMs);
      },
      onPitchModeChanged: (_, __) {},
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    expect(
      find.byKey(const ValueKey('timeline_selection_toolbar_t2')),
      findsNothing,
    );
    final incoming = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_body_drag_t2')),
    );
    final visibleIncoming = incoming.intersect(
      tester.getRect(find.byKey(const ValueKey('timeline_pan_surface'))),
    );
    expect(visibleIncoming.isEmpty, isFalse);
    final gestureStart = Offset(
      visibleIncoming.left + visibleIncoming.width * 0.55,
      visibleIncoming.top + math.min(48, visibleIncoming.height * 0.45),
    );
    final gesture = await tester.startGesture(gestureStart);
    for (final delta in const [
      Offset(-24, 1),
      Offset(-24, 1),
      Offset(-24, 0),
    ]) {
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 8));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(starts, hasLength(1));
    expect(starts.single, isNot(initialIncomingStartMs));
    expect(
      find.byKey(const ValueKey('timeline_selection_toolbar_t2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t2')),
      findsOneWidget,
    );
  });

  testWidgets('tap selects an editable clip without persisting placement', (
    tester,
  ) async {
    final starts = <int>[];
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      onTimelineStartChanged: (_, startMs) => starts.add(startMs),
      onPitchModeChanged: (_, __) {},
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
    );

    await tester.tap(
      find.byKey(const ValueKey('timeline_clip_body_drag_t2')),
    );
    await tester.pumpAndSettle();

    expect(starts, isEmpty);
    expect(
      find.byKey(const ValueKey('timeline_selection_toolbar_t2')),
      findsOneWidget,
    );
  });

  testWidgets('background drag still pans when clip editing is enabled', (
    tester,
  ) async {
    final starts = <int>[];
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 600),
      upcoming: [_track('t2', 'Paper Planes', 600)],
      size: const Size(390, 844),
      onTimelineStartChanged: (_, startMs) => starts.add(startMs),
    );
    await _pinchZoom(tester);

    final surface = tester.getRect(
      find.byKey(const ValueKey('timeline_pan_surface')),
    );
    final clipRects = [
      tester.getRect(find.byKey(const ValueKey('timeline_clip_t1'))),
      tester.getRect(find.byKey(const ValueKey('timeline_clip_t2'))),
    ];
    final clipsBottom = clipRects
        .map((rect) => rect.bottom)
        .reduce((first, second) => math.max(first, second));
    final background = Offset(
      surface.center.dx,
      math.min(surface.bottom - 72, clipsBottom + 48),
    );
    for (final rect in clipRects) {
      expect(rect.contains(background), isFalse);
    }
    final beforeLeft = clipRects.first.left;

    await tester.dragFrom(background, const Offset(-140, 0));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(const ValueKey('timeline_clip_t1'))).left,
      lessThan(beforeLeft),
    );
    expect(starts, isEmpty);
  });

  testWidgets('edit-mode clip body drag updates timeline placement, not pan', (
    tester,
  ) async {
    final starts = <int>[];

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      onTimelineStartChanged: (track, ms) {
        if (track.id == 't1') starts.add(ms);
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      const Offset(90, 0),
    );
    await tester.pumpAndSettle();

    expect(starts, hasLength(1));
    expect(starts.last, greaterThan(0));
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      findsOneWidget,
    );
  });

  testWidgets('selected metadata stays outside the draggable waveform',
      (tester) async {
    final starts = <int>[];
    final current = _analyzedTrack('t1', 'Midnight Drive', 240);
    final upcoming = _analyzedTrack('t2', 'Paper Planes', 240);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [upcoming],
      onTimelineStartChanged: (track, ms) {
        if (track.id == 't2') starts.add(ms);
      },
      onPitchModeChanged: (_, __) {},
      onEditAnalysis: (_, {initialFirstDownbeatMs}) {},
      onMoveEarlier: (_) {},
      onMoveLater: (_) {},
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: TimelineModel(
        clips: [
          _mixClip('t1', 0, 240000),
          _mixClip('t2', 0, 240000),
        ],
      ),
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('timeline_tempo_t2'));
    expect(chip, findsOneWidget);
    final chipRect = tester.getRect(chip);
    final clipRect = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t2')),
    );
    expect(chipRect.overlaps(clipRect), isFalse);
    await tester.dragFrom(
      Offset(clipRect.right - 72, clipRect.top + 32),
      const Offset(100, 0),
    );
    await tester.pumpAndSettle();

    expect(
      starts,
      isNotEmpty,
      reason: 'non-button metadata must not consume waveform drag gestures',
    );
  });

  testWidgets('completed async edit replaces optimistic preview with live lock',
      (tester) async {
    final outgoingDownbeats =
        List<int>.generate(56, (index) => 112 + index * 3300);
    final incomingDownbeats =
        List<int>.generate(62, (index) => 562 + index * 3300);
    final outgoing = _analyzedTrack(
      'still-here',
      'Still Here',
      184,
      bpm: 72.73,
      downbeatsMs: outgoingDownbeats,
    );
    final incoming = _analyzedTrack(
      'csirac',
      'CSIRAC',
      202,
      bpm: 72.73,
      downbeatsMs: incomingDownbeats,
    );
    final outgoingTempo = ClipTempoMetadata(
      nativeBpm: 72.73,
      bpmConfidence: 0.62,
      downbeatsMs: outgoingDownbeats,
    );
    final incomingTempo = ClipTempoMetadata(
      nativeBpm: 72.73,
      bpmConfidence: 0.62,
      downbeatsMs: incomingDownbeats,
    );
    final committed = Completer<void>();
    int? requestedStartMs;

    Future<void> commitPlacement(Track track, int valueMs) async {
      requestedStartMs = valueMs;
      await committed.future;
    }

    TimelineModel modelAt(int incomingStartMs) => TimelineModel(
          clips: [
            _mixClip('still-here', 0, 184000, tempo: outgoingTempo),
            _mixClip(
              'csirac',
              incomingStartMs,
              202000,
              tempo: incomingTempo,
            ),
          ],
        );

    await _pump(
      tester,
      previous: null,
      current: outgoing,
      upcoming: [incoming],
      timelineModel: modelAt(171150),
      onTimelineStartChanged: commitPlacement,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_csirac')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_csirac')),
      const Offset(-30, 0),
    );
    await tester.pump();

    expect(requestedStartMs, isNotNull);
    final authoritativeStartMs = requestedStartMs! + 112;
    await _pump(
      tester,
      previous: null,
      current: outgoing,
      upcoming: [incoming],
      timelineModel: modelAt(authoritativeStartMs),
      onTimelineStartChanged: commitPlacement,
      settle: false,
    );
    committed.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Beat locked'), findsWidgets);
    expect(find.textContaining('Downbeat -112ms'), findsNothing);
  });

  testWidgets('busy placement blocks a quick second drag then re-enables edits',
      (
    tester,
  ) async {
    const initialStartMs = 180000;
    var authoritativeStartMs = initialStartMs;
    final calls = <int>[];
    final completions = <Completer<void>>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final incoming = _track('t2', 'Paper Planes', 240);

    Future<void> commitPlacement(Track track, int startMs) async {
      calls.add(startMs);
      final completion = Completer<void>();
      completions.add(completion);
      await completion.future;
      authoritativeStartMs = startMs;
    }

    TimelineModel modelAt(int incomingStartMs) => TimelineModel(
          clips: [
            _mixClip('t1', 0, 240000),
            _mixClip('t2', incomingStartMs, 240000),
          ],
        );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(initialStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t2')),
      const Offset(-30, 0),
    );
    await tester.pump();
    expect(calls, hasLength(1));
    final olderStartMs = calls.first;
    final body = find.byKey(const ValueKey('timeline_clip_body_drag_t2'));
    final beforeBlockedDrag = tester.getRect(body);

    await tester.drag(
      body,
      const Offset(-30, 0),
    );
    await tester.pump();
    final blockedStartMs =
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs;
    expect(blockedStartMs, olderStartMs);
    expect(
      calls,
      [olderStartMs],
      reason: 'a busy track must not start a second placement write',
    );
    expect(tester.getRect(body), beforeBlockedDrag);

    completions[0].complete();
    await tester.pump();
    expect(authoritativeStartMs, olderStartMs);
    expect(calls, [olderStartMs]);
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(olderStartMs),
      onTimelineStartChanged: commitPlacement,
      settle: false,
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      olderStartMs,
    );

    await tester.drag(
      body,
      const Offset(-30, 0),
    );
    await tester.pump();
    expect(calls, hasLength(2));
    final newerStartMs = calls.last;
    expect(newerStartMs, lessThan(olderStartMs));
    completions[1].complete();
    await tester.pumpAndSettle();
    expect(authoritativeStartMs, newerStartMs);
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(authoritativeStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    expect(
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs, newerStartMs);

    final correctedStartMs = newerStartMs + 137;
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(correctedStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      correctedStartMs,
      reason: 'the newest successful write must release its preview',
    );
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(newerStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    expect(
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs, newerStartMs);
  });

  testWidgets('busy placement cannot be replaced by semantic movement', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const initialStartMs = 180000;
    var authoritativeStartMs = initialStartMs;
    final calls = <int>[];
    final completions = <Completer<void>>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final incoming = _track('t2', 'Paper Planes', 240);

    Future<void> commitPlacement(Track track, int startMs) async {
      calls.add(startMs);
      final completion = Completer<void>();
      completions.add(completion);
      await completion.future;
      authoritativeStartMs = startMs;
    }

    TimelineModel modelAt(int incomingStartMs) => TimelineModel(
          clips: [
            _mixClip('t1', 0, 240000),
            _mixClip('t2', incomingStartMs, 240000),
          ],
        );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(initialStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final body = find.byKey(const ValueKey('timeline_clip_body_drag_t2'));
    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();
    final firstStartMs = calls.single;
    final firstPreviewMs =
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs;

    final node = tester.getSemantics(
      find.byKey(const ValueKey('timeline_clip_semantics_t2')),
    );
    final data = node.getSemanticsData();
    expect(data.label, contains('Saving Paper Planes timeline edit'));
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    expect(data.hasAction(SemanticsAction.decrease), isFalse);
    tester.binding.performSemanticsAction(
      ui.SemanticsActionEvent(
        type: SemanticsAction.increase,
        viewId: tester.view.viewId,
        nodeId: node.id,
      ),
    );
    await tester.pump();
    expect(calls, [firstStartMs]);
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      firstPreviewMs,
      reason: 'a suppressed semantic action must not orphan the drag preview',
    );

    completions[0].complete();
    await tester.pumpAndSettle();
    expect(authoritativeStartMs, firstStartMs);
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(authoritativeStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      firstStartMs,
    );
    final available = tester
        .getSemantics(
          find.byKey(const ValueKey('timeline_clip_semantics_t2')),
        )
        .getSemanticsData();
    expect(available.hasAction(SemanticsAction.increase), isTrue);
    expect(available.hasAction(SemanticsAction.decrease), isTrue);
    semantics.dispose();
  });

  testWidgets('dispose prevents an old transaction from reaching a successor', (
    tester,
  ) async {
    final calls = <int>[];
    final firstCompletion = Completer<void>();
    final successorCalls = <int>[];

    Future<void> commitPlacement(Track track, int startMs) async {
      calls.add(startMs);
      await firstCompletion.future;
    }

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: TimelineModel(
        clips: [
          _mixClip('t1', 0, 240000),
          _mixClip('t2', 180000, 240000),
        ],
      ),
      onTimelineStartChanged: commitPlacement,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final body = find.byKey(const ValueKey('timeline_clip_body_drag_t2'));
    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();
    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();
    expect(calls, hasLength(1));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await _pump(
      tester,
      previous: null,
      current: _track('successor', 'Successor', 240),
      upcoming: const [],
      onTimelineStartChanged: (_, startMs) => successorCalls.add(startMs),
    );

    firstCompletion.complete();
    await tester.pump();
    await tester.pump();

    expect(calls, hasLength(1));
    expect(successorCalls, isEmpty);
    expect(tester.takeException(), isNull);

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_successor')),
      const Offset(90, 0),
    );
    await tester.pumpAndSettle();
    expect(successorCalls, hasLength(1));
  });

  testWidgets('fresh parent callbacks preserve pending edit ownership', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const initialStartMs = 180000;
    final oldCompletion = Completer<void>();
    final oldCalls = <int>[];
    final replacementCalls = <int>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final incoming = _track('t2', 'Paper Planes', 240);

    Future<void> oldCallback(Track track, int startMs) async {
      oldCalls.add(startMs);
      await oldCompletion.future;
    }

    void replacementCallback(Track track, int startMs) {
      replacementCalls.add(startMs);
    }

    final model = TimelineModel(
      clips: [
        _mixClip('t1', 0, 240000),
        _mixClip('t2', initialStartMs, 240000),
      ],
    );
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: model,
      onTimelineStartChanged: oldCallback,
    );
    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t2')),
      const Offset(-30, 0),
    );
    await tester.pump();
    expect(oldCalls, hasLength(1));
    final heldPreviewMs =
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs;
    expect(heldPreviewMs, lessThan(initialStartMs));

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: model,
      onTimelineStartChanged: replacementCallback,
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      heldPreviewMs,
      reason: 'inline callback churn must not release the active preview',
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('timeline_clip_semantics_t2')),
          )
          .label,
      contains('Saving Paper Planes timeline edit'),
    );

    oldCompletion.complete();
    await tester.pump();
    await tester.pump();
    expect(oldCalls, hasLength(1));
    expect(replacementCalls, isEmpty);
    expect(tester.takeException(), isNull);
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      initialStartMs,
    );

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t2')),
      const Offset(-30, 0),
    );
    await tester.pumpAndSettle();
    expect(replacementCalls, hasLength(1));
    semantics.dispose();
  });

  testWidgets('track reorder preserves and removal prunes pending ownership', (
    tester,
  ) async {
    const incomingStartMs = 180000;
    final calls = <int>[];
    final completions = <Completer<void>>[];
    final replacementCalls = <int>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final incoming = _track('t2', 'Paper Planes', 240);
    final later = _track('t3', 'Glass', 240);

    Future<void> heldCallback(Track track, int startMs) async {
      calls.add(startMs);
      final completion = Completer<void>();
      completions.add(completion);
      await completion.future;
    }

    TimelineModel model({required bool includeIncoming}) => TimelineModel(
          clips: [
            _mixClip('t1', 0, 240000),
            if (includeIncoming) _mixClip('t2', incomingStartMs, 240000),
            _mixClip('t3', 210000, 240000),
          ],
        );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming, later],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: model(includeIncoming: true),
      onTimelineStartChanged: heldCallback,
    );
    final incomingBody = find.byKey(
      const ValueKey('timeline_clip_body_drag_t2'),
    );
    await tester.drag(incomingBody, const Offset(-30, 0));
    await tester.pump();
    expect(calls, hasLength(1));
    final heldPreviewMs =
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs;
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t2')),
      findsOneWidget,
    );

    await _pump(
      tester,
      previous: current,
      current: incoming,
      upcoming: [later],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: model(includeIncoming: true),
      onTimelineStartChanged: (track, startMs) => heldCallback(track, startMs),
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      heldPreviewMs,
      reason: 'stable lane ownership must survive a queue-role reorder',
    );
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t2')),
      findsOneWidget,
    );
    await tester.drag(incomingBody, const Offset(-30, 0));
    await tester.pump();
    expect(
      calls,
      hasLength(1),
      reason: 'the busy lock must move with the stable lane identity',
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      heldPreviewMs,
    );
    completions[0].complete();
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));

    await tester.drag(incomingBody, const Offset(-30, 0));
    await tester.pump();
    expect(calls, hasLength(2));

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [later],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: model(includeIncoming: false),
      onTimelineStartChanged: null,
    );
    expect(incomingBody, findsNothing);
    completions[1].complete();
    await tester.pump();
    expect(tester.takeException(), isNull);

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [later, incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: model(includeIncoming: true),
      onTimelineStartChanged: (_, startMs) => replacementCalls.add(startMs),
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      incomingStartMs,
      reason: 're-added tracks must not inherit stale busy or preview state',
    );
    expect(
      find.byKey(const ValueKey('timeline_trim_start_t2')),
      findsNothing,
      reason: 'a removed lane must not retain stale selection ownership',
    );
    await tester.drag(incomingBody, const Offset(-30, 0));
    await tester.pumpAndSettle();
    expect(replacementCalls, hasLength(1));
  });

  testWidgets('failed busy write reports once and ignores a second drag', (
    tester,
  ) async {
    const initialStartMs = 180000;
    var authoritativeStartMs = initialStartMs;
    final calls = <int>[];
    final completions = <Completer<void>>[];
    final current = _track('t1', 'Midnight Drive', 240);
    final incoming = _track('t2', 'Paper Planes', 240);

    Future<void> commitPlacement(Track track, int startMs) async {
      calls.add(startMs);
      final completion = Completer<void>();
      completions.add(completion);
      await completion.future;
      authoritativeStartMs = startMs;
    }

    TimelineModel modelAt(int incomingStartMs) => TimelineModel(
          clips: [
            _mixClip('t1', 0, 240000),
            _mixClip('t2', incomingStartMs, 240000),
          ],
        );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(initialStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final body = find.byKey(const ValueKey('timeline_clip_body_drag_t2'));
    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();
    final olderStartMs = calls.single;
    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();
    final blockedPreviewMs =
        _waveformPainter(tester, 't2').mixClip!.timelineStartMs;
    expect(blockedPreviewMs, olderStartMs);
    expect(calls, [olderStartMs]);

    completions[0].completeError(StateError('placement failed'));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(tester.takeException(), isNull);
    expect(calls, [olderStartMs]);
    await tester.pump();
    expect(authoritativeStartMs, initialStartMs);
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(authoritativeStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      initialStartMs,
    );

    await tester.drag(body, const Offset(-30, 0));
    await tester.pump();
    expect(calls, hasLength(2));
    completions[1].complete();
    await tester.pumpAndSettle();
  });

  testWidgets('failed latest write rolls back its optimistic preview', (
    tester,
  ) async {
    const initialStartMs = 180000;
    final placementCommit = Completer<void>();
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: TimelineModel(
        clips: [
          _mixClip('t1', 0, 240000),
          _mixClip('t2', initialStartMs, 240000),
        ],
      ),
      onTimelineStartChanged: (_, __) async {
        await placementCommit.future;
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t2')),
      const Offset(-30, 0),
    );
    await tester.pump();
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      lessThan(initialStartMs),
    );

    placementCommit.completeError(StateError('latest placement failed'));
    await tester.pump();
    expect(tester.takeException(), isA<StateError>());
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      initialStartMs,
    );
  });

  testWidgets('busy lock preserves preview across no-op and cancelled drags', (
    tester,
  ) async {
    const initialStartMs = 10000;
    var authoritativeStartMs = initialStartMs;
    final calls = <int>[];
    final firstCompletion = Completer<void>();
    final current = _track('t1', 'Midnight Drive', 240);
    final incoming = _track('t2', 'Paper Planes', 240);

    Future<void> commitPlacement(Track track, int startMs) async {
      calls.add(startMs);
      await firstCompletion.future;
      authoritativeStartMs = startMs;
    }

    TimelineModel modelAt(int incomingStartMs) => TimelineModel(
          clips: [
            _mixClip('t1', 0, 240000),
            _mixClip('t2', incomingStartMs, 240000),
          ],
        );

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(initialStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t2')));
    await tester.pumpAndSettle();

    final body = find.byKey(const ValueKey('timeline_clip_body_drag_t2'));
    await tester.drag(body, const Offset(-100, 0));
    await tester.pump();
    expect(calls, [0]);
    expect(_waveformPainter(tester, 't2').mixClip!.timelineStartMs, 0);

    await tester.drag(body, const Offset(-40, 0));
    await tester.pump();
    expect(calls, [0], reason: 'a busy no-op must not start another edit');
    expect(_waveformPainter(tester, 't2').mixClip!.timelineStartMs, 0);

    final cancelled = await tester.startGesture(tester.getCenter(body));
    for (final delta in const [Offset(40, 0), Offset(40, 0)]) {
      await cancelled.moveBy(delta);
      await tester.pump();
    }
    expect(
      _waveformPainter(tester, 't2').mixClip!.timelineStartMs,
      0,
      reason: 'the busy recognizer must not alter the in-flight preview',
    );
    tester.widget<GestureDetector>(body).onHorizontalDragCancel!();
    await tester.pump();
    await cancelled.cancel();
    await tester.pump();
    expect(calls, [0], reason: 'a cancelled busy drag must not start an edit');
    expect(_waveformPainter(tester, 't2').mixClip!.timelineStartMs, 0);

    firstCompletion.complete();
    await tester.pumpAndSettle();
    expect(authoritativeStartMs, 0);
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [incoming],
      transitionSnapMode: BeatSnapMode.free,
      timelineModel: modelAt(authoritativeStartMs),
      onTimelineStartChanged: commitPlacement,
    );
    expect(_waveformPainter(tester, 't2').mixClip!.timelineStartMs, 0);
  });

  testWidgets('busy placement blocks trim no-op and cancel attempts', (
    tester,
  ) async {
    final placementCommit = Completer<void>();
    final trimCommit = Completer<void>();
    var placementCalls = 0;
    var trimCalls = 0;

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      transitionSnapMode: BeatSnapMode.free,
      onTimelineStartChanged: (_, __) async {
        placementCalls += 1;
        await placementCommit.future;
      },
      onTrimEndChanged: (_, __) async {
        trimCalls += 1;
        await trimCommit.future;
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      const Offset(90, 0),
    );
    await tester.pump();
    expect(placementCalls, 1);
    final placementPreview = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t1')),
    );

    final trimHandle = find.byKey(const ValueKey('timeline_trim_end_t1'));
    await tester.dragFrom(
      tester.getCenter(trimHandle),
      const Offset(-70, 0),
    );
    await tester.pump();
    expect(trimCalls, 0);
    expect(
      tester.getRect(find.byKey(const ValueKey('timeline_clip_t1'))),
      placementPreview,
    );

    final cancelledTrim =
        await tester.startGesture(tester.getCenter(trimHandle));
    for (final delta in const [Offset(-40, 0), Offset(-40, 0)]) {
      await cancelledTrim.moveBy(delta);
      await tester.pump();
    }
    await cancelledTrim.cancel();
    await tester.pump();
    expect(trimCalls, 0);
    expect(
      tester.getRect(find.byKey(const ValueKey('timeline_clip_t1'))),
      placementPreview,
      reason: 'a blocked trim attempt cannot remove the placement preview',
    );

    placementCommit.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('busy trim blocks placement until the trim completes', (
    tester,
  ) async {
    final trimCommit = Completer<void>();
    final placementCommit = Completer<void>();
    var trimCalls = 0;
    var placementCalls = 0;

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      transitionSnapMode: BeatSnapMode.free,
      onTrimEndChanged: (_, __) async {
        trimCalls += 1;
        await trimCommit.future;
      },
      onTimelineStartChanged: (_, __) async {
        placementCalls += 1;
        await placementCommit.future;
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_trim_end_t1')),
      const Offset(-70, 0),
    );
    await tester.pump();
    expect(trimCalls, 1);
    final trimPreview = tester.getRect(
      find.byKey(const ValueKey('timeline_clip_t1')),
    );

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      const Offset(90, 0),
    );
    await tester.pump();
    expect(placementCalls, 0);
    expect(
      tester.getRect(find.byKey(const ValueKey('timeline_clip_t1'))),
      trimPreview,
    );

    trimCommit.complete();
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      const Offset(90, 0),
    );
    await tester.pump();
    expect(placementCalls, 1);
    placementCommit.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('trim handles beat body drag hit-testing in edit mode', (
    tester,
  ) async {
    final trimStarts = <int>[];
    final placements = <int>[];

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      onTimelineStartChanged: (track, ms) => placements.add(ms),
      onTrimStartChanged: (track, ms) {
        if (track.id == 't1') trimStarts.add(ms);
      },
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();

    expect(trimStarts, hasLength(1));
    expect(trimStarts.last, greaterThan(0));
    expect(
      placements,
      isEmpty,
      reason: 'a trim handle drag must not also move the clip body',
    );
  });

  testWidgets('disabled trim handles pass through to clip body drag', (
    tester,
  ) async {
    final starts = <int>[];

    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240)],
      onTimelineStartChanged: (track, ms) {
        if (track.id == 't1') starts.add(ms);
      },
      onTrimStartChanged: null,
      onTrimEndChanged: null,
    );
    await tester.tap(find.byKey(const ValueKey('timeline_clip_t1')));
    await tester.pumpAndSettle();

    final clip = tester.getRect(find.byKey(const ValueKey('timeline_clip_t1')));
    final gesture = await tester.startGesture(
      Offset(clip.left + 20, clip.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(80, 0));
    await tester.pumpAndSettle();
    await gesture.up();

    expect(
      starts,
      isNotEmpty,
      reason: 'disabled trim hit target must not block the clip body drag',
    );
  });

  testWidgets('edited placement and trim keep transition display accurate', (
    tester,
  ) async {
    final current = _track('t1', 'Midnight Drive', 240);
    final next = _track('t2', 'Paper Planes', 240);
    var nextStartMs = 222000;
    var currentEndMs = current.durationMs;

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      clipFor: (track, fallback) {
        if (track.id == 't1') {
          return fallback.withSourceRange(
            sourceStartMs: fallback.sourceStartMs,
            sourceEndMs: currentEndMs,
          );
        }
        if (track.id == 't2') return fallback.withTimelineStartMs(nextStartMs);
        return fallback;
      },
    );
    expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);

    nextStartMs = 250000;
    currentEndMs = 200000;
    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      clipFor: (track, fallback) {
        if (track.id == 't1') {
          return fallback.withSourceRange(
            sourceStartMs: fallback.sourceStartMs,
            sourceEndMs: currentEndMs,
          );
        }
        if (track.id == 't2') return fallback.withTimelineStartMs(nextStartMs);
        return fallback;
      },
    );
    expect(
      find.byKey(const ValueKey('transition_window')),
      findsNothing,
      reason: 'moving/trimming clips apart should remove stale overlap chrome',
    );
  });

  testWidgets(
    'fallback placement uses analyzed phrase/downbeat transition defaults',
    (tester) async {
      await _pump(
        tester,
        previous: null,
        current: _analyzedTrack('t1', 'Midnight Drive', 20),
        upcoming: [_analyzedTrack('t2', 'Phrase Entrance', 20)],
      );

      expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
      expect(find.textContaining('transition 0:08'), findsOneWidget);
      expect(find.textContaining('Beat locked'), findsOneWidget);
    },
  );

  testWidgets('fallback placement stays contiguous without reliable analysis', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 20),
      upcoming: [_track('t2', 'Paper Planes', 20)],
    );

    expect(find.byKey(const ValueKey('transition_window')), findsNothing);
  });
}
