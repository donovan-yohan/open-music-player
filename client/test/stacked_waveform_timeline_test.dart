import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/stacked_waveform_timeline.dart';

Track _track(String id, String title, int duration) => Track(
      id: id,
      title: title,
      artist: 'Artist $id',
      duration: duration,
      addedAt: DateTime.utc(2026, 1, 1),
    );

MixClip _mixClip(
  String id,
  int startMs,
  int durationMs, {
  GainEnvelope envelope = const GainEnvelope.flat(),
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
    );

Future<void> _pump(
  WidgetTester tester, {
  required Track? previous,
  required Track current,
  required List<Track> upcoming,
  Size size = const Size(390, 844),
  ValueChanged<Track>? onMoveEarlier,
  ValueChanged<Track>? onMoveLater,
  TimelineClip Function(Track, TimelineClip)? clipFor,
  TimelineModel? timelineModel,
  int playheadPositionMs = 0,
  Stream<int>? positionMsStream,
  VoidCallback? onScrubStart,
  ValueChanged<int>? onScrubUpdate,
  Future<void> Function(int)? onScrubEnd,
  void Function(Track, int)? onTimelineStartChanged,
  void Function(Track, int)? onTrimStartChanged,
  void Function(Track, int)? onTrimEndChanged,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StackedWaveformTimeline(
          previousTrack: previous,
          currentTrack: current,
          upcomingTracks: upcoming,
          peaksFor: (t) => mockWaveformPeaks(t.id),
          trimRangeFor: (t) => TrimRange.full(t.durationMs),
          clipFor: clipFor,
          timelineModel: timelineModel,
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
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
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
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188), _track('t3', 'Glass', 241)],
    );

    expect(
      find.byKey(const ValueKey('stacked_waveform_timeline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_playhead')), findsOneWidget);
    expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_mode_bar')), findsOneWidget);

    // Current + upcoming lanes each render header, clip and waveform.
    for (final id in ['t1', 't2', 't3']) {
      expect(find.byKey(ValueKey('timeline_lane_header_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('timeline_clip_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('timeline_waveform_$id')), findsOneWidget);
    }

    // Right future teaser present; no previous → no history teaser.
    expect(find.byKey(const ValueKey('right_future_teaser')), findsOneWidget);
    expect(find.byKey(const ValueKey('left_history_teaser')), findsNothing);
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

    await _pump(
      tester,
      previous: null,
      current: current,
      upcoming: [next],
      timelineModel: model,
      playheadPositionMs: 0,
      positionMsStream: positions.stream,
    );

    final before = tester.getRect(
      find.byKey(const ValueKey('timeline_playhead')),
    );
    await tester.runAsync(() async {
      positions.add(60000);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    final after = tester.getRect(
      find.byKey(const ValueKey('timeline_playhead')),
    );

    expect(after.left, greaterThan(before.left));
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

  testWidgets('renders left history teaser when a previous clip exists', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: _track('t0', 'Opening', 200),
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188)],
    );

    expect(find.byKey(const ValueKey('left_history_teaser')), findsOneWidget);
    expect(find.byKey(const ValueKey('right_future_teaser')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('timeline_lane_header_t0')),
      findsOneWidget,
    );
    expect(find.textContaining('ended'), findsOneWidget);
    expect(find.textContaining('starts in'), findsOneWidget);
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
        current: _track('n1', 'Narrow Now', 214),
        upcoming: [_track('n2', 'Narrow Next', 188)],
        size: const Size(StackedWaveformTimeline.railWidth + 1, 844),
      );

      expect(
        find.byKey(const ValueKey('stacked_waveform_timeline')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('transition_window')), findsOneWidget);
    },
  );

  testWidgets('mode bar toggles browse and edit', (tester) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
    );

    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_zoom_out')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_zoom_in')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_zoom_reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_zoom_label')), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline_zoom_in')));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline_zoom_reset')));
    await tester.pumpAndSettle();
    expect(find.text('1.0x'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    // No throw, mode bar still present.
    expect(find.byKey(const ValueKey('timeline_mode_bar')), findsOneWidget);
  });

  testWidgets('floating options panel controls snap marker mode and zoom', (
    tester,
  ) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188)],
    );

    expect(find.byKey(const ValueKey('timeline_options_fab')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline_options_fab')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('timeline_options_panel')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('timeline_snap_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_snap_4')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline_snap_16')), findsOneWidget);
    expect(find.text('4 beats'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('timeline_snap_16')));
    await tester.pumpAndSettle();
    expect(find.textContaining('16 beats'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('timeline_options_zoom_in')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('timeline_options_zoom_label')),
      findsOneWidget,
    );
    expect(find.text('1.5x'), findsWidgets);
  });

  testWidgets('browse drag pans the zoomed timeline viewport', (tester) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 240),
      upcoming: [_track('t2', 'Paper Planes', 240), _track('t3', 'Glass', 240)],
    );

    await tester.tap(find.byKey(const ValueKey('timeline_zoom_in')));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);

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
      timelineModel: TimelineModel.sequential(
        [current.id, next.id, later.id],
        sourceDurationMsFor: (_) => 240000,
      ),
      onScrubStart: () => events.add('begin'),
      onScrubUpdate: (ms) => events.add('update:$ms'),
      onScrubEnd: (ms) async => events.add('end:$ms'),
    );

    await tester.tap(find.byKey(const ValueKey('timeline_zoom_in')));
    await tester.pumpAndSettle();
    expect(find.text('1.5x'), findsOneWidget);

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

    await tester.tap(find.byKey(const ValueKey('timeline_zoom_in')));
    await tester.pumpAndSettle();
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

      await tester.tap(find.byKey(const ValueKey('timeline_zoom_in')));
      await tester.pumpAndSettle();
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

  testWidgets('shows timeline move controls for upcoming clips', (
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

    expect(
      find.byKey(const ValueKey('timeline_move_earlier_t2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline_move_later_t2')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('timeline_move_later_t2')));
    await tester.pumpAndSettle();
    expect(movedLater, ['t2']);

    await tester.tap(find.byKey(const ValueKey('timeline_move_earlier_t2')));
    await tester.pumpAndSettle();
    expect(movedEarlier, ['t2']);
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
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    final playheadBefore = tester.getRect(
      find.byKey(const ValueKey('timeline_playhead')),
    );
    await tester.drag(
      find.byKey(const ValueKey('timeline_clip_body_drag_t1')),
      const Offset(90, 0),
    );
    await tester.pumpAndSettle();

    final playheadAfter = tester.getRect(
      find.byKey(const ValueKey('timeline_playhead')),
    );

    expect(starts, isNotEmpty);
    expect(starts.last, greaterThan(0));
    expect(
      playheadAfter.left,
      playheadBefore.left,
      reason: 'edit body drag should not fall through into browse pan',
    );
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
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('timeline_trim_start_t1')),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();

    expect(trimStarts, isNotEmpty);
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
    await tester.tap(find.text('Edit'));
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
}
