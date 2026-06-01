import 'dart:math' as math;

/// Timing-only viewport contract for a horizontal arranger timeline.
///
/// Converts between timeline milliseconds and screen pixels using an immutable
/// scale (`pixelsPerSecond`) plus horizontal scroll offset (`offsetMs`). Pan and
/// zoom helpers clamp to the available timeline duration so UI code can stay
/// pointer/gesture focused later.
class TimelineViewport {
  final int durationMs;
  final double widthPx;
  final double pixelsPerSecond;
  final int offsetMs;

  static const double minPixelsPerSecond = 1;
  static const double maxPixelsPerSecond = 400;

  const TimelineViewport._({
    required this.durationMs,
    required this.widthPx,
    required this.pixelsPerSecond,
    required this.offsetMs,
  });

  factory TimelineViewport.clamped({
    required int durationMs,
    required double widthPx,
    required double pixelsPerSecond,
    required int offsetMs,
  }) {
    final duration = math.max(0, durationMs);
    final width = widthPx.isFinite ? math.max(0, widthPx).toDouble() : 0.0;
    final scale = pixelsPerSecond
        .clamp(
          minPixelsPerSecond,
          maxPixelsPerSecond,
        )
        .toDouble();
    final visibleMs = _visibleDurationMs(width, scale);
    final maxOffset = math.max(0, duration - visibleMs);

    return TimelineViewport._(
      durationMs: duration,
      widthPx: width,
      pixelsPerSecond: scale,
      offsetMs: offsetMs.clamp(0, maxOffset),
    );
  }

  int get visibleDurationMs => _visibleDurationMs(widthPx, pixelsPerSecond);

  int get maxOffsetMs => math.max(0, durationMs - visibleDurationMs);

  double msToX(int timelineMs) =>
      ((timelineMs - offsetMs) / 1000) * pixelsPerSecond;

  int xToMs(double xPx) => offsetMs + ((xPx / pixelsPerSecond) * 1000).round();

  TimelineViewport panToOffsetMs(int ms) => TimelineViewport.clamped(
        durationMs: durationMs,
        widthPx: widthPx,
        pixelsPerSecond: pixelsPerSecond,
        offsetMs: ms,
      );

  TimelineViewport panByPixels(double deltaXPx) =>
      panToOffsetMs(offsetMs + ((deltaXPx / pixelsPerSecond) * 1000).round());

  TimelineViewport zoomAround({
    required double newPixelsPerSecond,
    required double focalXPx,
  }) {
    final scale = newPixelsPerSecond
        .clamp(
          minPixelsPerSecond,
          maxPixelsPerSecond,
        )
        .toDouble();
    final focalX = focalXPx.isFinite ? focalXPx : widthPx / 2;
    final focalTimelineMs = xToMs(focalX);
    final newOffset = focalTimelineMs - ((focalX / scale) * 1000).round();

    return TimelineViewport.clamped(
      durationMs: durationMs,
      widthPx: widthPx,
      pixelsPerSecond: scale,
      offsetMs: newOffset,
    );
  }

  static int _visibleDurationMs(double widthPx, double pixelsPerSecond) =>
      pixelsPerSecond <= 0 ? 0 : ((widthPx / pixelsPerSecond) * 1000).round();

  @override
  bool operator ==(Object other) =>
      other is TimelineViewport &&
      other.durationMs == durationMs &&
      other.widthPx == widthPx &&
      other.pixelsPerSecond == pixelsPerSecond &&
      other.offsetMs == offsetMs;

  @override
  int get hashCode => Object.hash(
        durationMs,
        widthPx,
        pixelsPerSecond,
        offsetMs,
      );
}
