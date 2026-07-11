import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

TimelineWaveformPainter _painter(
  List<double> peaks, {
  int snapMarkerCount = 0,
  TimelineWaveformData? waveform,
  MixClip? mixClip,
  Object? mappingRevision,
  double viewportPixelsPerMs = 0,
  int viewportOriginMs = 0,
  double visibleStartFraction = 0,
  double visibleEndFraction = 1,
  TimelineWaveformPaintCache? paintCache,
}) =>
    TimelineWaveformPainter(
      peaks: peaks,
      waveform: waveform,
      mixClip: mixClip,
      mappingRevision: mappingRevision,
      paintCache: paintCache,
      viewportPixelsPerMs: viewportPixelsPerMs,
      viewportOriginMs: viewportOriginMs,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
      color: const Color(0xFF2E7D32),
      dimColor: const Color(0xFF90A4AE),
      handleColor: const Color(0xFFFFFFFF),
      snapMarkerCount: snapMarkerCount,
    );

void _paint(TimelineWaveformPainter painter, Size size) {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, size);
  recorder.endRecording().dispose();
}

void main() {
  group('TimelineWaveformPainter narrow slots', () {
    test('does not throw when peaks outnumber horizontal pixels', () {
      final painter = _painter(List<double>.filled(100, 0.5));
      // 100 peaks / 10px => slot 0.1 (< 1.0) inverts the bar-width clamp.
      expect(() => _paint(painter, const Size(10, 40)), returnsNormally);
    });

    test('does not throw at a sub-pixel-per-peak extreme', () {
      final painter = _painter(List<double>.filled(200, 0.8));
      expect(() => _paint(painter, const Size(4, 24)), returnsNormally);
    });

    test('still renders normally for wide slots', () {
      final painter = _painter(List<double>.filled(8, 0.5));
      expect(() => _paint(painter, const Size(320, 40)), returnsNormally);
    });

    test('draws prototype snap marker counts without throwing', () {
      for (final count in [1, 4, 16]) {
        final painter = _painter(
          List<double>.filled(32, 0.5),
          snapMarkerCount: count,
        );
        expect(() => _paint(painter, const Size(320, 40)), returnsNormally);
      }
    });

    test('draws rich spectral waveform markers without throwing', () {
      const waveform = TimelineWaveformData(
        durationMs: 4000,
        frames: [
          WaveformFrame(peak: 0.2, rms: 0.1, low: 0.8, mid: 0.3, high: 0.1),
          WaveformFrame(peak: 0.7, rms: 0.4, low: 0.4, mid: 0.8, high: 0.2),
          WaveformFrame(peak: 1.0, rms: 0.7, low: 0.9, mid: 0.6, high: 0.4),
          WaveformFrame(peak: 0.5, rms: 0.3, low: 0.2, mid: 0.4, high: 0.9),
        ],
        beatsMs: [0, 500, 1000, 1500],
        downbeatsMs: [0],
        transientsMs: [750, 1250],
        silenceRanges: [WaveformTimeRange(startMs: 0, endMs: 250)],
        analyzed: true,
        resolutionLabel: 'detail',
      );
      final painter = _painter(waveform.peaks, waveform: waveform);

      expect(() => _paint(painter, const Size(320, 64)), returnsNormally);
    });

    test('falls back to peaks when rich waveform frames are empty', () {
      const waveform = TimelineWaveformData(
        durationMs: 4000,
        frames: [],
        beatsMs: [0, 1000, 2000, 3000],
      );
      final painter = _painter(
        const [0.2, 0.5, 0.8, 0.4],
        waveform: waveform,
      );

      expect(() => _paint(painter, const Size(320, 64)), returnsNormally);
    });

    test('can paint a culled visible slice of a dense waveform', () {
      final waveform = richWaveformForTrack(
        _track(),
        sampleCount: 131072,
      );
      final painter = _painter(
        waveform.peaks,
        waveform: waveform,
        visibleStartFraction: 0.40,
        visibleEndFraction: 0.405,
      );

      expect(() => _paint(painter, const Size(480000, 64)), returnsNormally);
    });

    test('paints sliced phase-aligned markers through trimmed BPM ramps', () {
      const rampStartMs = 4600;
      const rampDurationMs = 76800;
      final outgoing = _rampedClip(
        id: 'outgoing',
        sourceDurationMs: 92000,
        sourceStartMs: 1800,
        sourceEndMs: 92000,
        timelineStartMs: 1000,
        rampStartMs: rampStartMs,
        rampEndMs: rampStartMs + rampDurationMs,
        startRate: 1,
        endRate: 1.25,
      );
      final incoming = _rampedClip(
        id: 'incoming',
        sourceDurationMs: 75000,
        sourceStartMs: 960,
        sourceEndMs: 75000,
        timelineStartMs: rampStartMs,
        rampStartMs: rampStartMs,
        rampEndMs: rampStartMs + rampDurationMs,
        startRate: 0.8,
        endRate: 1,
      );
      final outgoingBeats = List<int>.generate(
        145,
        (index) => 5400 + index * 600,
      );
      final incomingBeats = List<int>.generate(
        145,
        (index) => 960 + index * 480,
      );
      const phaseIndices = [0, 33, 68, 105, 144];
      final outgoingFull = TimelineWaveformData(
        durationMs: 100000,
        frames: List<WaveformFrame>.filled(
          256,
          const WaveformFrame(
            peak: 0.7,
            rms: 0.45,
            low: 0.5,
            mid: 0.6,
            high: 0.3,
          ),
        ),
        beatsMs: outgoingBeats,
        downbeatsMs: [
          for (var index = 0; index < outgoingBeats.length; index += 4)
            outgoingBeats[index],
        ],
        transientsMs: [
          for (final index in phaseIndices) outgoingBeats[index],
        ],
      );
      final incomingFull = TimelineWaveformData(
        durationMs: 76000,
        frames: List<WaveformFrame>.filled(
          256,
          const WaveformFrame(
            peak: 0.7,
            rms: 0.45,
            low: 0.5,
            mid: 0.6,
            high: 0.3,
          ),
        ),
        beatsMs: incomingBeats,
        downbeatsMs: [
          for (var index = 0; index < incomingBeats.length; index += 4)
            incomingBeats[index],
        ],
        transientsMs: [
          for (final index in phaseIndices) incomingBeats[index],
        ],
      );
      final outgoingSlice = outgoingFull.sliced(
        sourceStartMs: outgoing.placement.sourceStartMs,
        sourceEndMs: outgoing.placement.sourceEndMs,
        targetSampleCount: 512,
      );
      final incomingSlice = incomingFull.sliced(
        sourceStartMs: incoming.placement.sourceStartMs,
        sourceEndMs: incoming.placement.sourceEndMs,
        targetSampleCount: 512,
      );
      const pixelsPerMs = 0.02;

      List<double> localMarkerXs(
        TimelineWaveformData waveform,
        MixClip clip,
        List<int> markers,
        double minSpacingPx,
      ) {
        return timelineWaveformMarkerXs(
          localMarkersMs: markers,
          mixClip: clip,
          sourceDurationMs: waveform.durationMs,
          width: clip.timelineDurationMs * pixelsPerMs,
          viewportPixelsPerMs: pixelsPerMs,
          viewportOriginMs: 0,
          visibleSourceStartMs: 0,
          visibleSourceEndMs: waveform.durationMs,
          visibleStartFraction: 0,
          visibleEndFraction: 1,
          minSpacingPx: minSpacingPx,
        );
      }

      List<double> globalMarkerXs(
        TimelineWaveformData waveform,
        MixClip clip,
        List<int> markers,
        double minSpacingPx,
      ) =>
          localMarkerXs(waveform, clip, markers, minSpacingPx)
              .map((x) => x + clip.timelineStartMs * pixelsPerMs)
              .toList(growable: false);

      final outgoingBeatXs = globalMarkerXs(
        outgoingSlice,
        outgoing,
        outgoingSlice.beatsMs,
        7,
      );
      final incomingBeatXs = globalMarkerXs(
        incomingSlice,
        incoming,
        incomingSlice.beatsMs,
        7,
      );
      expect(outgoingBeatXs, hasLength(145));
      expect(incomingBeatXs, hasLength(145));
      for (var index = 0; index < outgoingBeatXs.length; index++) {
        expect(
          outgoingBeatXs[index],
          closeTo(incomingBeatXs[index], 0.03),
        );
      }

      final expectedMixMs = [4600, 23800, 43000, 62200, 81400];
      for (var index = 0; index < expectedMixMs.length; index++) {
        final beatIndex = phaseIndices[index];
        final expectedX = expectedMixMs[index] * pixelsPerMs;
        expect(outgoingBeatXs[beatIndex], closeTo(expectedX, 0.03));
        expect(incomingBeatXs[beatIndex], closeTo(expectedX, 0.03));
      }

      for (final markerSet in [
        (
          outgoing: outgoingSlice.downbeatsMs,
          incoming: incomingSlice.downbeatsMs,
          minSpacing: 14.0,
        ),
        (
          outgoing: outgoingSlice.transientsMs,
          incoming: incomingSlice.transientsMs,
          minSpacing: 10.0,
        ),
      ]) {
        final outgoingXs = globalMarkerXs(
          outgoingSlice,
          outgoing,
          markerSet.outgoing,
          markerSet.minSpacing,
        );
        final incomingXs = globalMarkerXs(
          incomingSlice,
          incoming,
          markerSet.incoming,
          markerSet.minSpacing,
        );
        expect(outgoingXs, hasLength(incomingXs.length));
        for (var index = 0; index < outgoingXs.length; index++) {
          expect(outgoingXs[index], closeTo(incomingXs[index], 0.03));
        }
      }

      expect(
        outgoingBeatXs.last - outgoingBeatXs[outgoingBeatXs.length - 2],
        lessThan(outgoingBeatXs[1] - outgoingBeatXs.first),
      );

      final outgoingLocalXs = localMarkerXs(
        outgoingSlice,
        outgoing,
        outgoingSlice.beatsMs,
        7,
      );
      const visibleStartIndex = 20;
      const visibleEndIndex = 120;
      final culledXs = timelineWaveformMarkerXs(
        localMarkersMs: outgoingSlice.beatsMs,
        mixClip: outgoing,
        sourceDurationMs: outgoingSlice.durationMs,
        width: outgoing.timelineDurationMs * pixelsPerMs,
        viewportPixelsPerMs: pixelsPerMs,
        viewportOriginMs: 0,
        visibleSourceStartMs: outgoingSlice.beatsMs[visibleStartIndex],
        visibleSourceEndMs: outgoingSlice.beatsMs[visibleEndIndex],
        visibleStartFraction: outgoingLocalXs[visibleStartIndex] /
            (outgoing.timelineDurationMs * pixelsPerMs),
        visibleEndFraction: outgoingLocalXs[visibleEndIndex] /
            (outgoing.timelineDurationMs * pixelsPerMs),
        minSpacingPx: 7,
      );
      expect(
        culledXs,
        orderedEquals(
          outgoingLocalXs.sublist(visibleStartIndex, visibleEndIndex + 1),
        ),
      );

      expect(
        () => _paint(
          _painter(
            outgoingSlice.peaks,
            waveform: outgoingSlice,
            mixClip: outgoing,
            mappingRevision: outgoing.rateAutomation,
          ),
          Size(outgoing.timelineDurationMs * pixelsPerMs, 64),
        ),
        returnsNormally,
      );
      expect(
        () => _paint(
          _painter(
            incomingSlice.peaks,
            waveform: incomingSlice,
            mixClip: incoming,
            mappingRevision: incoming.rateAutomation,
          ),
          Size(incoming.timelineDurationMs * pixelsPerMs, 64),
        ),
        returnsNormally,
      );
    });

    test(
      'uses shared mix-time buckets for the 145.14 to 138.02 BPM overlap',
      () {
        const overlapStartMs = 95120;
        const overlapEndMs = 140103;
        const outgoingBpm = 145.14;
        const incomingBpm = 138.02;
        const viewportWidth = 426.67;
        const devicePixelRatio = 3.0;
        const pixelsPerMs = viewportWidth / (overlapEndMs - overlapStartMs);
        final outgoing = _rampedClip(
          id: 'outgoing-phase',
          sourceDurationMs: 180000,
          sourceStartMs: 12000,
          sourceEndMs: 170000,
          timelineStartMs: 0,
          rampStartMs: overlapStartMs,
          rampEndMs: overlapEndMs,
          startRate: 1,
          endRate: incomingBpm / outgoingBpm,
        );
        final incoming = _rampedClip(
          id: 'incoming-phase',
          sourceDurationMs: 76000,
          sourceStartMs: 4200,
          sourceEndMs: 70000,
          timelineStartMs: overlapStartMs,
          rampStartMs: overlapStartMs,
          rampEndMs: overlapEndMs,
          startRate: outgoingBpm / incomingBpm,
          endRate: 1,
        );
        final anchorsMs = [
          for (var ms = overlapStartMs; ms <= overlapEndMs; ms += 250) ms,
        ];
        final outgoingMarkers = _localMarkersForMixAnchors(outgoing, anchorsMs);
        final incomingMarkers = _localMarkersForMixAnchors(incoming, anchorsMs);

        for (var index = 0; index < anchorsMs.length; index++) {
          final outgoingAnchor = outgoing.timelineMsForSourcePosition(
            outgoing.placement.sourceStartMs + outgoingMarkers[index],
          );
          final incomingAnchor = incoming.timelineMsForSourcePosition(
            incoming.placement.sourceStartMs + incomingMarkers[index],
          );
          expect((outgoingAnchor - incomingAnchor).abs(), lessThanOrEqualTo(1));
        }

        List<double> visibleGlobalXs(
            MixClip clip, List<int> markers, double spacing) {
          final localXs = timelineWaveformMarkerXs(
            localMarkersMs: markers,
            mixClip: clip,
            sourceDurationMs: clip.selectedDurationMs,
            width: math.max(8, clip.timelineDurationMs * pixelsPerMs),
            viewportPixelsPerMs: pixelsPerMs,
            viewportOriginMs: overlapStartMs,
            visibleSourceStartMs: clip.sourcePositionAt(overlapStartMs) -
                clip.placement.sourceStartMs,
            visibleSourceEndMs: clip.sourcePositionAt(overlapEndMs) -
                clip.placement.sourceStartMs,
            visibleStartFraction: (overlapStartMs - clip.timelineStartMs) /
                clip.timelineDurationMs,
            visibleEndFraction:
                (overlapEndMs - clip.timelineStartMs) / clip.timelineDurationMs,
            minSpacingPx: spacing,
          );
          return localXs
              .map(
                (x) =>
                    x + (clip.timelineStartMs - overlapStartMs) * pixelsPerMs,
              )
              .toList(growable: false);
        }

        final outgoingBeatXs = visibleGlobalXs(outgoing, outgoingMarkers, 7);
        final incomingBeatXs = visibleGlobalXs(incoming, incomingMarkers, 7);
        final outgoingDownbeatXs = visibleGlobalXs(
          outgoing,
          [
            for (var index = 0; index < outgoingMarkers.length; index += 4)
              outgoingMarkers[index]
          ],
          14,
        );
        final incomingDownbeatXs = visibleGlobalXs(
          incoming,
          [
            for (var index = 0; index < incomingMarkers.length; index += 4)
              incomingMarkers[index]
          ],
          14,
        );

        for (final paired in [
          (outgoing: outgoingBeatXs, incoming: incomingBeatXs),
          (outgoing: outgoingDownbeatXs, incoming: incomingDownbeatXs),
        ]) {
          expect(paired.outgoing, isNotEmpty);
          expect(paired.outgoing, hasLength(paired.incoming.length));
          for (var index = 0; index < paired.outgoing.length; index++) {
            expect(
              (paired.outgoing[index] - paired.incoming[index]).abs() *
                  devicePixelRatio,
              lessThanOrEqualTo(1),
            );
          }
        }

        final zoomedOut = visibleGlobalXs(outgoing, outgoingMarkers, 7);
        const zoomedInPixelsPerMs = pixelsPerMs * 5;
        final zoomedIn = timelineWaveformMarkerXs(
          localMarkersMs: outgoingMarkers,
          mixClip: outgoing,
          sourceDurationMs: outgoing.selectedDurationMs,
          width: math.max(
            8,
            outgoing.timelineDurationMs * zoomedInPixelsPerMs,
          ),
          viewportPixelsPerMs: zoomedInPixelsPerMs,
          viewportOriginMs: overlapStartMs,
          visibleSourceStartMs: outgoing.sourcePositionAt(overlapStartMs) -
              outgoing.placement.sourceStartMs,
          visibleSourceEndMs: outgoing.sourcePositionAt(overlapEndMs) -
              outgoing.placement.sourceStartMs,
          visibleStartFraction: (overlapStartMs - outgoing.timelineStartMs) /
              outgoing.timelineDurationMs,
          visibleEndFraction: (overlapEndMs - outgoing.timelineStartMs) /
              outgoing.timelineDurationMs,
          minSpacingPx: 7,
        );
        expect(zoomedIn.length, greaterThan(zoomedOut.length));
      },
    );

    test('keeps shared buckets when clip starts and trims differ', () {
      const pixelsPerMs = 0.01;
      final earlierClip = MixClip(
        placement: TimelineClip.clamped(
          id: 'earlier',
          trackId: 'earlier',
          sourceDurationMs: 6000,
          sourceStartMs: 0,
          sourceEndMs: 5000,
          timelineStartMs: 0,
        ),
      );
      final trimmedLaterClip = MixClip(
        placement: TimelineClip.clamped(
          id: 'trimmed-later',
          trackId: 'trimmed-later',
          sourceDurationMs: 8000,
          sourceStartMs: 1000,
          sourceEndMs: 6000,
          timelineStartMs: 250,
        ),
      );
      final earlierMarkers = [for (var ms = 0; ms <= 4500; ms += 250) ms];
      final laterMarkers = [for (var ms = 0; ms <= 4250; ms += 250) ms];

      List<double> globalXs(MixClip clip, List<int> markers) =>
          timelineWaveformMarkerXs(
            localMarkersMs: markers,
            mixClip: clip,
            sourceDurationMs: clip.selectedDurationMs,
            width: math.max(8, clip.timelineDurationMs * pixelsPerMs),
            viewportPixelsPerMs: pixelsPerMs,
            viewportOriginMs: 0,
            visibleSourceStartMs: 0,
            visibleSourceEndMs: clip.selectedDurationMs,
            visibleStartFraction: 0,
            visibleEndFraction: 1,
            minSpacingPx: 7,
          )
              .map((x) => x + clip.timelineStartMs * pixelsPerMs)
              .where((x) => x >= trimmedLaterClip.timelineStartMs * pixelsPerMs)
              .toList(growable: false);

      expect(
        globalXs(earlierClip, earlierMarkers),
        orderedEquals(globalXs(trimmedLaterClip, laterMarkers)),
      );
    });

    test('enforces spacing across boundary-adjacent buckets', () {
      final markerXs = _spacingMarkerXs([60, 71, 142]);

      expect(markerXs, hasLength(2));
      for (var index = 1; index < markerXs.length; index++) {
        expect(markerXs[index] - markerXs[index - 1], greaterThanOrEqualTo(7));
      }
    });

    test('clipped ranges do not reselect a conflicting bucket neighbor', () {
      final full = _spacingMarkerXs([60, 71, 142, 500]);
      final clipped = _spacingMarkerXs(
        [60, 71, 142, 500],
        visibleSourceStartMs: 71,
      );

      expect(
        clipped,
        orderedEquals(full.where((x) => x >= 7.1).toList()),
      );
    });

    test('density selection resumes after a real marker gap', () {
      final markerXs = _spacingMarkerXs([60, 71, 500]);

      expect(markerXs, hasLength(2));
      expect(markerXs.last, closeTo(50, 0.001));
    });

    test('absolute bucket phase is invariant to viewport origin', () {
      final originZero = _spacingMarkerXs([60, 71, 142, 500], originMs: 0);
      final panned = _spacingMarkerXs([60, 71, 142, 500], originMs: 8432);

      expect(panned, orderedEquals(originZero));
    });

    test('reuses marker and RGB geometry across viewport-only paints', () {
      final cache = TimelineWaveformPaintCache();
      final waveform = TimelineWaveformData(
        durationMs: 120000,
        frames: List<WaveformFrame>.filled(
          1024,
          const WaveformFrame(
            peak: 0.8,
            rms: 0.5,
            low: 0.2,
            mid: 0.6,
            high: 0.9,
          ),
        ),
        beatsMs: [for (var ms = 0; ms <= 120000; ms += 250) ms],
        downbeatsMs: [for (var ms = 0; ms <= 120000; ms += 1000) ms],
        transientsMs: [for (var ms = 125; ms <= 120000; ms += 500) ms],
      );
      final clip = MixClip(
        placement: TimelineClip.clamped(
          id: 'cached-paint',
          trackId: 'cached-paint',
          sourceDurationMs: 120000,
          sourceStartMs: 0,
          sourceEndMs: 120000,
          timelineStartMs: 20000,
        ),
      );
      final first = _painter(
        waveform.peaks,
        waveform: waveform,
        mixClip: clip,
        mappingRevision: clip.rateAutomation,
        viewportPixelsPerMs: 0.01,
        viewportOriginMs: 0,
        paintCache: cache,
      );
      final panned = _painter(
        waveform.peaks,
        waveform: waveform,
        mixClip: clip,
        mappingRevision: clip.rateAutomation,
        viewportPixelsPerMs: 0.01,
        viewportOriginMs: 18000,
        visibleStartFraction: 0.1,
        visibleEndFraction: 0.5,
        paintCache: cache,
      );

      _paint(first, const Size(1200, 64));
      _paint(panned, const Size(1200, 64));

      expect(cache.paintCount, 2);
      expect(cache.frameGeometryBuildCount, 1);
      expect(cache.markerGeometryBuildCount, 1);
      expect(panned.shouldRepaint(first), isTrue);
    });

    test('retains geometry for a lane wider than 4096 physical pixels', () {
      final cache = TimelineWaveformPaintCache();
      final waveform = TimelineWaveformData(
        durationMs: 60000,
        analyzed: true,
        frames: List<WaveformFrame>.filled(
          4800,
          const WaveformFrame(
            peak: 0.8,
            rms: 0.5,
            low: 0.2,
            mid: 0.6,
            high: 0.9,
          ),
        ),
      );
      final painter = _painter(
        waveform.peaks,
        waveform: waveform,
        paintCache: cache,
      );

      // 1600 logical pixels at DPR3 is a 4800-physical-pixel lane.
      _paint(painter, const Size(1600, 64));
      final missesAfterFirstPaint = cache.frameGeometryMissCount;
      _paint(painter, const Size(1600, 64));

      expect(missesAfterFirstPaint, 4800);
      expect(cache.frameGeometryMissCount, missesAfterFirstPaint);
      expect(cache.frameGeometryEntryCount, 4800);
      expect(cache.estimatedByteSize, 4800 * 96 + 128 + 256);
    });

    test('notifies only when retained paint bytes change', () {
      var notifications = 0;
      final cache = TimelineWaveformPaintCache(
        onSizeChanged: () => notifications++,
      );
      final waveform = TimelineWaveformData(
        durationMs: 16000,
        analyzed: true,
        frames: List<WaveformFrame>.filled(
          16,
          const WaveformFrame(
            peak: 0.8,
            rms: 0.5,
            low: 0.2,
            mid: 0.6,
            high: 0.9,
          ),
        ),
      );
      final painter = _painter(
        waveform.peaks,
        waveform: waveform,
        paintCache: cache,
      );

      _paint(painter, const Size(160, 64));
      _paint(painter, const Size(160, 64));

      expect(notifications, 1);
      expect(cache.frameGeometryEntryCount, 16);
    });

    test('trims retained geometry in place without rebinding frame data', () {
      final cache = TimelineWaveformPaintCache();
      final waveform = TimelineWaveformData(
        durationMs: 60000,
        analyzed: true,
        frames: List<WaveformFrame>.filled(
          4096,
          const WaveformFrame(
            peak: 0.8,
            rms: 0.5,
            low: 0.2,
            mid: 0.6,
            high: 0.9,
          ),
        ),
      );
      final painter = _painter(
        waveform.peaks,
        waveform: waveform,
        paintCache: cache,
      );
      _paint(painter, const Size(1600, 64));
      final buildCount = cache.frameGeometryBuildCount;
      final bytesBeforeTrim = cache.estimatedByteSize;

      final freed = cache.clearRetainedGeometry();

      expect(freed, greaterThan(0));
      expect(cache.estimatedByteSize,
          TimelineWaveformPaintCache.minimumRetainedByteSize);
      expect(cache.frameGeometryEntryCount, 0);
      expect(cache.geometryTrimCount, 1);
      expect(cache.trimmedGeometryByteCount, bytesBeforeTrim - 256);

      _paint(painter, const Size(1600, 64));
      expect(cache.frameGeometryBuildCount, buildCount);
      expect(cache.frameGeometryEntryCount, 4096);
    });

    test('culls waveform frames through trim and zoom in source space', () {
      final clip = MixClip(
        placement: TimelineClip.clamped(
          id: 'trimmed',
          trackId: 'trimmed',
          sourceDurationMs: 12000,
          sourceStartMs: 2000,
          sourceEndMs: 10000,
          timelineStartMs: 0,
        ),
        rateAutomation: const PlaybackRateAutomation(
          segments: [
            PlaybackRateSegment(
              startMs: 0,
              endMs: 8000,
              startRate: 0.75,
              endRate: 1.25,
            ),
          ],
        ),
      );
      final range = timelineWaveformVisibleFrameRange(
        mixClip: clip,
        frameCount: 8000,
        sourceDurationMs: 8000,
        visibleStartFraction: 0.5,
        visibleEndFraction: 0.55,
        padding: 0,
      );
      final visibleStartSource = clip.sourcePositionAt(
            (clip.timelineDurationMs * 0.5).round(),
          ) -
          clip.placement.sourceStartMs;

      expect(range.start, closeTo(visibleStartSource, 2));
      expect(range.end - range.start, lessThan(900));
    });

    test('repaints when the active rate schedule changes', () {
      final base = _rampedClip(
        id: 'repaint',
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 10000,
        timelineStartMs: 0,
        rampStartMs: 0,
        rampEndMs: 10000,
        startRate: 1,
        endRate: 1,
      );
      final ramped = _rampedClip(
        id: 'repaint',
        sourceDurationMs: 11250,
        sourceStartMs: 0,
        sourceEndMs: 11250,
        timelineStartMs: 0,
        rampStartMs: 0,
        rampEndMs: 10000,
        startRate: 1,
        endRate: 1.25,
      );
      final oldPainter = _painter(
        const [0.5, 0.6],
        mixClip: base,
        mappingRevision: base.rateAutomation,
      );
      final nextPainter = _painter(
        const [0.5, 0.6],
        mixClip: ramped,
        mappingRevision: ramped.rateAutomation,
      );
      final samePainter = _painter(
        const [0.5, 0.6],
        mixClip: base,
        mappingRevision: base.rateAutomation,
      );

      expect(nextPainter.shouldRepaint(oldPainter), isTrue);
      expect(samePainter.shouldRepaint(oldPainter), isFalse);

      final pannedPainter = _painter(
        const [0.5, 0.6],
        mixClip: base,
        mappingRevision: base.rateAutomation,
        viewportOriginMs: 5000,
      );
      expect(pannedPainter.shouldRepaint(oldPainter), isFalse);
    });
  });

  test('marker thinning keeps absolute picks when a trim begins mid-bucket',
      () {
    final markers = List<int>.generate(101, (index) => index * 10);
    final full = _spacingMarkerXs(markers);
    final trimmed = _spacingMarkerXs(markers, visibleSourceStartMs: 40);

    expect(
      trimmed,
      orderedEquals(full.where((x) => x >= 4).toList(growable: false)),
      reason: '1px markers with 7px spacing must not rephase at trim start 4',
    );
  });

  test('analyzed slices cap to covered bins and preserve transient peaks', () {
    final source = TimelineWaveformData(
      durationMs: 800,
      analyzed: true,
      frames: [
        for (var index = 0; index < 8; index++)
          WaveformFrame(
            peak: index == 3 ? 1 : index / 10,
            rms: index / 20,
            low: index / 20,
            mid: index / 20,
            high: index / 20,
          ),
      ],
    );

    final expanded = source.sliced(
      sourceStartMs: 200,
      sourceEndMs: 600,
      targetSampleCount: 128,
    );
    final downsampled = source.sliced(
      sourceStartMs: 200,
      sourceEndMs: 600,
      targetSampleCount: 2,
    );

    expect(expanded.frames, hasLength(4));
    expect(expanded.coveredSourceFrameCount, 4);
    expect(expanded.frames.map((frame) => frame.peak), [0.2, 1, 0.4, 0.5]);
    expect(downsampled.frames, hasLength(2));
    expect(downsampled.frames.map((frame) => frame.peak), [1, 0.5]);
    expect(
      TimelineWaveformData.fromPeaks(
        const [0.1, 1],
        durationMs: 1000,
        targetSampleCount: 64,
        analyzed: true,
      ).frames,
      hasLength(2),
    );
  });

  test('sliced analyzer markers keep full-track thinning phase at trim 4px',
      () {
    final source = TimelineWaveformData(
      durationMs: 1000,
      analyzed: true,
      frames: List<WaveformFrame>.filled(
        80,
        const WaveformFrame(
          peak: 0.5,
          rms: 0.3,
          low: 0.2,
          mid: 0.4,
          high: 0.6,
        ),
      ),
      beatsMs: List<int>.generate(101, (index) => index * 10),
    );
    final sliced = source.sliced(
      sourceStartMs: 40,
      sourceEndMs: 1000,
      targetSampleCount: 80,
    );
    final fullClip = MixClip(
      placement: TimelineClip.clamped(
        id: 'full-phase',
        trackId: 'phase',
        sourceDurationMs: 1000,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        timelineStartMs: 0,
      ),
    );
    final trimmedClip = MixClip(
      placement: TimelineClip.clamped(
        id: 'trimmed-phase',
        trackId: 'phase',
        sourceDurationMs: 1000,
        sourceStartMs: 40,
        sourceEndMs: 1000,
        timelineStartMs: 40,
      ),
    );

    List<double> globalXs(
      TimelineWaveformData waveform,
      MixClip clip,
      double pixelsPerMs,
    ) =>
        timelineWaveformMarkerXs(
          localMarkersMs: waveform.beatsMs,
          mixClip: clip,
          sourceDurationMs: waveform.durationMs,
          width: waveform.durationMs * pixelsPerMs,
          viewportPixelsPerMs: pixelsPerMs,
          viewportOriginMs: 0,
          visibleSourceStartMs: 0,
          visibleSourceEndMs: waveform.durationMs,
          visibleStartFraction: 0,
          visibleEndFraction: 1,
          minSpacingPx: 7,
        )
            .map((x) => x + clip.timelineStartMs * pixelsPerMs)
            .toList(growable: false);

    final full = globalXs(source, fullClip, 0.1).where((x) => x >= 4).toList();
    final trimmed = globalXs(sliced, trimmedClip, 0.1);
    expect(trimmed, orderedEquals(full));
    for (var index = 0; index < full.length; index++) {
      expect((trimmed[index] - full[index]).abs() * 3, lessThanOrEqualTo(1));
    }

    final maxUsefulPixelsPerMs = waveformMaxUsefulPixelsPerSecond(
          realFrameCount: 80,
          timelineDurationMs: 1000,
        ) /
        1000;
    expect(maxUsefulPixelsPerMs, 0.4);
    final fullAtMax = globalXs(source, fullClip, maxUsefulPixelsPerMs)
        .where((x) => x >= 16)
        .toList();
    final trimmedAtMax = globalXs(
      sliced,
      trimmedClip,
      maxUsefulPixelsPerMs,
    );
    expect(trimmedAtMax, orderedEquals(fullAtMax));
    for (var index = 0; index < fullAtMax.length; index++) {
      expect(
        (trimmedAtMax[index] - fullAtMax[index]).abs() * 3,
        lessThanOrEqualTo(1),
      );
    }
  });
}

MixClip _rampedClip({
  required String id,
  required int sourceDurationMs,
  required int sourceStartMs,
  required int sourceEndMs,
  required int timelineStartMs,
  required int rampStartMs,
  required int rampEndMs,
  required double startRate,
  required double endRate,
}) =>
    MixClip(
      placement: TimelineClip.clamped(
        id: id,
        trackId: id,
        sourceDurationMs: sourceDurationMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        timelineStartMs: timelineStartMs,
      ),
      rateAutomation: PlaybackRateAutomation(
        segments: [
          PlaybackRateSegment(
            startMs: rampStartMs,
            endMs: rampEndMs,
            startRate: startRate,
            endRate: endRate,
          ),
        ],
      ),
    );

Track _track() => Track(
      id: 'dense-painter-track',
      title: 'Dense Painter Track',
      artist: 'Artist',
      duration: 240,
      addedAt: DateTime.utc(2026, 1, 1),
    );

List<int> _localMarkersForMixAnchors(MixClip clip, List<int> anchorsMs) => [
      for (final anchorMs in anchorsMs)
        clip.sourcePositionAt(anchorMs) - clip.placement.sourceStartMs,
    ];

List<double> _spacingMarkerXs(
  List<int> markers, {
  int visibleSourceStartMs = 0,
  int originMs = 1000,
}) {
  const viewportPixelsPerMs = 0.1;
  const width = 120.0;
  final clip = MixClip(
    placement: TimelineClip.clamped(
      id: 'spacing',
      trackId: 'spacing',
      sourceDurationMs: 1000,
      sourceStartMs: 0,
      sourceEndMs: 1000,
      timelineStartMs: 1000,
    ),
  );
  return timelineWaveformMarkerXs(
    localMarkersMs: markers,
    mixClip: clip,
    sourceDurationMs: clip.selectedDurationMs,
    width: width,
    viewportPixelsPerMs: viewportPixelsPerMs,
    viewportOriginMs: originMs,
    visibleSourceStartMs: visibleSourceStartMs,
    visibleSourceEndMs: clip.selectedDurationMs,
    visibleStartFraction: visibleSourceStartMs * viewportPixelsPerMs / width,
    visibleEndFraction: clip.selectedDurationMs * viewportPixelsPerMs / width,
    minSpacingPx: 7,
  );
}
