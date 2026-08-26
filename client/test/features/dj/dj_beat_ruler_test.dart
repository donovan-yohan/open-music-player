import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/models/dj_beat_grid.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/widgets/dj_beat_ruler_painter.dart';
import 'package:open_music_player/features/dj/widgets/dj_waveform_lane.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

import '../../support/dj_analysis_fixtures.dart';

/// One beat at 120 BPM is 500ms, and the lane's content is
/// `durationMs / 1000 * pixelsPerSecond` wide, so a beat is exactly 45.0px at
/// the detail zoom regardless of the lane's own width.
const double beatPx = 45;

DjDeckState deckFor(QueueTrack track, {int positionMs = 0}) => DjDeckState(
      deckId: DjDeckId.a,
      queueItemId: track.queueItemId,
      trackRef: track.id,
      title: track.title,
      queueTrack: track,
      durationMs: track.durationMs,
      positionMs: positionMs,
    );

Future<Uint8List> rasterize(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.round(), size.height.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('detail zoom paints beat, bar and phrase levels at the expected '
      'x positions', (tester) async {
    final track = djAnalysisTrack(analysis: djNumberedAnalysis());
    await pumpDjLane(tester, deck: deckFor(track), track: track);

    final painters = djRulerPainters(tester);
    expect(painters, hasLength(1));
    final beats = djTickXs(painters.single, DjBeatTickLevel.beat);
    final bars = djTickXs(painters.single, DjBeatTickLevel.bar);
    final phrases = djTickXs(painters.single, DjBeatTickLevel.phrase);

    expect(beats, hasLength(djBeatGridBeats));
    for (var i = 0; i < beats.length; i++) {
      expect(beats[i], closeTo(i * beatPx, 0.5));
    }
    // Every 4th beat.
    expect(bars, hasLength(djBeatGridBeats ~/ 4));
    for (var i = 0; i < bars.length; i++) {
      expect(bars[i], closeTo(i * 4 * beatPx, 0.5));
    }
    // Every 16th beat, numbered from the first downbeat.
    expect(phrases, hasLength(djBeatGridBeats ~/ 16));
    for (var i = 0; i < phrases.length; i++) {
      expect(phrases[i], closeTo(i * 16 * beatPx, 0.5));
    }
    final labels = [
      for (final tick in painters.single.ticks)
        if (tick.level == DjBeatTickLevel.phrase) tick.phrase,
    ];
    expect(labels, [1, 2, 3, 4]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a manual downbeat phase shifts bar and phrase ticks only',
      (tester) async {
    final unshifted = djAnalysisTrack(analysis: djNumberedAnalysis());
    await pumpDjLane(tester, deck: deckFor(unshifted), track: unshifted);
    final base = djRulerPainters(tester).single;
    final baseBeats = djTickXs(base, DjBeatTickLevel.beat);
    final baseBars = djTickXs(base, DjBeatTickLevel.bar);
    final basePhrases = djTickXs(base, DjBeatTickLevel.phrase);

    final shifted = djAnalysisTrack(
      id: '43',
      analysis: djNumberedAnalysis(downbeatPhaseIndex: 2),
    );
    await pumpDjLane(tester, deck: deckFor(shifted), track: shifted);
    final moved = djRulerPainters(tester).single;

    expect(djTickXs(moved, DjBeatTickLevel.beat), baseBeats);
    final movedBars = djTickXs(moved, DjBeatTickLevel.bar);
    for (var i = 0; i < movedBars.length; i++) {
      expect(movedBars[i], closeTo(baseBars[i] + 2 * beatPx, 0.5));
    }
    final movedPhrases = djTickXs(moved, DjBeatTickLevel.phrase);
    for (var i = 0; i < movedPhrases.length; i++) {
      expect(movedPhrases[i], closeTo(basePhrases[i] + 2 * beatPx, 0.5));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview zoom drops beat ticks and keeps bars and phrases',
      (tester) async {
    final track = djAnalysisTrack(analysis: djNumberedAnalysis());
    await pumpDjLane(
      tester,
      deck: deckFor(track),
      track: track,
      pixelsPerSecond: kDjLaneOverviewPixelsPerSecond,
    );

    final painter = djRulerPainters(tester).single;
    expect(djTickXs(painter, DjBeatTickLevel.beat), isEmpty);
    expect(djTickXs(painter, DjBeatTickLevel.bar), isNotEmpty);
    expect(djTickXs(painter, DjBeatTickLevel.phrase), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unnumbered ruler paints bars but no phrase level',
      (tester) async {
    final track = djAnalysisTrack(analysis: djUnnumberedAnalysis());
    await pumpDjLane(tester, deck: deckFor(track), track: track);

    final painter = djRulerPainters(tester).single;
    expect(djTickXs(painter, DjBeatTickLevel.beat), isNotEmpty);
    expect(djTickXs(painter, DjBeatTickLevel.bar), isNotEmpty);
    expect(djTickXs(painter, DjBeatTickLevel.phrase), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a track with no beat grid mounts the lane without a ruler',
      (tester) async {
    final track = djAnalysisTrack(analysis: djNoGridAnalysis());
    await pumpDjLane(tester, deck: deckFor(track), track: track);

    expect(DjBeatRuler.forAnalysis(track.analysis), isNull);
    expect(djRulerPainters(tester), isEmpty);
    expect(find.byType(DjWaveformLane), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the painter survives every tier and an empty tick list', () {
    const style = TextStyle(fontSize: 11);
    for (final ticks in <List<DjBeatTick>>[
      djBeatRulerTicks(
        ruler: DjBeatRuler.forAnalysis(djNumberedAnalysis())!,
        durationMs: djBeatTrackSeconds * 1000,
        contentWidth: djBeatTrackSeconds * kDjLaneDetailPixelsPerSecond,
        pixelsPerSecond: kDjLaneDetailPixelsPerSecond,
      ),
      djBeatRulerTicks(
        ruler: DjBeatRuler.forAnalysis(djUnnumberedAnalysis())!,
        durationMs: djBeatTrackSeconds * 1000,
        contentWidth: djBeatTrackSeconds * kDjLaneDetailPixelsPerSecond,
        pixelsPerSecond: kDjLaneDetailPixelsPerSecond,
      ),
      const <DjBeatTick>[],
    ]) {
      final painter = DjBeatRulerPainter(
        ticks: ticks,
        beatColor: const Color(0x4739C6B6),
        barColor: const Color(0x8C39C6B6),
        phraseColor: const Color(0xD939C6B6),
        labelStyle: style,
      );
      final recorder = ui.PictureRecorder();
      expect(
        () => painter.paint(Canvas(recorder), const Size(400, 40)),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    }
  });

  test('shouldRepaint ignores everything but the tick list and its colours',
      () {
    const style = TextStyle(fontSize: 11);
    final ticks = djBeatRulerTicks(
      ruler: DjBeatRuler.forAnalysis(djNumberedAnalysis())!,
      durationMs: djBeatTrackSeconds * 1000,
      contentWidth: djBeatTrackSeconds * kDjLaneDetailPixelsPerSecond,
      pixelsPerSecond: kDjLaneDetailPixelsPerSecond,
    );
    DjBeatRulerPainter build(List<DjBeatTick> source, {Color? beat}) =>
        DjBeatRulerPainter(
          ticks: source,
          beatColor: beat ?? const Color(0x4739C6B6),
          barColor: const Color(0x8C39C6B6),
          phraseColor: const Color(0xD939C6B6),
          labelStyle: style,
        );

    expect(build(ticks).shouldRepaint(build(ticks)), isFalse);
    expect(
      build(ticks, beat: const Color(0xFF000000)).shouldRepaint(build(ticks)),
      isTrue,
    );
    expect(build(List.of(ticks)).shouldRepaint(build(ticks)), isTrue);
  });

  testWidgets('the shared painter draws different pixels with markers off',
      (tester) async {
    final waveform = TimelineWaveformData.fromPeaks(
      const [0.9, 0.3, 0.7, 0.2, 0.8, 0.4],
      durationMs: 4000,
      beatsMs: const [0, 500, 1000, 1500, 2000, 2500, 3000, 3500],
      downbeatsMs: const [0, 2000],
      analyzed: true,
    );
    TimelineWaveformPainter build({required bool markers}) =>
        TimelineWaveformPainter(
          peaks: waveform.peaks,
          waveform: waveform,
          laneIdentity: markers ? 'markers-on' : 'markers-off',
          paintCache: TimelineWaveformPaintCache(),
          viewportPixelsPerMs: 0.09,
          viewportOriginMs: 0,
          color: const Color(0xFF4FC3F7),
          dimColor: const Color(0xFF9E9E9E),
          handleColor: const Color(0xFFFFFFFF),
          musicalMarkers: markers,
        );

    const size = Size(360, 48);
    // Picture.toImage needs the real event loop, not the test's fake async.
    late Uint8List withMarkers;
    late Uint8List withoutMarkers;
    await tester.runAsync(() async {
      withMarkers = await rasterize(build(markers: true), size);
      withoutMarkers = await rasterize(build(markers: false), size);
    });
    expect(withMarkers, isNot(equals(withoutMarkers)));
    expect(
      build(markers: false).shouldRepaint(build(markers: true)),
      isTrue,
    );
  });
}
