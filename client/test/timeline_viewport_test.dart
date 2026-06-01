import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/timeline_viewport.dart';

void main() {
  TimelineViewport viewport({
    int durationMs = 240000,
    double widthPx = 400,
    double pixelsPerSecond = 20,
    int offsetMs = 0,
  }) =>
      TimelineViewport.clamped(
        durationMs: durationMs,
        widthPx: widthPx,
        pixelsPerSecond: pixelsPerSecond,
        offsetMs: offsetMs,
      );

  group('scale and offset conversions', () {
    test('converts timeline milliseconds to screen x pixels', () {
      final v = viewport(pixelsPerSecond: 20, offsetMs: 10000);
      expect(v.msToX(10000), 0);
      expect(v.msToX(15000), 100);
    });

    test('converts screen x pixels to timeline milliseconds', () {
      final v = viewport(pixelsPerSecond: 20, offsetMs: 10000);
      expect(v.xToMs(0), 10000);
      expect(v.xToMs(100), 15000);
    });

    test('reports visible duration from width and scale', () {
      final v = viewport(widthPx: 400, pixelsPerSecond: 20);
      expect(v.visibleDurationMs, 20000);
    });
  });

  group('pan clamps', () {
    test('sanitizes non-finite widths to zero before clamping', () {
      for (final width in [
        double.nan,
        double.infinity,
        double.negativeInfinity
      ]) {
        final v = viewport(widthPx: width, offsetMs: 5000);
        expect(v.widthPx, 0);
        expect(v.visibleDurationMs, 0);
        expect(v.offsetMs, 5000);
      }
    });

    test('clamps offset below zero', () {
      final v = viewport(offsetMs: -5000);
      expect(v.offsetMs, 0);
    });

    test('clamps offset beyond max visible range', () {
      final v = viewport(
        durationMs: 60000,
        widthPx: 400,
        pixelsPerSecond: 20,
        offsetMs: 100000,
      );
      expect(v.offsetMs, 40000);
    });

    test('panByPixels moves through timeline time and clamps', () {
      final v = viewport(
        durationMs: 60000,
        widthPx: 400,
        pixelsPerSecond: 20,
        offsetMs: 10000,
      );
      expect(v.panByPixels(100).offsetMs, 15000);
      expect(v.panByPixels(-1000).offsetMs, 0);
    });

    test('content shorter than viewport forces zero offset', () {
      final v = viewport(
        durationMs: 10000,
        widthPx: 400,
        pixelsPerSecond: 20,
        offsetMs: 5000,
      );
      expect(v.visibleDurationMs, 20000);
      expect(v.maxOffsetMs, 0);
      expect(v.offsetMs, 0);
    });
  });

  group('zoom anchored around focal x', () {
    test('preserves the focal timeline millisecond when possible', () {
      final v = viewport(
        durationMs: 240000,
        widthPx: 400,
        pixelsPerSecond: 20,
        offsetMs: 10000,
      );
      final focalBefore = v.xToMs(200);
      final zoomed = v.zoomAround(
        newPixelsPerSecond: 40,
        focalXPx: 200,
      );
      expect(zoomed.pixelsPerSecond, 40);
      expect(zoomed.xToMs(200), focalBefore);
      expect(zoomed.offsetMs, 15000);
    });

    test('clamps anchored zoom when focal preservation would exceed bounds',
        () {
      final v = viewport(
        durationMs: 60000,
        widthPx: 400,
        pixelsPerSecond: 20,
        offsetMs: 40000,
      );
      final zoomed = v.zoomAround(
        newPixelsPerSecond: 5,
        focalXPx: 400,
      );
      expect(zoomed.maxOffsetMs, 0);
      expect(zoomed.offsetMs, 0);
    });

    test('clamps scale to configured limits', () {
      final v = viewport(pixelsPerSecond: 20);
      expect(v.zoomAround(newPixelsPerSecond: 0.1, focalXPx: 0).pixelsPerSecond,
          TimelineViewport.minPixelsPerSecond);
      expect(
          v.zoomAround(newPixelsPerSecond: 10000, focalXPx: 0).pixelsPerSecond,
          TimelineViewport.maxPixelsPerSecond);
    });

    test('uses viewport center when focal x is non-finite', () {
      final v = viewport(
        durationMs: 240000,
        widthPx: 400,
        pixelsPerSecond: 20,
        offsetMs: 10000,
      );
      final centerZoomed = v.zoomAround(
        newPixelsPerSecond: 40,
        focalXPx: 200,
      );

      for (final focal in [
        double.nan,
        double.infinity,
        double.negativeInfinity
      ]) {
        final zoomed = v.zoomAround(
          newPixelsPerSecond: 40,
          focalXPx: focal,
        );
        expect(zoomed, centerZoomed);
      }
    });
  });
}
