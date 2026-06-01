import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

Future<void> _pump(
  WidgetTester tester, {
  required Track? previous,
  required Track current,
  required List<Track> upcoming,
}) async {
  tester.view.physicalSize = const Size(390, 844);
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
      expect(maxDelta, greaterThan(0.6),
          reason: 'adjacent bars should spike, not average out');

      // A uniform averaged strip (all == mean) would lose this structure:
      // require high spread.
      final mean = peaks.reduce((a, b) => a + b) / peaks.length;
      final variance =
          peaks.map((p) => (p - mean) * (p - mean)).reduce((a, b) => a + b) /
              peaks.length;
      expect(math.sqrt(variance), greaterThan(0.2),
          reason: 'uniform averaged strip should fail');
    });

    test('are deterministic per track id', () {
      expect(mockWaveformPeaks('t1'), mockWaveformPeaks('t1'));
      expect(mockWaveformPeaks('t1'), isNot(mockWaveformPeaks('t2')));
    });
  });

  testWidgets('renders stacked lanes, shared playhead and transition window',
      (tester) async {
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

  testWidgets('renders left history teaser when a previous clip exists',
      (tester) async {
    await _pump(
      tester,
      previous: _track('t0', 'Opening', 200),
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: [_track('t2', 'Paper Planes', 188)],
    );

    expect(find.byKey(const ValueKey('left_history_teaser')), findsOneWidget);
    expect(find.byKey(const ValueKey('right_future_teaser')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('timeline_lane_header_t0')), findsOneWidget);
    expect(find.textContaining('ended'), findsOneWidget);
    expect(find.textContaining('starts in'), findsOneWidget);
  });

  testWidgets('mode bar toggles browse and edit', (tester) async {
    await _pump(
      tester,
      previous: null,
      current: _track('t1', 'Midnight Drive', 214),
      upcoming: const [],
    );

    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('mock'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    // No throw, mode bar still present.
    expect(find.byKey(const ValueKey('timeline_mode_bar')), findsOneWidget);
  });
}
