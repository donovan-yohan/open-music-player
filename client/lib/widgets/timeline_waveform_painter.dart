import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/engine/timeline_model.dart';
import '../models/waveform.dart';

class _TimelineMarkerCandidate {
  final int markerMs;
  final double localX;
  final double globalX;
  final int bucket;
  final double distanceToCenter;

  const _TimelineMarkerCandidate({
    required this.markerMs,
    required this.localX,
    required this.globalX,
    required this.bucket,
    required this.distanceToCenter,
  });
}

class _TimelineFramePaintGeometry {
  final double peak;
  final double rms;
  final Color coreColor;
  final Color haloColor;
  final Color rmsColor;

  const _TimelineFramePaintGeometry({
    required this.peak,
    required this.rms,
    required this.coreColor,
    required this.haloColor,
    required this.rmsColor,
  });
}

class _TimelineMarkerPaintGeometry {
  final List<double> beats;
  final List<double> downbeats;
  final List<double> transients;

  const _TimelineMarkerPaintGeometry({
    this.beats = const [],
    this.downbeats = const [],
    this.transients = const [],
  });

  int get estimatedByteSize =>
      (beats.length + downbeats.length + transients.length) * 8 + 128;
}

class _TimelineMarkerCacheKey {
  final TimelineWaveformData waveform;
  final String laneIdentity;
  final int timelineStartMs;
  final int sourceStartMs;
  final int sourceEndMs;
  final Object? mappingRevision;
  final int widthMicropixels;
  final int pixelsPerMsMicros;

  const _TimelineMarkerCacheKey({
    required this.waveform,
    required this.laneIdentity,
    required this.timelineStartMs,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.mappingRevision,
    required this.widthMicropixels,
    required this.pixelsPerMsMicros,
  });

  @override
  bool operator ==(Object other) =>
      other is _TimelineMarkerCacheKey &&
      identical(other.waveform, waveform) &&
      other.laneIdentity == laneIdentity &&
      other.timelineStartMs == timelineStartMs &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceEndMs == sourceEndMs &&
      other.mappingRevision == mappingRevision &&
      other.widthMicropixels == widthMicropixels &&
      other.pixelsPerMsMicros == pixelsPerMsMicros;

  @override
  int get hashCode => Object.hash(
        identityHashCode(waveform),
        laneIdentity,
        timelineStartMs,
        sourceStartMs,
        sourceEndMs,
        mappingRevision,
        widthMicropixels,
        pixelsPerMsMicros,
      );
}

/// Retains expensive waveform geometry across viewport-only rebuilds.
class TimelineWaveformPaintCache {
  static const int _maxCachedFrameGeometry = 8192;
  static const int _estimatedFrameGeometryBytes = 96;
  static const int _maxCachedFrameGeometryBytes =
      _maxCachedFrameGeometry * _estimatedFrameGeometryBytes;

  List<double>? _framePeaks;
  TimelineWaveformData? _frameWaveform;
  final LinkedHashMap<int, _TimelineFramePaintGeometry> _frames =
      LinkedHashMap();
  static const int _maxMarkerLanes = 16;
  static const int _maxMarkerGeometryBytes = 256 * 1024;
  static const int maxRetainedByteSize =
      _maxCachedFrameGeometryBytes + _maxMarkerGeometryBytes + 256;
  static const int minimumRetainedByteSize = 256;
  final LinkedHashMap<_TimelineMarkerCacheKey, _TimelineMarkerPaintGeometry>
      _markersByLane = LinkedHashMap();
  final VoidCallback? onSizeChanged;

  int _frameGeometryBuildCount = 0;
  int _frameGeometryMissCount = 0;
  int _markerGeometryBuildCount = 0;
  int _paintCount = 0;
  int _geometryTrimCount = 0;
  int _trimmedGeometryByteCount = 0;

  TimelineWaveformPaintCache({this.onSizeChanged});

  @visibleForTesting
  int get frameGeometryBuildCount => _frameGeometryBuildCount;

  @visibleForTesting
  int get frameGeometryMissCount => _frameGeometryMissCount;

  @visibleForTesting
  int get frameGeometryEntryCount => _frames.length;

  @visibleForTesting
  int get markerGeometryBuildCount => _markerGeometryBuildCount;

  @visibleForTesting
  int get paintCount => _paintCount;

  @visibleForTesting
  int get geometryTrimCount => _geometryTrimCount;

  @visibleForTesting
  int get trimmedGeometryByteCount => _trimmedGeometryByteCount;

  static int maxRetainedByteSizeForFrameCount(int frameCount) =>
      frameCount.clamp(0, _maxCachedFrameGeometry).toInt() *
          _estimatedFrameGeometryBytes +
      _maxMarkerGeometryBytes +
      minimumRetainedByteSize;

  int get estimatedByteSize =>
      _frames.length * _estimatedFrameGeometryBytes +
      _markersByLane.values.fold<int>(
        0,
        (total, value) => total + value.estimatedByteSize,
      ) +
      256;

  void _notifySizeChanged(int previousByteSize) {
    if (estimatedByteSize != previousByteSize) onSizeChanged?.call();
  }

  int trimRetainedGeometryToBytes(int maxBytes) {
    final target = math.max(minimumRetainedByteSize, maxBytes);
    final before = estimatedByteSize;
    var retainedBytes = before;
    while (_markersByLane.isNotEmpty && retainedBytes > target) {
      final removed = _markersByLane.remove(_markersByLane.keys.first)!;
      retainedBytes -= removed.estimatedByteSize;
    }
    while (_frames.isNotEmpty && retainedBytes > target) {
      _frames.remove(_frames.keys.first);
      retainedBytes -= _estimatedFrameGeometryBytes;
    }
    final freed = before - retainedBytes;
    if (freed > 0) {
      _geometryTrimCount++;
      _trimmedGeometryByteCount += freed;
    }
    return freed;
  }

  int clearRetainedGeometry() =>
      trimRetainedGeometryToBytes(minimumRetainedByteSize);

  int _prepareFrameGeometry({
    required List<double> peaks,
    required TimelineWaveformData? waveform,
  }) {
    final hasRichFrames = waveform?.frames.isNotEmpty ?? false;
    if (identical(_frameWaveform, waveform) &&
        (hasRichFrames || identical(_framePeaks, peaks))) {
      return hasRichFrames ? waveform!.frames.length : peaks.length;
    }
    _frames.clear();
    _framePeaks = peaks;
    _frameWaveform = waveform;
    _frameGeometryBuildCount++;
    return hasRichFrames ? waveform!.frames.length : peaks.length;
  }

  _TimelineFramePaintGeometry _frameGeometryAt(int index) {
    final cached = _frames.remove(index);
    if (cached != null) {
      _frames[index] = cached;
      return cached;
    }
    final richFrames = _frameWaveform?.frames;
    final frame =
        richFrames != null && richFrames.isNotEmpty ? richFrames[index] : null;
    final peak = frame?.peak ?? _framePeaks![index];
    final rms = frame?.rms ?? peak * 0.68;
    final low = frame?.low ?? 0.48;
    final mid = frame?.mid ?? 0.52;
    final high = frame?.high ?? 0.24;
    final geometry = _TimelineFramePaintGeometry(
      peak: peak,
      rms: rms,
      coreColor: _eqColorForValues(
        peak: peak,
        rms: rms,
        low: low,
        mid: mid,
        high: high,
      ),
      haloColor: _eqColorForValues(
        peak: peak,
        rms: rms,
        low: low,
        mid: mid,
        high: high,
        brighten: 0.04,
      ),
      rmsColor: _eqColorForValues(
        peak: peak,
        rms: rms,
        low: low,
        mid: mid,
        high: high,
        brighten: 0.08,
      ),
    );
    _frameGeometryMissCount++;
    while (_frames.length >= _maxCachedFrameGeometry ||
        (_frames.length + 1) * _estimatedFrameGeometryBytes >
            _maxCachedFrameGeometryBytes) {
      _frames.remove(_frames.keys.first);
    }
    _frames[index] = geometry;
    return geometry;
  }

  _TimelineMarkerPaintGeometry _markerGeometryFor({
    required TimelineWaveformData waveform,
    required MixClip? mixClip,
    required Object? mappingRevision,
    required String? laneIdentity,
    required double width,
    required double viewportPixelsPerMs,
    required int viewportOriginMs,
  }) {
    final placement = mixClip?.placement;
    final explicitLaneIdentity = laneIdentity;
    final clipQueueItemId = mixClip?.queueItemId;
    final cacheKey = _TimelineMarkerCacheKey(
      waveform: waveform,
      laneIdentity:
          explicitLaneIdentity != null && explicitLaneIdentity.isNotEmpty
              ? explicitLaneIdentity
              : clipQueueItemId != null && clipQueueItemId.isNotEmpty
                  ? clipQueueItemId
                  : mixClip?.id ?? 'unplaced',
      timelineStartMs: mixClip?.timelineStartMs ?? 0,
      sourceStartMs: placement?.sourceStartMs ?? 0,
      sourceEndMs: placement?.sourceEndMs ?? waveform.durationMs,
      mappingRevision: mappingRevision,
      widthMicropixels: (width * 1000000).round(),
      pixelsPerMsMicros: (viewportPixelsPerMs * 1000000).round(),
    );
    final cached = _markersByLane.remove(cacheKey);
    if (cached != null) {
      _markersByLane[cacheKey] = cached;
      return cached;
    }

    List<double> select(List<int> markers, double spacingPx) =>
        timelineWaveformMarkerXs(
          localMarkersMs: markers,
          mixClip: mixClip,
          sourceDurationMs: waveform.durationMs,
          width: width,
          visibleSourceStartMs: 0,
          visibleSourceEndMs: waveform.durationMs,
          visibleStartFraction: 0,
          visibleEndFraction: 1,
          minSpacingPx: spacingPx,
          viewportPixelsPerMs: viewportPixelsPerMs,
          viewportOriginMs: viewportOriginMs,
        );

    final markers = _TimelineMarkerPaintGeometry(
      beats: select(waveform.beatsMs, 7),
      downbeats: select(waveform.downbeatsMs, 14),
      transients: select(waveform.transientsMs, 10),
    );
    var cachedMarkerBytes = _markersByLane.values.fold<int>(
      0,
      (total, value) => total + value.estimatedByteSize,
    );
    while (_markersByLane.isNotEmpty &&
        (_markersByLane.length >= _maxMarkerLanes ||
            cachedMarkerBytes + markers.estimatedByteSize >
                _maxMarkerGeometryBytes)) {
      final removed = _markersByLane.remove(_markersByLane.keys.first)!;
      cachedMarkerBytes -= removed.estimatedByteSize;
    }
    if (markers.estimatedByteSize <= _maxMarkerGeometryBytes) {
      _markersByLane[cacheKey] = markers;
    }
    _markerGeometryBuildCount++;
    return markers;
  }
}

Color _eqColorForValues({
  required double peak,
  required double rms,
  required double low,
  required double mid,
  required double high,
  double brighten = 0.0,
}) {
  final normalizedLow = low.clamp(0.0, 1.0).toDouble();
  final normalizedMid = mid.clamp(0.0, 1.0).toDouble();
  final normalizedHigh = high.clamp(0.0, 1.0).toDouble();
  final loudness = (peak * 0.68 + rms * 0.32).clamp(0.0, 1.0).toDouble();
  final maxEnergy = math.max(
    0.08,
    math.max(normalizedLow, math.max(normalizedMid, normalizedHigh)),
  );
  final gain = 0.42 + loudness * 0.66;
  final whiteLift =
      math.min(normalizedLow, math.min(normalizedMid, normalizedHigh)) * 0.10 +
          brighten;
  final red = (math.pow(normalizedLow / maxEnergy, 0.62) * gain + whiteLift)
      .clamp(0.0, 1.0);
  final green = (math.pow(normalizedMid / maxEnergy, 0.62) * gain + whiteLift)
      .clamp(0.0, 1.0);
  final blue = (math.pow(normalizedHigh / maxEnergy, 0.62) * gain + whiteLift)
      .clamp(0.0, 1.0);

  return Color.fromARGB(
    255,
    (red * 255).round(),
    (green * 255).round(),
    (blue * 255).round(),
  );
}

Color _withAlpha(Color color, double alpha) =>
    color.withAlpha((alpha.clamp(0.0, 1.0) * 255).round());

/// Converts an absolute source position into the local x coordinate of a
/// rate-adjusted timeline clip.
///
/// This deliberately delegates to [MixClip.timelineMsForSourcePosition], the
/// same source-to-mix-time mapping used by playback. Callers pass a clip-local
/// waveform, so source zero is [MixClip.placement.sourceStartMs].
@visibleForTesting
double timelineWaveformXForSourcePosition({
  required MixClip mixClip,
  required int sourcePositionMs,
  required double width,
  double viewportPixelsPerMs = 0,
}) {
  if (!width.isFinite || width <= 0 || mixClip.timelineDurationMs <= 0) {
    return 0;
  }
  final sourceMs = sourcePositionMs
      .clamp(
        mixClip.placement.sourceStartMs,
        mixClip.placement.sourceEndMs,
      )
      .toInt();
  final timelineMs = mixClip.timelineMsForSourcePosition(sourceMs);
  final pixelsPerMs = _resolvedPixelsPerMs(
    mixClip: mixClip,
    width: width,
    viewportPixelsPerMs: viewportPixelsPerMs,
  );
  return ((timelineMs - mixClip.timelineStartMs) * pixelsPerMs)
      .clamp(0.0, width)
      .toDouble();
}

/// Returns the frame interval that can contribute to a visible timeline slice.
///
/// With a [mixClip], visibility is first converted back to source time, then
/// into waveform frames. That avoids walking dense, off-screen source samples
/// for a zoomed rate-adjusted clip.
@visibleForTesting
({int start, int end}) timelineWaveformVisibleFrameRange({
  required MixClip? mixClip,
  required int frameCount,
  required int sourceDurationMs,
  required double visibleStartFraction,
  required double visibleEndFraction,
  int padding = 4,
}) {
  if (frameCount <= 0) return (start: 0, end: 0);
  final startFraction = visibleStartFraction.clamp(0.0, 1.0).toDouble();
  final endFraction = visibleEndFraction.clamp(startFraction, 1.0).toDouble();

  double sourceStartFraction = startFraction;
  double sourceEndFraction = endFraction;
  if (mixClip != null && sourceDurationMs > 0) {
    final sourceStartMs = _localSourcePositionForTimelineFraction(
      mixClip,
      startFraction,
      sourceDurationMs,
    );
    final sourceEndMs = _localSourcePositionForTimelineFraction(
      mixClip,
      endFraction,
      sourceDurationMs,
    );
    sourceStartFraction = sourceStartMs / sourceDurationMs;
    sourceEndFraction = sourceEndMs / sourceDurationMs;
  }

  final start = ((sourceStartFraction * frameCount).floor() - padding)
      .clamp(0, frameCount)
      .toInt();
  final end = ((sourceEndFraction * frameCount).ceil() + padding)
      .clamp(start, frameCount)
      .toInt();
  return (start: start, end: end);
}

/// Resolves sliced, clip-local marker times to the x coordinates paint uses.
///
/// [TimelineWaveformData.sliced] normalizes markers to the selected source
/// range. A mapped clip therefore restores [TimelineClip.sourceStartMs]
/// exactly once before applying its rate schedule. Visibility and density
/// culling live here as well so tests exercise the same path as rendering.
///
/// Density buckets are anchored in mix time, rather than at the first visible
/// marker in a lane. That makes overlapping clips select the same phase bucket
/// even when their trims or visible ranges differ.
@visibleForTesting
List<double> timelineWaveformMarkerXs({
  required List<int> localMarkersMs,
  required MixClip? mixClip,
  required int sourceDurationMs,
  required double width,
  required int visibleSourceStartMs,
  required int visibleSourceEndMs,
  required double visibleStartFraction,
  required double visibleEndFraction,
  required double minSpacingPx,
  double viewportPixelsPerMs = 0,
  int viewportOriginMs = 0,
}) {
  if (localMarkersMs.isEmpty ||
      sourceDurationMs <= 0 ||
      !width.isFinite ||
      width <= 0) {
    return const [];
  }
  final visibleStartX = visibleStartFraction.clamp(0.0, 1.0).toDouble() * width;
  final visibleEndX = visibleEndFraction
          .clamp(visibleStartFraction.clamp(0.0, 1.0), 1.0)
          .toDouble() *
      width;
  final spacingPx = math.max(1.0, minSpacingPx);
  final pixelsPerMs = _resolvedPixelsPerMs(
    mixClip: mixClip,
    width: width,
    viewportPixelsPerMs: viewportPixelsPerMs,
  );
  // viewportOriginMs is deliberately excluded from bucket coordinates. It is
  // part of the shared viewport contract, but pan must not rephase density.
  final selectedByBucket = <int, _TimelineMarkerCandidate>{};
  for (final markerMs in localMarkersMs) {
    final x = _timelineWaveformXForLocalSourcePosition(
      mixClip: mixClip,
      localSourceMs: markerMs,
      sourceDurationMs: sourceDurationMs,
      width: width,
      viewportPixelsPerMs: viewportPixelsPerMs,
    );
    final globalX = (mixClip?.timelineStartMs ?? 0) * pixelsPerMs + x;
    final bucket = (globalX / spacingPx).floor();
    final bucketCenter = (bucket + 0.5) * spacingPx;
    final distanceToCenter = (globalX - bucketCenter).abs();
    final previous = selectedByBucket[bucket];
    if (previous == null ||
        distanceToCenter < previous.distanceToCenter ||
        (distanceToCenter == previous.distanceToCenter &&
            globalX < previous.globalX)) {
      selectedByBucket[bucket] = _TimelineMarkerCandidate(
        markerMs: markerMs,
        localX: x,
        globalX: globalX,
        bucket: bucket,
        distanceToCenter: distanceToCenter,
      );
    }
  }
  final candidates = selectedByBucket.values.toList()
    ..sort((a, b) {
      final byDistance = a.distanceToCenter.compareTo(b.distanceToCenter);
      if (byDistance != 0) return byDistance;
      final byBucket = a.bucket.compareTo(b.bucket);
      if (byBucket != 0) return byBucket;
      return a.globalX.compareTo(b.globalX);
    });
  final selected = SplayTreeMap<double, _TimelineMarkerCandidate>();
  for (final candidate in candidates) {
    if (selected.containsKey(candidate.globalX)) continue;
    final previousKey = selected.lastKeyBefore(candidate.globalX);
    final nextKey = selected.firstKeyAfter(candidate.globalX);
    final previous = previousKey == null ? null : selected[previousKey];
    final next = nextKey == null ? null : selected[nextKey];
    if ((previous != null &&
            candidate.globalX - previous.globalX < spacingPx) ||
        (next != null && next.globalX - candidate.globalX < spacingPx)) {
      continue;
    }
    selected[candidate.globalX] = candidate;
  }
  return [
    for (final candidate in selected.values)
      if (candidate.markerMs >= visibleSourceStartMs &&
          candidate.markerMs <= visibleSourceEndMs &&
          candidate.localX >= visibleStartX &&
          candidate.localX <= visibleEndX)
        candidate.localX,
  ];
}

double _resolvedPixelsPerMs({
  required MixClip? mixClip,
  required double width,
  required double viewportPixelsPerMs,
}) {
  if (viewportPixelsPerMs.isFinite && viewportPixelsPerMs > 0) {
    return viewportPixelsPerMs;
  }
  if (mixClip == null || mixClip.timelineDurationMs <= 0) return 0;
  return width / mixClip.timelineDurationMs;
}

double _timelineWaveformXForLocalSourcePosition({
  required MixClip? mixClip,
  required int localSourceMs,
  required int sourceDurationMs,
  required double width,
  double viewportPixelsPerMs = 0,
}) {
  if (mixClip == null) {
    if (sourceDurationMs <= 0) return 0;
    return (localSourceMs / sourceDurationMs) * width;
  }
  if (localSourceMs < 0) {
    final boundaryRate = mixClip.playbackRateAt(mixClip.timelineStartMs);
    return localSourceMs /
        boundaryRate *
        _resolvedPixelsPerMs(
          mixClip: mixClip,
          width: width,
          viewportPixelsPerMs: viewportPixelsPerMs,
        );
  }
  if (localSourceMs > sourceDurationMs) {
    final boundaryRate = mixClip.playbackRateAt(mixClip.timelineEndMs);
    return width +
        (localSourceMs - sourceDurationMs) /
            boundaryRate *
            _resolvedPixelsPerMs(
              mixClip: mixClip,
              width: width,
              viewportPixelsPerMs: viewportPixelsPerMs,
            );
  }
  return timelineWaveformXForSourcePosition(
    mixClip: mixClip,
    sourcePositionMs: mixClip.placement.sourceStartMs + localSourceMs,
    width: width,
    viewportPixelsPerMs: viewportPixelsPerMs,
  );
}

int _localSourcePositionForTimelineFraction(
  MixClip mixClip,
  double timelineFraction,
  int sourceDurationMs,
) {
  if (sourceDurationMs <= 0 || mixClip.timelineDurationMs <= 0) return 0;
  final timelineMs = mixClip.timelineStartMs +
      (mixClip.timelineDurationMs * timelineFraction).round();
  return (mixClip.sourcePositionAt(timelineMs) -
          mixClip.placement.sourceStartMs)
      .clamp(0, sourceDurationMs)
      .toInt();
}

/// Paints a compact, transient-preserving waveform for a single timeline clip.
///
/// When rich analysis is available, each vertical slice is an RGB/EQ blend:
/// low energy contributes red, mid contributes green, and high contributes blue.
/// Overlaps naturally read as yellow, cyan, violet, pink, and white.
/// Beat, downbeat, transient, and silence metadata sit on top of the waveform
/// and are density-thinned so dense zoom levels stay readable.
class TimelineWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final TimelineWaveformData? waveform;
  final MixClip? mixClip;
  final Object? mappingRevision;
  final String? laneIdentity;
  final TimelineWaveformPaintCache paintCache;
  final double viewportPixelsPerMs;
  final int viewportOriginMs;
  final double visibleStartFraction;
  final double visibleEndFraction;
  final Color color;
  final Color dimColor;
  final Color handleColor;
  final Color? snapMarkerColor;
  final double trimStartFraction;
  final double trimEndFraction;
  final int snapMarkerCount;

  TimelineWaveformPainter({
    required this.peaks,
    this.waveform,
    this.mixClip,
    this.mappingRevision,
    this.laneIdentity,
    TimelineWaveformPaintCache? paintCache,
    required this.viewportPixelsPerMs,
    required this.viewportOriginMs,
    this.visibleStartFraction = 0,
    this.visibleEndFraction = 1,
    required this.color,
    required this.dimColor,
    required this.handleColor,
    this.snapMarkerColor,
    this.trimStartFraction = 0.0,
    this.trimEndFraction = 1.0,
    this.snapMarkerCount = 0,
  }) : paintCache = paintCache ?? TimelineWaveformPaintCache();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final startFraction = visibleStartFraction.clamp(0.0, 1.0).toDouble();
    final endFraction = visibleEndFraction.clamp(startFraction, 1.0).toDouble();
    if (endFraction <= startFraction) return;

    final cacheByteSizeBeforePaint = paintCache.estimatedByteSize;
    paintCache._paintCount++;
    final richWaveform = waveform;
    final frameCount = paintCache._prepareFrameGeometry(
      peaks: peaks,
      waveform: richWaveform,
    );
    if (frameCount == 0) {
      paintCache._notifySizeChanged(cacheByteSizeBeforePaint);
      return;
    }

    final sourceDurationMs =
        richWaveform?.durationMs ?? mixClip?.selectedDurationMs ?? frameCount;
    final safeSourceDurationMs = sourceDurationMs < 0 ? 0 : sourceDurationMs;
    final frameRange = timelineWaveformVisibleFrameRange(
      mixClip: mixClip,
      frameCount: frameCount,
      sourceDurationMs: safeSourceDurationMs,
      visibleStartFraction: startFraction,
      visibleEndFraction: endFraction,
    );
    final visibleSourceStartMs = mixClip == null
        ? (safeSourceDurationMs * startFraction).round()
        : _localSourcePositionForTimelineFraction(
            mixClip!,
            startFraction,
            safeSourceDurationMs,
          );
    final visibleSourceEndMs = mixClip == null
        ? (safeSourceDurationMs * endFraction).round()
        : _localSourcePositionForTimelineFraction(
            mixClip!,
            endFraction,
            safeSourceDurationMs,
          );

    if (richWaveform != null) {
      _paintSilenceRanges(
        canvas,
        size,
        richWaveform,
        sourceDurationMs: safeSourceDurationMs,
        visibleSourceStartMs: visibleSourceStartMs,
        visibleSourceEndMs: visibleSourceEndMs,
      );
      _paintMusicalMarkers(
        canvas,
        size,
        paintCache._markerGeometryFor(
          waveform: richWaveform,
          mixClip: mixClip,
          mappingRevision: mappingRevision,
          laneIdentity: laneIdentity,
          width: size.width,
          viewportPixelsPerMs: viewportPixelsPerMs,
          viewportOriginMs: viewportOriginMs,
        ),
        visibleStartFraction: startFraction,
        visibleEndFraction: endFraction,
      );
    }

    final midY = size.height / 2;
    final slot = size.width / frameCount;
    final strokeWidth = _sliceStrokeWidth(slot);
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.plus
      ..strokeWidth = (strokeWidth * 2.8).clamp(0.8, 4.8).toDouble();
    final corePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.srcOver
      ..strokeWidth = strokeWidth;
    final rmsPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.plus
      ..strokeWidth = (strokeWidth * 0.46).clamp(0.35, 1.1).toDouble();

    for (var i = frameRange.start; i < frameRange.end; i++) {
      final frame = paintCache._frameGeometryAt(i);
      final frac = (i + 0.5) / frameCount;
      final inTrim = frac >= trimStartFraction && frac <= trimEndFraction;
      final alpha = inTrim ? 1.0 : 0.34;
      final peak = frame.peak;
      final rms = frame.rms;
      final localSourceMs = safeSourceDurationMs <= 0
          ? 0
          : (((i + 0.5) * safeSourceDurationMs) / frameCount).round();
      final cx = _xForLocalSourcePosition(
        localSourceMs,
        safeSourceDurationMs,
        size.width,
      );
      final peakHeight = (peak.clamp(0.0, 1.0).toDouble()) * (size.height - 2);
      final rmsHeight = (rms.clamp(0.0, 1.0).toDouble()) * (size.height - 2);
      if (peakHeight <= 0) continue;

      glowPaint.color = _withAlpha(frame.haloColor, alpha * 0.16);
      canvas.drawLine(
        Offset(cx, midY - peakHeight / 2),
        Offset(cx, midY + peakHeight / 2),
        glowPaint,
      );

      corePaint.color = _withAlpha(frame.coreColor, alpha);
      canvas.drawLine(
        Offset(cx, midY - peakHeight / 2),
        Offset(cx, midY + peakHeight / 2),
        corePaint,
      );

      rmsPaint.color = _withAlpha(frame.rmsColor, alpha * 0.78);
      canvas.drawLine(
        Offset(cx, midY - rmsHeight / 2),
        Offset(cx, midY + rmsHeight / 2),
        rmsPaint,
      );
    }

    // Prototype snap notches remain separate from analyzed beat/downbeat ticks:
    // they show the active edit mode, while beat ticks show musical structure.
    if (snapMarkerCount > 0) {
      final marker = Paint()
        ..color = snapMarkerColor ?? handleColor.withValues(alpha: 0.48)
        ..strokeWidth = 1;
      for (var i = 1; i <= snapMarkerCount; i++) {
        final x = (i / (snapMarkerCount + 1)) * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, 6), marker);
        canvas.drawLine(
          Offset(x, size.height - 6),
          Offset(x, size.height),
          marker,
        );
      }
    }

    final handle = Paint()
      ..color = handleColor
      ..strokeWidth = 2;
    for (final frac in [trimStartFraction, trimEndFraction]) {
      final x = (frac.clamp(0.0, 1.0)) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), handle);
    }
    paintCache._notifySizeChanged(cacheByteSizeBeforePaint);
  }

  @override
  bool shouldRepaint(covariant TimelineWaveformPainter old) =>
      old.peaks != peaks ||
      old.waveform != waveform ||
      old.mixClip != mixClip ||
      old.mappingRevision != mappingRevision ||
      old.laneIdentity != laneIdentity ||
      old.viewportPixelsPerMs != viewportPixelsPerMs ||
      old.visibleStartFraction != visibleStartFraction ||
      old.visibleEndFraction != visibleEndFraction ||
      old.color != color ||
      old.dimColor != dimColor ||
      old.handleColor != handleColor ||
      old.snapMarkerColor != snapMarkerColor ||
      old.trimStartFraction != trimStartFraction ||
      old.trimEndFraction != trimEndFraction ||
      old.snapMarkerCount != snapMarkerCount;

  double _sliceStrokeWidth(double slot) {
    if (!slot.isFinite || slot <= 0) return 0.5;
    return (slot * 1.16).clamp(0.6, 5.0).toDouble();
  }

  void _paintSilenceRanges(
    Canvas canvas,
    Size size,
    TimelineWaveformData waveform, {
    required int sourceDurationMs,
    required int visibleSourceStartMs,
    required int visibleSourceEndMs,
  }) {
    if (sourceDurationMs <= 0 || waveform.silenceRanges.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = dimColor.withValues(alpha: 0.18);
    for (final range in waveform.silenceRanges) {
      final start = range.startMs.clamp(0, sourceDurationMs).toInt();
      final end = range.endMs.clamp(start, sourceDurationMs).toInt();
      if (end < visibleSourceStartMs || start > visibleSourceEndMs) continue;
      final visibleStart = math.max(start, visibleSourceStartMs).toInt();
      final visibleEnd = math.min(end, visibleSourceEndMs).toInt();
      final startX = _xForLocalSourcePosition(
        visibleStart,
        sourceDurationMs,
        size.width,
      );
      final endX = _xForLocalSourcePosition(
        visibleEnd,
        sourceDurationMs,
        size.width,
      );
      canvas.drawRect(
        Rect.fromLTRB(
          math.min(startX, endX),
          0,
          math.max(startX, endX),
          size.height,
        ),
        paint,
      );
    }
  }

  void _paintMusicalMarkers(
    Canvas canvas,
    Size size,
    _TimelineMarkerPaintGeometry markers, {
    required double visibleStartFraction,
    required double visibleEndFraction,
  }) {
    _paintTimeMarkers(
      canvas,
      size,
      markers.beats,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
      color: Colors.white.withValues(alpha: 0.08),
      strokeWidth: 0.6,
      top: size.height * 0.12,
      bottom: size.height * 0.88,
    );
    _paintTimeMarkers(
      canvas,
      size,
      markers.downbeats,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
      color: const Color(0xFFFFF176).withValues(alpha: 0.20),
      strokeWidth: 1,
      top: 0,
      bottom: size.height,
    );
    _paintTimeMarkers(
      canvas,
      size,
      markers.transients,
      visibleStartFraction: visibleStartFraction,
      visibleEndFraction: visibleEndFraction,
      color: const Color(0xFFE1F5FE).withValues(alpha: 0.16),
      strokeWidth: 0.8,
      top: size.height * 0.28,
      bottom: size.height * 0.72,
    );
  }

  void _paintTimeMarkers(
    Canvas canvas,
    Size size,
    List<double> markerXs, {
    required double visibleStartFraction,
    required double visibleEndFraction,
    required Color color,
    required double strokeWidth,
    required double top,
    required double bottom,
  }) {
    if (markerXs.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth;
    final visibleStartX =
        visibleStartFraction.clamp(0.0, 1.0).toDouble() * size.width;
    final visibleEndX = visibleEndFraction
            .clamp(visibleStartFraction.clamp(0.0, 1.0), 1.0)
            .toDouble() *
        size.width;
    final start = _lowerBound(markerXs, visibleStartX);
    final end = _upperBound(markerXs, visibleEndX);
    for (var index = start; index < end; index++) {
      final x = markerXs[index];
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
  }

  double _xForLocalSourcePosition(
    int localSourceMs,
    int sourceDurationMs,
    double width,
  ) {
    return _timelineWaveformXForLocalSourcePosition(
      mixClip: mixClip,
      localSourceMs: localSourceMs,
      sourceDurationMs: sourceDurationMs,
      width: width,
      viewportPixelsPerMs: viewportPixelsPerMs,
    );
  }
}

int _lowerBound(List<double> sortedValues, double target) {
  var low = 0;
  var high = sortedValues.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (sortedValues[middle] < target) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

int _upperBound(List<double> sortedValues, double target) {
  var low = 0;
  var high = sortedValues.length;
  while (low < high) {
    final middle = low + ((high - low) >> 1);
    if (sortedValues[middle] <= target) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}
