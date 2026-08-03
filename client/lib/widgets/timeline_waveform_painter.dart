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
  final double minPeak;
  final double maxPeak;
  final Color? coreColor;

  const _TimelineFramePaintGeometry({
    required this.minPeak,
    required this.maxPeak,
    required this.coreColor,
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
    final minPeak = frame?.resolvedMinPeak ?? -peak;
    final maxPeak = frame?.resolvedMaxPeak ?? peak;
    final channels = frame?.resolvedChannels ?? const <String, double>{};
    final geometry = _TimelineFramePaintGeometry(
      minPeak: minPeak,
      maxPeak: maxPeak,
      coreColor:
          channels.isEmpty ? null : seratoWaveformColorForChannels(channels),
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
    required List<int>? projectedBeatMarkers,
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
      beats: select(projectedBeatMarkers ?? waveform.beatsMs, 7),
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

const Map<String, Color> _waveformChannelColors = {
  'low': Color(0xFFFF0000),
  'bass': Color(0xFFFF0000),
  'sub': Color(0xFFFF0000),
  'sub_bass': Color(0xFFFF0000),
  'mid': Color(0xFF00FF00),
  'mids': Color(0xFF00FF00),
  'vocal': Color(0xFF00FF00),
  'high': Color(0xFF0000FF),
  'treble': Color(0xFF0000FF),
};

@visibleForTesting
Color waveformChannelColor(String name) {
  final normalized = name.trim().toLowerCase().replaceAll('-', '_');
  final registered = _waveformChannelColors[normalized];
  if (registered != null) return registered;
  var hash = 2166136261;
  for (final codeUnit in normalized.codeUnits) {
    hash = ((hash ^ codeUnit) * 16777619) & 0x7fffffff;
  }
  return HSVColor.fromAHSV(1, (hash % 360).toDouble(), 1, 1).toColor();
}

/// Separated-stem channel hues (ADR 0006 `stems4-demucs-v1` /
/// `stems5-hybrid-v1`).
///
/// Deliberately a sibling of [_waveformChannelColors] rather than extra keys in
/// it: spectral band colors are pure primaries chosen for the additive mixing
/// in [seratoWaveformColorForChannels], and `bass` / `vocal` already mean
/// *frequency band* there. Stem ticks are read individually, never mixed, so
/// they use distinguishable hues instead.
const Map<String, Color> _stemChannelColors = {
  'vocals': Color(0xFFE91E63),
  'melody': Color(0xFF7C4DFF),
  'other': Color(0xFF7C4DFF),
  'bass': Color(0xFF00BCD4),
  'kick': Color(0xFFFFA726),
  'drums': Color(0xFFFFA726),
  'perc': Color(0xFF8BC34A),
};

/// Stem-channel tick color. Unknown names fall through to the deterministic
/// spectral hash so a future channel set still paints something stable.
///
/// Unlike [waveformChannelColor] this is not `@visibleForTesting`: stem ticks
/// are painted by `TimelineClipWidget`, so it is a real cross-file accessor.
Color stemChannelColor(String name) {
  final normalized = name.trim().toLowerCase().replaceAll('-', '_');
  return _stemChannelColors[normalized] ?? waveformChannelColor(normalized);
}

/// Serato-style additive channel hue. Amplitude changes column geometry, not
/// color brightness, so quiet and loud frames keep comparable spectral color.
@visibleForTesting
Color? seratoWaveformColorForChannels(Map<String, double> channels) {
  var red = 0.0;
  var green = 0.0;
  var blue = 0.0;
  for (final entry in channels.entries) {
    final energy = entry.value.clamp(0.0, 1.0).toDouble();
    if (energy <= 0) continue;
    final color = waveformChannelColor(entry.key);
    red += energy * color.r;
    green += energy * color.g;
    blue += energy * color.b;
  }
  final maxComponent = math.max(red, math.max(green, blue));
  if (maxComponent <= 0) return null;
  const value = 0.94;
  return Color.fromARGB(
    255,
    ((red / maxComponent) * value * 255).round().clamp(0, 255),
    ((green / maxComponent) * value * 255).round().clamp(0, 255),
    ((blue / maxComponent) * value * 255).round().clamp(0, 255),
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
/// Rich analysis controls waveform geometry and per-frame EQ color, while raw
/// peaks retain the lane color fallback. Beat, downbeat, transient, and
/// silence metadata sit on top of the waveform
/// and are density-thinned so dense zoom levels stay readable.
class TimelineWaveformPainter extends CustomPainter {
  final List<double> peaks;
  final TimelineWaveformData? waveform;
  final List<int>? projectedBeatMarkers;
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
    this.projectedBeatMarkers,
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
    final hasRichFrames = richWaveform?.frames.isNotEmpty ?? false;
    final frameCount = paintCache._prepareFrameGeometry(
      peaks: peaks,
      waveform: richWaveform,
    );
    if (frameCount == 0) {
      final pendingPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.butt
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: 0.72);
      final midY = size.height / 2;
      canvas.drawLine(
        Offset(size.width * startFraction, midY),
        Offset(size.width * endFraction, midY),
        pendingPaint,
      );
      _paintEditOverlays(canvas, size);
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
          projectedBeatMarkers: projectedBeatMarkers,
        ),
        visibleStartFraction: startFraction,
        visibleEndFraction: endFraction,
      );
    }

    final midY = size.height / 2;
    final slot = size.width / frameCount;
    final strokeWidth = _sliceStrokeWidth(slot);
    final corePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..blendMode = BlendMode.srcOver
      ..strokeWidth = strokeWidth;

    for (var i = frameRange.start; i < frameRange.end; i++) {
      final frame = paintCache._frameGeometryAt(i);
      final frac = (i + 0.5) / frameCount;
      final inTrim = frac >= trimStartFraction && frac <= trimEndFraction;
      final alpha = inTrim ? 1.0 : 0.46;
      final localSourceMs = safeSourceDurationMs <= 0
          ? 0
          : (((i + 0.5) * safeSourceDurationMs) / frameCount).round();
      final cx = _xForLocalSourcePosition(
        localSourceMs,
        safeSourceDurationMs,
        size.width,
      );
      final upperHeight =
          frame.maxPeak.clamp(0.0, 1.0).toDouble() * (size.height / 2 - 1);
      final lowerHeight =
          (-frame.minPeak).clamp(0.0, 1.0).toDouble() * (size.height / 2 - 1);
      if (upperHeight <= 0 && lowerHeight <= 0) continue;
      final frameColor = hasRichFrames ? frame.coreColor ?? color : color;
      corePaint.color = _withAlpha(inTrim ? frameColor : dimColor, alpha);
      canvas.drawLine(
        Offset(cx, midY - upperHeight),
        Offset(cx, midY + lowerHeight),
        corePaint,
      );
    }

    _paintEditOverlays(canvas, size);
    paintCache._notifySizeChanged(cacheByteSizeBeforePaint);
  }

  @override
  bool shouldRepaint(covariant TimelineWaveformPainter old) =>
      (old.color != color &&
          (_usesLaneColor(waveform) || _usesLaneColor(old.waveform))) ||
      old.peaks != peaks ||
      old.waveform != waveform ||
      old.mixClip != mixClip ||
      old.mappingRevision != mappingRevision ||
      old.laneIdentity != laneIdentity ||
      old.viewportPixelsPerMs != viewportPixelsPerMs ||
      old.visibleStartFraction != visibleStartFraction ||
      old.visibleEndFraction != visibleEndFraction ||
      old.dimColor != dimColor ||
      old.handleColor != handleColor ||
      old.snapMarkerColor != snapMarkerColor ||
      old.trimStartFraction != trimStartFraction ||
      old.trimEndFraction != trimEndFraction ||
      old.snapMarkerCount != snapMarkerCount;

  bool _usesLaneColor(TimelineWaveformData? data) =>
      data == null ||
      data.frames.isEmpty ||
      data.frames.any((frame) => frame.resolvedChannels.isEmpty);

  double _sliceStrokeWidth(double slot) {
    if (!slot.isFinite || slot <= 0) return 0.5;
    return (slot * 1.16).clamp(0.6, 5.0).toDouble();
  }

  void _paintEditOverlays(Canvas canvas, Size size) {
    // Edit-mode snap notches remain separate from analyzed beat/downbeat ticks.
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
      final x = frac.clamp(0.0, 1.0) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), handle);
    }
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
