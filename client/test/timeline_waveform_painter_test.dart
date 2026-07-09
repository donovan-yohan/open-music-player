import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

TimelineWaveformPainter _painter(
  List<double> peaks, {
  int snapMarkerCount = 0,
  TimelineWaveformData? waveform,
  double visibleStartFraction = 0,
  double visibleEndFraction = 1,
}) =>
    TimelineWaveformPainter(
      peaks: peaks,
      waveform: waveform,
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
  });
}

Track _track() => Track(
      id: 'dense-painter-track',
      title: 'Dense Painter Track',
      artist: 'Artist',
      duration: 240,
      addedAt: DateTime.utc(2026, 1, 1),
    );
