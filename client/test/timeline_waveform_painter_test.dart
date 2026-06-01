import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

TimelineWaveformPainter _painter(List<double> peaks) => TimelineWaveformPainter(
      peaks: peaks,
      color: const Color(0xFF2E7D32),
      dimColor: const Color(0xFF90A4AE),
      handleColor: const Color(0xFFFFFFFF),
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
  });
}
