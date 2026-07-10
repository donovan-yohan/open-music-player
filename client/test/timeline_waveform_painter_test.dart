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
  double visibleStartFraction = 0,
  double visibleEndFraction = 1,
}) =>
    TimelineWaveformPainter(
      peaks: peaks,
      waveform: waveform,
      mixClip: mixClip,
      mappingRevision: mappingRevision,
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
    });
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
