import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import '../app/theme.dart';
import '../core/engine/tempo_automation.dart';
import '../core/engine/timeline_model.dart';
import '../core/engine/transition_diagnostics.dart';
import '../models/timeline_clip.dart';
import '../models/timeline_viewport.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import 'timeline_clip_widget.dart';
import 'timeline_waveform_painter.dart';

typedef TimelineAnalysisEditCallback = void Function(
  Track track, {
  int? initialFirstDownbeatMs,
});
typedef TimelinePitchModeChangedCallback = FutureOr<void> Function(
  Track track,
  String pitchMode,
);
typedef TimelineClipEditCallback = FutureOr<void> Function(
  Track track,
  int valueMs,
);

@visibleForTesting
const int timelineWaveformCacheFrameBudget = 196608;

@visibleForTesting
const int timelineWaveformCacheByteBudget = 12 * 1024 * 1024;

const int _timelineWaveformFrameAndPeakBytes = 48 + 8;
const int _timelineWaveformSliceBaseBytes = 256 + 128;
const int _timelineWaveformActiveMarkerReserveBytes = 64 * 1024;
const int _timelineWaveformMinSamples = 8;
const int _timelineWaveformMaxSamples = 65536;

@visibleForTesting
int timelineWaveformActiveSampleCap(int activeLaneCount) {
  final lanes = math.max(1, activeLaneCount);
  var candidate = _timelineWaveformMinSamples;
  var result = candidate;
  while (candidate <= _timelineWaveformMaxSamples) {
    final estimatedSliceBytes = _timelineWaveformSliceBaseBytes +
        candidate * _timelineWaveformFrameAndPeakBytes +
        TimelineWaveformPaintCache.maxRetainedByteSizeForFrameCount(
          candidate,
        ) +
        _timelineWaveformActiveMarkerReserveBytes;
    if (candidate * lanes > timelineWaveformCacheFrameBudget ||
        estimatedSliceBytes * lanes > timelineWaveformCacheByteBudget) {
      break;
    }
    result = candidate;
    candidate *= 2;
  }
  return result;
}

String _timelineLaneId(Track track) =>
    track.queueItemId.isNotEmpty ? track.queueItemId : track.id;

String _mixClipLaneId(MixClip clip) {
  final queueItemId = clip.queueItemId;
  return queueItemId != null && queueItemId.isNotEmpty ? queueItemId : clip.id;
}

/// Stacked compact-waveform timeline for the phone-first mix planner
/// (~390x844), wired to the live mix engine when a [timelineModel] and
/// [positionMsStream] are supplied.
///
/// The dominant object is a stack of overlapping waveform lanes sharing a single
/// global playhead — not list rows or cards. Previous / current / upcoming clips
/// are placed on one timeline with synthetic transition windows so overlap is
/// visible. Lane identity stays inside each row so the timeline can converge
/// with the queue list instead of relying on separate edge controls.
///
/// Source trim stays separate from timeline placement. Engine-backed callers
/// provide real [TimelineModel] clips plus the raw global playhead stream;
/// tests/empty states may still omit the engine contract and use the queue
/// editing fallback geometry.
class StackedWaveformTimeline extends StatefulWidget {
  final Track? previousTrack;
  final Track currentTrack;
  final List<Track> upcomingTracks;
  final List<double> Function(Track) peaksFor;
  final TimelineWaveformData Function(Track, int targetSampleCount)?
      waveformFor;
  final TrimRange Function(Track) trimRangeFor;
  final TimelineClip Function(Track, TimelineClip)? clipFor;
  final String Function(Track)? pitchModeFor;
  final TimelineClipEditCallback? onTimelineStartChanged;
  final TimelineClipEditCallback? onTrimStartChanged;
  final TimelineClipEditCallback? onTrimEndChanged;
  final ValueChanged<Track>? onMoveEarlier;
  final ValueChanged<Track>? onMoveLater;
  final TimelineAnalysisEditCallback? onEditAnalysis;
  final TimelinePitchModeChangedCallback? onPitchModeChanged;
  final BeatSnapMode transitionSnapMode;
  final ValueChanged<BeatSnapMode>? onTransitionSnapModeChanged;
  final TimelineModel? timelineModel;
  final Set<String> pitchFallbackClipIds;
  final Map<String, ClipTempoRuntimeState> clipTempoStates;
  final int playheadPositionMs;
  final Stream<int>? positionMsStream;
  final VoidCallback? onScrubStart;
  final ValueChanged<int>? onScrubUpdate;
  final Future<void> Function(int globalMs)? onScrubEnd;
  final ValueChanged<List<Track>>? onVisibleTracksChanged;

  const StackedWaveformTimeline({
    super.key,
    required this.previousTrack,
    required this.currentTrack,
    required this.upcomingTracks,
    required this.peaksFor,
    this.waveformFor,
    required this.trimRangeFor,
    this.clipFor,
    this.pitchModeFor,
    this.onTimelineStartChanged,
    this.onTrimStartChanged,
    this.onTrimEndChanged,
    this.onMoveEarlier,
    this.onMoveLater,
    this.onEditAnalysis,
    this.onPitchModeChanged,
    this.transitionSnapMode = BeatSnapMode.downbeat,
    this.onTransitionSnapModeChanged,
    this.timelineModel,
    this.pitchFallbackClipIds = const {},
    this.clipTempoStates = const {},
    this.playheadPositionMs = 0,
    this.positionMsStream,
    this.onScrubStart,
    this.onScrubUpdate,
    this.onScrubEnd,
    this.onVisibleTracksChanged,
  });

  /// Synthetic crossfade/transition window between adjacent clips (ms). Visual
  /// only — there is no real mixer.
  static const int transitionMs = 18000;

  /// Timeline metadata is overlaid on top of the lane so the waveform keeps the
  /// full phone width for direct manipulation.
  static const double railWidth = 0;

  @override
  State<StackedWaveformTimeline> createState() =>
      _StackedWaveformTimelineState();
}

enum SnapMarkerMode { free, downbeat, beat1, beat4, beat16 }

enum _TrimEdge { start, end }

enum _TimelineTrackAction {
  correctAnalysis,
  moveEarlierInQueue,
  moveLaterInQueue,
}

extension on SnapMarkerMode {
  int get markerCount => switch (this) {
        SnapMarkerMode.free => 0,
        SnapMarkerMode.downbeat => 4,
        SnapMarkerMode.beat1 => 1,
        SnapMarkerMode.beat4 => 4,
        SnapMarkerMode.beat16 => 16,
      };

  String get label => switch (this) {
        SnapMarkerMode.free => 'Free',
        SnapMarkerMode.downbeat => 'Downbeat',
        SnapMarkerMode.beat1 => '1 beat',
        SnapMarkerMode.beat4 => '4 beats',
        SnapMarkerMode.beat16 => '16 beats',
      };

  BeatSnapMode get beatSnapMode => switch (this) {
        SnapMarkerMode.free => BeatSnapMode.free,
        SnapMarkerMode.downbeat => BeatSnapMode.downbeat,
        SnapMarkerMode.beat1 => BeatSnapMode.beat1,
        SnapMarkerMode.beat4 => BeatSnapMode.beat4,
        SnapMarkerMode.beat16 => BeatSnapMode.beat16,
      };
}

SnapMarkerMode _snapMarkerModeFor(BeatSnapMode mode) => switch (mode) {
      BeatSnapMode.free => SnapMarkerMode.free,
      BeatSnapMode.downbeat => SnapMarkerMode.downbeat,
      BeatSnapMode.beat1 => SnapMarkerMode.beat1,
      BeatSnapMode.beat4 => SnapMarkerMode.beat4,
      BeatSnapMode.beat16 => SnapMarkerMode.beat16,
    };

class _SnapGrid {
  final List<int> markersMs;
  final int? intervalMs;

  const _SnapGrid({this.markersMs = const [], this.intervalMs});
}

@visibleForTesting
int snapTimelineStartMsToMusicalGrid({
  required int requestedStartMs,
  required SnapMarkerMode mode,
  required TimelineClip clip,
  required ClipTempoMetadata tempo,
}) {
  final safeRequestedStartMs = math.max(0, requestedStartMs);
  if (mode == SnapMarkerMode.free) return safeRequestedStartMs;

  final grid = _snapGridFor(mode, tempo);
  final sourceAnchorMs = _nearestMarker(
        grid.markersMs.where(
          (marker) =>
              marker >= clip.sourceStartMs && marker <= clip.sourceEndMs,
        ),
        clip.sourceStartMs,
      ) ??
      clip.sourceStartMs;
  final anchorDeltaMs = sourceAnchorMs - clip.sourceStartMs;
  final intervalMs = grid.intervalMs ?? _fallbackSnapIntervalMs(mode);
  if (intervalMs <= 1) return safeRequestedStartMs;

  final targetAnchorMs = safeRequestedStartMs + anchorDeltaMs;
  final snappedAnchorMs = _snapToAvailableMarkerGrid(
    targetAnchorMs,
    grid.markersMs,
    fallbackIntervalMs: intervalMs,
  );
  return math.max(0, snappedAnchorMs - anchorDeltaMs);
}

int _snapToAvailableMarkerGrid(
  int targetMs,
  List<int> markers, {
  required int fallbackIntervalMs,
}) {
  if (markers.isEmpty) return _snapToInterval(targetMs, fallbackIntervalMs);
  if (targetMs >= markers.first && targetMs <= markers.last) {
    return _nearestMarker(markers, targetMs)!;
  }

  final anchor = targetMs < markers.first ? markers.first : markers.last;
  final edgeInterval = markers.length < 2
      ? fallbackIntervalMs
      : targetMs < markers.first
          ? markers[1] - markers.first
          : markers.last - markers[markers.length - 2];
  final interval = edgeInterval > 0 ? edgeInterval : fallbackIntervalMs;
  if (interval <= 1) return targetMs;
  return anchor + (((targetMs - anchor) / interval).round() * interval);
}

@visibleForTesting
int snapSourceMsToMusicalGrid({
  required int requestedSourceMs,
  required SnapMarkerMode mode,
  required TimelineClip clip,
  required ClipTempoMetadata tempo,
}) {
  final safeRequestedSourceMs =
      requestedSourceMs.clamp(0, math.max(0, clip.sourceDurationMs)).toInt();
  if (mode == SnapMarkerMode.free) return safeRequestedSourceMs;

  final grid = _snapGridFor(mode, tempo);
  final marker = _nearestMarker(
    grid.markersMs.where(
      (candidate) =>
          candidate >= 0 && candidate <= math.max(0, clip.sourceDurationMs),
    ),
    safeRequestedSourceMs,
  );
  if (marker != null) return marker;

  final intervalMs = grid.intervalMs ?? _fallbackSnapIntervalMs(mode);
  if (intervalMs <= 1) return safeRequestedSourceMs;
  return _snapToInterval(
    safeRequestedSourceMs,
    intervalMs,
  ).clamp(0, math.max(0, clip.sourceDurationMs)).toInt();
}

_SnapGrid _snapGridFor(SnapMarkerMode mode, ClipTempoMetadata tempo) {
  if (mode == SnapMarkerMode.free) {
    return const _SnapGrid(intervalMs: 1);
  }

  var markers = beatMarkersForSnapMode(tempo, mode.beatSnapMode);
  if (mode == SnapMarkerMode.downbeat && markers.isEmpty) {
    markers = beatMarkersForSnapMode(tempo, BeatSnapMode.beat4);
  }
  if (markers.isEmpty) return const _SnapGrid(intervalMs: 1);

  return _SnapGrid(
    markersMs: markers,
    intervalMs: markers.length >= 2 ? _medianIntervalMs(markers) : 1,
  );
}

int? _nearestMarker(Iterable<int> markers, int targetMs) {
  int? nearest;
  int? nearestDistance;
  for (final marker in markers) {
    final distance = (marker - targetMs).abs();
    if (nearestDistance == null || distance < nearestDistance) {
      nearest = marker;
      nearestDistance = distance;
    }
  }
  return nearest;
}

int _medianIntervalMs(List<int> sortedMarkers) {
  if (sortedMarkers.length < 2) return 0;
  final intervals = <int>[
    for (var i = 1; i < sortedMarkers.length; i++)
      if (sortedMarkers[i] > sortedMarkers[i - 1])
        sortedMarkers[i] - sortedMarkers[i - 1],
  ]..sort();
  if (intervals.isEmpty) return 0;
  return intervals[intervals.length ~/ 2];
}

int _fallbackSnapIntervalMs(SnapMarkerMode mode) => switch (mode) {
      SnapMarkerMode.free => 1,
      SnapMarkerMode.downbeat => 2000,
      SnapMarkerMode.beat1 => 500,
      SnapMarkerMode.beat4 => 2000,
      SnapMarkerMode.beat16 => 8000,
    };

int _snapToInterval(int valueMs, int intervalMs) {
  if (intervalMs <= 1) return valueMs;
  return ((valueMs / intervalMs).round() * intervalMs)
      .clamp(0, 2147483647)
      .toInt();
}

class _LaneModel {
  final Track track;
  final MixClip mixClip;
  final LaneRole role;
  final Color accent;
  final String status;
  final double height;

  _LaneModel({
    required this.track,
    required this.mixClip,
    required this.role,
    required this.accent,
    required this.status,
    required this.height,
  });

  TimelineClip get clip => mixClip.placement;
  String get laneId => _timelineLaneId(track);
  int get timelineStartMs => mixClip.timelineStartMs;
  int get timelineEndMs => mixClip.timelineEndMs;
}

class _WaveformSliceCacheKey {
  final String trackId;
  final Object analysisRevision;
  final int sourceStartMs;
  final int sourceEndMs;
  final int sampleCount;

  const _WaveformSliceCacheKey({
    required this.trackId,
    required this.analysisRevision,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.sampleCount,
  });

  @override
  bool operator ==(Object other) =>
      other is _WaveformSliceCacheKey &&
      other.trackId == trackId &&
      other.analysisRevision == analysisRevision &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceEndMs == sourceEndMs &&
      other.sampleCount == sampleCount;

  @override
  int get hashCode => Object.hash(
        trackId,
        analysisRevision,
        sourceStartMs,
        sourceEndMs,
        sampleCount,
      );
}

class _WaveformSlice {
  final TimelineWaveformData waveform;
  final List<double> peaks;
  final TimelineWaveformPaintCache paintCache;

  _WaveformSlice({
    required this.waveform,
    required this.peaks,
    required VoidCallback onPaintCacheSizeChanged,
  }) : paintCache = TimelineWaveformPaintCache(
          onSizeChanged: onPaintCacheSizeChanged,
        );

  int get estimatedBytes =>
      waveform.estimatedByteSize +
      peaks.length * 8 +
      paintCache.estimatedByteSize +
      128;
}

class _PreviewWaveformSlice {
  final int generation;
  final _WaveformSliceCacheKey cacheKey;
  final _WaveformSlice slice;

  const _PreviewWaveformSlice({
    required this.generation,
    required this.cacheKey,
    required this.slice,
  });
}

typedef _WaveformSliceLeaseCallback = void Function(
  String laneId,
  _WaveformSlice slice,
);

class _ActiveWaveformSliceLease extends StatefulWidget {
  final String laneId;
  final _WaveformSlice slice;
  final _WaveformSliceLeaseCallback onAttach;
  final _WaveformSliceLeaseCallback onDetach;
  final Widget child;

  const _ActiveWaveformSliceLease({
    required this.laneId,
    required this.slice,
    required this.onAttach,
    required this.onDetach,
    required this.child,
  });

  @override
  State<_ActiveWaveformSliceLease> createState() =>
      _ActiveWaveformSliceLeaseState();
}

class _ActiveWaveformSliceLeaseState extends State<_ActiveWaveformSliceLease> {
  @override
  void initState() {
    super.initState();
    widget.onAttach(widget.laneId, widget.slice);
  }

  @override
  void didUpdateWidget(covariant _ActiveWaveformSliceLease oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.laneId == widget.laneId &&
        identical(oldWidget.slice, widget.slice)) {
      return;
    }
    oldWidget.onDetach(oldWidget.laneId, oldWidget.slice);
    widget.onAttach(widget.laneId, widget.slice);
  }

  @override
  void dispose() {
    widget.onDetach(widget.laneId, widget.slice);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ResolvedTimelineLayout {
  final Map<Track, MixClip> placed;
  final MixClip currentClip;
  final List<MixClip> placedClips;
  final int totalMs;

  const _ResolvedTimelineLayout({
    required this.placed,
    required this.currentClip,
    required this.placedClips,
    required this.totalMs,
  });
}

enum _TimelineEditKind { placement, trimStart, trimEnd, pitchMode }

class _TimelineEditTransaction {
  final int epoch;
  final String laneId;
  final Track track;
  final FutureOr<void> Function() operation;
  final int? previewGeneration;
  final _TimelineEditKind kind;

  const _TimelineEditTransaction({
    required this.epoch,
    required this.laneId,
    required this.track,
    required this.operation,
    required this.previewGeneration,
    required this.kind,
  });
}

class _StackedWaveformTimelineState extends State<StackedWaveformTimeline> {
  static const double _minZoom = 0.5;
  static const double _maxZoom = TimelineViewport.maxPixelsPerSecond;
  static const double _waveformPhysicalPixelsPerSample = 1.25;
  static const int _minWaveformSamples = _timelineWaveformMinSamples;
  static const int _maxWaveformSamples = _timelineWaveformMaxSamples;
  static const int _maxCachedWaveformFrames = timelineWaveformCacheFrameBudget;
  static const int _maxAggregateWaveformBytes = timelineWaveformCacheByteBudget;
  static const int _maxCachedTempoMetadata = 32;
  static const double _waveformPaintWindowPx = 96;
  static const double _laneScrollCacheExtentPx = 160;
  static const double _selectionControlsWidth = 96;
  static const double _scrubEdgeScrollZonePx = 56;
  static const double _scrubMaxEdgeScrollPx = 32;

  late SnapMarkerMode _snapMode;
  double _zoom = 1.0;
  int? _manualOffsetMs;
  String? _selectedTrackId;
  String? _activeClipDragTrackId;
  TimelineClip? _activeClipDragStartClip;
  int? _activeClipDragGeneration;
  String? _activeTrimTrackId;
  _TrimEdge? _activeTrimEdge;
  TimelineClip? _activeTrimStartClip;
  int? _activeTrimGeneration;
  int _nextPreviewGeneration = 0;
  int _timelineEditEpoch = 0;
  final Map<String, TimelineClip> _previewClips = {};
  final Map<String, int> _previewGenerations = {};
  final Map<String, _TimelineEditTransaction> _timelineEditTransactions = {};
  final LinkedHashMap<_WaveformSliceCacheKey, _WaveformSlice>
      _waveformSliceCache = LinkedHashMap();
  final LinkedHashMap<String, _PreviewWaveformSlice> _previewWaveformSlices =
      LinkedHashMap();
  final Map<String, _WaveformSlice> _activeWaveformSlices = {};
  final Set<_WaveformSlice> _pendingWaveformGeometryReleases =
      HashSet<_WaveformSlice>.identity();
  final Map<Object, ClipTempoMetadata> _tempoMetadataCache = {};
  _ResolvedTimelineLayout? _resolvedLayout;
  TimelineViewport? _scaleStartViewport;
  double? _scaleStartZoom;
  double? _scaleLastLocalFocalX;
  bool _isScrubbing = false;
  bool _preserveViewportForScrub = false;
  int? _lastScrubMs;
  late final ValueNotifier<int> _livePlayheadMs;
  StreamSubscription<int>? _positionSubscription;
  int _fallbackPlayheadMs = 0;
  int _timelineDurationMs = 0;
  bool _engineBacked = false;
  final ScrollController _laneScrollController = ScrollController();
  List<_LaneModel> _latestLanes = const [];
  double _laneViewportHeight = 0;
  String? _lastVisibleLaneSignature;
  bool _visibleLaneReportScheduled = false;
  bool _waveformBudgetEnforcementScheduled = false;
  Timer? _visibleLaneDebounce;

  @override
  void initState() {
    super.initState();
    _snapMode = _snapMarkerModeFor(widget.transitionSnapMode);
    _livePlayheadMs = ValueNotifier<int>(widget.playheadPositionMs);
    _bindPositionStream();
    _laneScrollController.addListener(_scheduleDebouncedVisibleLaneReport);
  }

  @override
  void dispose() {
    _invalidateTimelineEditOwnership();
    _positionSubscription?.cancel();
    _visibleLaneDebounce?.cancel();
    _livePlayheadMs.dispose();
    _laneScrollController
      ..removeListener(_scheduleDebouncedVisibleLaneReport)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StackedWaveformTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolvedLayout = null;

    _pruneTimelineEditOwnership(_renderedLaneIds(widget));

    if (!identical(oldWidget.positionMsStream, widget.positionMsStream)) {
      _bindPositionStream();
    } else if (widget.positionMsStream == null &&
        oldWidget.playheadPositionMs != widget.playheadPositionMs) {
      _livePlayheadMs.value = widget.playheadPositionMs;
    }

    if (oldWidget.waveformFor != widget.waveformFor) {
      _waveformSliceCache.clear();
      _previewWaveformSlices.clear();
    }

    if (oldWidget.transitionSnapMode != widget.transitionSnapMode &&
        _activeClipDragTrackId == null &&
        _activeTrimTrackId == null) {
      _snapMode = _snapMarkerModeFor(widget.transitionSnapMode);
    }

    if (_timelineLaneId(oldWidget.currentTrack) !=
        _timelineLaneId(widget.currentTrack)) {
      if (_isScrubbing || _preserveViewportForScrub) {
        if (!_isScrubbing) {
          _preserveViewportForScrub = false;
        }
        return;
      }
      _manualOffsetMs = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('stacked_waveform_timeline'),
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final paneWidth =
                  (constraints.maxWidth - StackedWaveformTimeline.railWidth)
                      .clamp(1.0, double.infinity);
              return _buildTimeline(context, paneWidth);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTimeline(
    BuildContext context,
    double paneWidth,
  ) {
    final layout = _resolveTimelineLayout();
    final placed = layout.placed;
    final currentClip = layout.currentClip;
    final totalMs = layout.totalMs;
    _engineBacked = widget.positionMsStream != null ||
        (widget.timelineModel?.clips.isNotEmpty ?? false);
    _timelineDurationMs = totalMs;
    _fallbackPlayheadMs = currentClip.timelineStartMs +
        StackedWaveformTimeline.transitionMs +
        8000;

    final fitPps = totalMs <= 0
        ? TimelineViewport.minPixelsPerSecond
        : (paneWidth / (totalMs / 1000));
    final basePps = math.max(fitPps, TimelineViewport.minPixelsPerSecond);
    final effectiveMaxPps = _effectiveMaxPixelsPerSecond(placed);
    final pps = (basePps * _zoom).clamp(
      TimelineViewport.minPixelsPerSecond,
      effectiveMaxPps,
    );
    final viewportOffsetMs = _manualOffsetMs ??
        (currentClip.timelineStartMs - 60000).clamp(0, totalMs);
    final viewport = TimelineViewport.clamped(
      durationMs: totalMs,
      widthPx: paneWidth,
      pixelsPerSecond: pps,
      offsetMs: viewportOffsetMs,
    );

    // --- Build lane models in stack order (history → future, top to bottom). ---
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final playerTheme = SoundQPlayerTheme.of(context);
    final laneHeightExtra = math.max(
      0.0,
      TimelineLaneHeader.heightForTextScale(textScale) - 64,
    );
    final lanes = <_LaneModel>[];
    if (widget.previousTrack != null) {
      lanes.add(
        _LaneModel(
          track: widget.previousTrack!,
          mixClip: placed[widget.previousTrack!]!,
          role: LaneRole.previous,
          accent: playerTheme.timelinePrevious,
          status: 'Played',
          height: 114 + laneHeightExtra,
        ),
      );
    }
    lanes.add(
      _LaneModel(
        track: widget.currentTrack,
        mixClip: currentClip,
        role: LaneRole.current,
        accent: playerTheme.timelineCurrent,
        status: 'Now playing',
        height: 146 + laneHeightExtra,
      ),
    );
    final upcoming = widget.upcomingTracks.toList();
    for (var i = 0; i < upcoming.length; i++) {
      final collapsed = i > 0;
      lanes.add(
        _LaneModel(
          track: upcoming[i],
          mixClip: placed[upcoming[i]]!,
          role: collapsed ? LaneRole.collapsed : LaneRole.upcoming,
          accent: playerTheme.timelineUpcoming,
          status: i == 0 ? 'Up next' : 'Later',
          height: (collapsed ? 84 : 114) + laneHeightExtra,
        ),
      );
    }
    final placedClips = layout.placedClips;
    final selectedLane = _selectedLaneForRegion(lanes);

    final overlapBands = _buildOverlapBands(
      context,
      placedClips,
      viewport,
      paneWidth,
    );

    return GestureDetector(
      key: const ValueKey('timeline_pan_surface'),
      behavior: HitTestBehavior.opaque,
      onTap: _clearSelectedTrack,
      onScaleStart: (details) => _beginViewportScale(viewport, details),
      onScaleUpdate: (details) => _updateViewportScale(viewport, details),
      onScaleEnd: (_) {
        _scaleStartViewport = null;
        _scaleStartZoom = null;
        _scaleLastLocalFocalX = null;
      },
      child: Stack(
        children: [
          ...overlapBands,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRuler(context, viewport, paneWidth),
              if (selectedLane != null)
                ValueListenableBuilder<int>(
                  valueListenable: _livePlayheadMs,
                  builder: (context, livePlayheadMs, _) =>
                      _timelineSelectionRegion(
                    context,
                    selectedLane,
                    placedClips,
                    _resolvedPlayheadMs(livePlayheadMs),
                  ),
                ),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        _latestLanes = lanes;
                        _laneViewportHeight = constraints.maxHeight;
                        _scheduleVisibleLaneReport();
                        final activeLaneCapacity = _activeWaveformLaneCapacity(
                          lanes,
                          constraints.maxHeight,
                        );
                        final activeSampleCap = timelineWaveformActiveSampleCap(
                          activeLaneCapacity,
                        );
                        return ListView.builder(
                          key: const PageStorageKey('timeline_lane_scroll'),
                          controller: _laneScrollController,
                          scrollCacheExtent: const ScrollCacheExtent.pixels(
                            _laneScrollCacheExtentPx,
                          ),
                          itemCount: lanes.length,
                          itemBuilder: (context, index) => _buildLane(
                            context,
                            lanes[index],
                            viewport,
                            paneWidth,
                            activeSampleCap,
                          ),
                        );
                      },
                    ),
                    _buildPlayheadOverlay(
                      context,
                      viewport,
                      paneWidth,
                      placedClips,
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              key: const ValueKey('timeline_options_fab'),
              heroTag: 'timeline_options_fab',
              tooltip: 'Timeline snap and zoom options',
              onPressed: () => _showOptionsPanel(context),
              child: const Icon(Icons.tune),
            ),
          ),
        ],
      ),
    );
  }

  void _bindPositionStream() {
    final previous = _positionSubscription;
    _positionSubscription = null;
    if (previous != null) unawaited(previous.cancel());
    _livePlayheadMs.value = widget.playheadPositionMs;
    final stream = widget.positionMsStream;
    if (stream == null) return;
    _positionSubscription = stream.listen((positionMs) {
      if (_livePlayheadMs.value != positionMs) {
        _livePlayheadMs.value = positionMs;
      }
    });
  }

  int _resolvedPlayheadMs(int livePositionMs) => _engineBacked
      ? livePositionMs.clamp(0, _timelineDurationMs).toInt()
      : _fallbackPlayheadMs;

  Widget _buildPlayheadOverlay(
    BuildContext context,
    TimelineViewport viewport,
    double paneWidth,
    List<MixClip> placedClips,
  ) {
    return ValueListenableBuilder<int>(
      valueListenable: _livePlayheadMs,
      builder: (context, livePositionMs, _) {
        final playheadMs = _resolvedPlayheadMs(livePositionMs);
        final playheadPaneX = viewport.msToX(playheadMs);
        final visible = playheadPaneX.isFinite &&
            playheadPaneX >= 0 &&
            playheadPaneX <= paneWidth;
        if (!visible) return const SizedBox.shrink();

        final dominantClip = _dominantClipAt(placedClips, playheadMs);
        final playheadLabel = _playheadTimeLabel(playheadMs, dominantClip);
        final badgeLeft =
            (StackedWaveformTimeline.railWidth + playheadPaneX + 6)
                .clamp(4.0, math.max(4.0, paneWidth - 152))
                .toDouble();

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              key: const ValueKey('timeline_playhead'),
              top: 0,
              bottom: 0,
              left: StackedWaveformTimeline.railWidth + playheadPaneX,
              width: 2,
              child: IgnorePointer(
                child: Semantics(
                  label: 'Mix playhead at ${_formatClock(playheadMs)}',
                  child: const ColoredBox(color: Color(0xFFD32F2F)),
                ),
              ),
            ),
            Positioned(
              key: const ValueKey('timeline_playhead_time_badge'),
              top: 2,
              left: badgeLeft,
              child: IgnorePointer(
                child: _playheadBadge(context, playheadLabel),
              ),
            ),
            if (_hasScrubHandlers)
              Positioned(
                key: const ValueKey('timeline_playhead_drag_handle'),
                top: 0,
                bottom: 0,
                left: StackedWaveformTimeline.railWidth + playheadPaneX - 14,
                width: 28,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (details) => _beginScrubAt(
                    viewport,
                    paneWidth,
                    StackedWaveformTimeline.railWidth +
                        playheadPaneX -
                        14 +
                        details.localPosition.dx,
                  ),
                  onHorizontalDragUpdate: (details) => _updateScrubAt(
                    viewport,
                    paneWidth,
                    StackedWaveformTimeline.railWidth +
                        playheadPaneX -
                        14 +
                        details.localPosition.dx,
                  ),
                  onHorizontalDragEnd: (_) => _endScrub(),
                  onHorizontalDragCancel: _endScrub,
                ),
              ),
          ],
        );
      },
    );
  }

  void _scheduleDebouncedVisibleLaneReport() {
    _visibleLaneDebounce?.cancel();
    _visibleLaneDebounce = Timer(
      const Duration(milliseconds: 120),
      _scheduleVisibleLaneReport,
    );
  }

  void _scheduleVisibleLaneReport() {
    if (widget.onVisibleTracksChanged == null || _visibleLaneReportScheduled) {
      return;
    }
    _visibleLaneReportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleLaneReportScheduled = false;
      if (!mounted || widget.onVisibleTracksChanged == null) return;
      _reportVisibleLanes();
    });
  }

  void _reportVisibleLanes() {
    if (_latestLanes.isEmpty || _laneViewportHeight <= 0) return;
    final offset =
        _laneScrollController.hasClients ? _laneScrollController.offset : 0.0;
    final end = offset + _laneViewportHeight;
    var laneTop = 0.0;
    int? firstVisible;
    int? lastVisible;
    for (var index = 0; index < _latestLanes.length; index++) {
      final lane = _latestLanes[index];
      final laneBottom = laneTop + lane.height;
      if (laneBottom > offset && laneTop < end) {
        firstVisible ??= index;
        lastVisible = index;
      }
      laneTop = laneBottom;
    }
    final first = math.max(0, (firstVisible ?? 0) - 1);
    final last = math.min(
      _latestLanes.length - 1,
      (lastVisible ?? first) + 1,
    );
    final visible = [
      for (var index = first; index <= last; index++) _latestLanes[index].track,
    ];

    final signature = visible.map(_timelineTrackIdentity).join('\u0000');
    if (signature == _lastVisibleLaneSignature) return;
    _lastVisibleLaneSignature = signature;
    widget.onVisibleTracksChanged!(List<Track>.unmodifiable(visible));
  }

  int _activeWaveformLaneCapacity(
    List<_LaneModel> lanes,
    double viewportHeight,
  ) {
    if (lanes.isEmpty) return 1;
    final minLaneHeight = lanes
        .map((lane) => lane.height)
        .reduce(math.min)
        .clamp(1.0, double.infinity);
    final coveredHeight =
        math.max(0.0, viewportHeight) + _laneScrollCacheExtentPx * 2;
    final guardedCapacity = (coveredHeight / minLaneHeight).ceil() + 2;
    return guardedCapacity.clamp(1, lanes.length).toInt();
  }

  String _timelineTrackIdentity(Track track) =>
      '${_timelineLaneId(track)}|${track.id}|${track.playbackTrackId ?? ''}';

  Set<String> _renderedLaneIds(StackedWaveformTimeline timeline) => {
        if (timeline.previousTrack case final previous?)
          _timelineLaneId(previous),
        _timelineLaneId(timeline.currentTrack),
        for (final track in timeline.upcomingTracks) _timelineLaneId(track),
      };

  void _pruneTimelineEditOwnership(Set<String> renderedLaneIds) {
    _timelineEditTransactions.removeWhere(
      (_, transaction) => !renderedLaneIds.contains(transaction.laneId),
    );
    _previewClips.removeWhere(
      (trackId, _) => !renderedLaneIds.contains(trackId),
    );
    _previewGenerations.removeWhere(
      (trackId, _) => !renderedLaneIds.contains(trackId),
    );
    _previewWaveformSlices.removeWhere(
      (laneId, _) => !renderedLaneIds.contains(laneId),
    );

    if (!renderedLaneIds.contains(_activeClipDragTrackId)) {
      _activeClipDragTrackId = null;
      _activeClipDragStartClip = null;
      _activeClipDragGeneration = null;
    }
    if (!renderedLaneIds.contains(_activeTrimTrackId)) {
      _activeTrimTrackId = null;
      _activeTrimEdge = null;
      _activeTrimStartClip = null;
      _activeTrimGeneration = null;
    }
    if (!renderedLaneIds.contains(_selectedTrackId)) {
      _selectedTrackId = null;
    }
  }

  void _invalidateTimelineEditOwnership() {
    _timelineEditEpoch += 1;
    _timelineEditTransactions.clear();
    _previewClips.clear();
    _previewGenerations.clear();
    _previewWaveformSlices.clear();
    _activeWaveformSlices.clear();
    _pendingWaveformGeometryReleases.clear();
    _activeClipDragTrackId = null;
    _activeClipDragStartClip = null;
    _activeClipDragGeneration = null;
    _activeTrimTrackId = null;
    _activeTrimEdge = null;
    _activeTrimStartClip = null;
    _activeTrimGeneration = null;
    _resolvedLayout = null;
  }

  _ResolvedTimelineLayout _resolveTimelineLayout() {
    final cached = _resolvedLayout;
    if (cached != null) return cached;

    final ordered = <Track>[
      if (widget.previousTrack != null) widget.previousTrack!,
      widget.currentTrack,
      ...widget.upcomingTracks,
    ];
    final placed = <Track, MixClip>{};
    final usedLiveClipIds = <String>{};
    var cursor = 0;
    for (var index = 0; index < ordered.length; index++) {
      final track = ordered[index];
      final trim = widget.trimRangeFor(track);
      final laneId = _timelineLaneId(track);
      final defaultClip = TimelineClip.clamped(
        id: 'clip_$laneId',
        trackId: track.id,
        sourceDurationMs: track.durationMs,
        sourceStartMs: trim.startOffsetMs,
        sourceEndMs: trim.endOffsetMs,
        timelineStartMs: cursor,
      );
      final liveClip = _liveClipForTrack(track, usedLiveClipIds);
      final baseClip = liveClip?.placement ??
          widget.clipFor?.call(track, defaultClip) ??
          defaultClip;
      final clip = _previewClipFor(track, baseClip) ?? baseClip;
      final trackTempo = _tempoForTrack(track);
      final mixClip = liveClip == null
          ? MixClip(
              placement: clip,
              queueItemId: laneId,
              tempo: trackTempo,
              pitchMode: widget.pitchModeFor?.call(track) ?? pitchModePreserve,
            )
          : _copyMixClipWithPlacement(
              liveClip,
              clip,
              fallbackTempo: trackTempo,
            );
      placed[track] = mixClip;

      if (index + 1 < ordered.length) {
        cursor = _defaultTimelineStartAfter(mixClip, ordered[index + 1]);
      }
    }

    final currentClip = placed[widget.currentTrack]!;
    final placedClips = List<MixClip>.unmodifiable(placed.values);
    final totalMs =
        placedClips.map((clip) => clip.timelineEndMs).fold<int>(0, math.max);
    return _resolvedLayout = _ResolvedTimelineLayout(
      placed: Map<Track, MixClip>.unmodifiable(placed),
      currentClip: currentClip,
      placedClips: placedClips,
      totalMs: totalMs,
    );
  }

  MixClip? _liveClipForTrack(Track track, Set<String> usedClipIds) {
    final model = widget.timelineModel;
    if (model == null || model.clips.isEmpty) return null;

    for (final clip in model.clips) {
      if (usedClipIds.contains(clip.id)) continue;
      if (!_clipMatchesTrack(clip, track)) continue;
      usedClipIds.add(clip.id);
      return clip;
    }
    return null;
  }

  TimelineClip? _previewClipFor(Track track, TimelineClip fallback) =>
      _previewClips[_timelineLaneId(track)];

  void _storePreviewClip(Track track, TimelineClip clip) {
    final laneId = _timelineLaneId(track);
    if (_previewClips[laneId] == clip) return;
    _previewClips[laneId] = clip;
    _resolvedLayout = null;
  }

  int _claimPreview(String laneId) {
    final generation = ++_nextPreviewGeneration;
    _previewGenerations[laneId] = generation;
    return generation;
  }

  void _removePreviewClip(String laneId, {int? generation}) {
    if (generation != null && _previewGenerations[laneId] != generation) {
      return;
    }
    if (_previewClips.remove(laneId) != null) {
      _resolvedLayout = null;
    }
    _previewGenerations.remove(laneId);
    _previewWaveformSlices.remove(laneId);
  }

  bool _promotePreviewWaveformSlice(String laneId, int? generation) {
    if (generation == null || _previewGenerations[laneId] != generation) {
      return false;
    }
    final previewClip = _previewClips[laneId];
    final cachedPreview = _previewWaveformSlices[laneId];
    if (previewClip == null ||
        cachedPreview == null ||
        cachedPreview.generation != generation ||
        cachedPreview.cacheKey.sourceStartMs != previewClip.sourceStartMs ||
        cachedPreview.cacheKey.sourceEndMs != previewClip.sourceEndMs) {
      return false;
    }
    _previewWaveformSlices.remove(laneId);
    _cacheWaveformSlice(cachedPreview.cacheKey, cachedPreview.slice);
    return true;
  }

  bool _isLaneSelected(String laneId) => _selectedTrackId == laneId;

  MixClip _copyMixClipWithPlacement(
    MixClip clip,
    TimelineClip placement, {
    ClipTempoMetadata fallbackTempo = ClipTempoMetadata.empty,
  }) {
    final tempo = _freshestTempo(clip.tempo, fallbackTempo);
    return MixClip(
      placement: placement,
      envelope: clip.envelope,
      audioSourceRef: clip.audioSourceRef,
      queueItemId: clip.queueItemId,
      playbackRate: clip.playbackRate,
      pitchMode: clip.pitchMode,
      tempo: tempo,
      rateAutomation: clip.rateAutomation.shiftedTimelineMs(
        placement.timelineStartMs - clip.timelineStartMs,
      ),
    );
  }

  ClipTempoMetadata _freshestTempo(
    ClipTempoMetadata liveTempo,
    ClipTempoMetadata rowTempo,
  ) {
    if (rowTempo.isEmpty) return liveTempo;
    if (liveTempo.isEmpty) return rowTempo;
    if (rowTempo == liveTempo) return liveTempo;

    final rowHasCompleteTiming =
        rowTempo.hasReliableBpm && rowTempo.hasDownbeats;
    final liveHasCompleteTiming =
        liveTempo.hasReliableBpm && liveTempo.hasDownbeats;
    if (rowHasCompleteTiming) return rowTempo;
    if (!liveHasCompleteTiming &&
        (rowTempo.hasReliableBpm || rowTempo.hasDownbeats)) {
      return rowTempo;
    }
    return liveTempo;
  }

  ClipTempoMetadata _tempoForTrack(Track track) {
    final analysis = track.analysis;
    if (analysis == null) return ClipTempoMetadata.empty;
    final cached = _tempoMetadataCache[analysis];
    if (cached != null) return cached;
    final tempo = ClipTempoMetadata.fromAnalysisSummary(
      analysis.summary?.toJson(),
      overrides: analysis.overrides?.toJson(),
    );
    if (_tempoMetadataCache.length >= _maxCachedTempoMetadata) {
      _tempoMetadataCache.remove(_tempoMetadataCache.keys.first);
    }
    _tempoMetadataCache[analysis] = tempo;
    return tempo;
  }

  int _defaultTimelineStartAfter(MixClip outgoing, Track incomingTrack) {
    final trim = widget.trimRangeFor(incomingTrack);
    final fallbackStartMs = outgoing.timelineEndMs;
    final incomingDefaultClip = TimelineClip.clamped(
      id: 'clip_${incomingTrack.id}',
      trackId: incomingTrack.id,
      sourceDurationMs: incomingTrack.durationMs,
      sourceStartMs: trim.startOffsetMs,
      sourceEndMs: trim.endOffsetMs,
      timelineStartMs: fallbackStartMs,
    );
    return defaultDownbeatLockedTransitionStartMs(
      outgoingTimelineStartMs: outgoing.timelineStartMs,
      outgoingTimelineEndMs: outgoing.timelineEndMs,
      outgoingSourceStartMs: outgoing.placement.sourceStartMs,
      outgoingSelectedDurationMs: outgoing.selectedDurationMs,
      outgoingTempo: outgoing.tempo,
      outgoingBaseRate: outgoing.playbackRate,
      incomingSourceStartMs: incomingDefaultClip.sourceStartMs,
      incomingSelectedDurationMs: incomingDefaultClip.selectedDurationMs,
      incomingTempo: _tempoForTrack(incomingTrack),
      snapMode: _snapMode.beatSnapMode,
      fallbackStartMs: fallbackStartMs,
    );
  }

  _WaveformSlice _waveformSliceForClip(
    Track track,
    TimelineClip clip,
    String laneId,
    bool preview,
    double width,
    double devicePixelRatio,
    double viewportPixelsPerSecond,
    int activeSampleCap,
  ) {
    final sampleCount = _targetWaveformSamples(
      clip,
      width,
      devicePixelRatio,
      viewportPixelsPerSecond,
      activeSampleCap,
    );
    final selectedDurationMs = math.max(1, clip.selectedDurationMs);
    final sourceSampleCount = (sampleCount *
            math.max(selectedDurationMs, track.durationMs) /
            selectedDurationMs)
        .ceil()
        .clamp(_minWaveformSamples, _maxWaveformSamples)
        .toInt();
    final cacheKey = _WaveformSliceCacheKey(
      trackId: track.playbackTrackId ?? track.id,
      analysisRevision: _analysisRevisionFor(track),
      sourceStartMs: clip.sourceStartMs,
      sourceEndMs: clip.sourceEndMs,
      sampleCount: sampleCount,
    );
    if (preview) {
      final generation = _previewGenerations[laneId];
      final cachedPreview = _previewWaveformSlices.remove(laneId);
      if (cachedPreview != null &&
          generation != null &&
          cachedPreview.generation == generation &&
          cachedPreview.cacheKey == cacheKey) {
        _markWaveformSliceActive(laneId, cachedPreview.slice);
        _previewWaveformSlices[laneId] = cachedPreview;
        _enforceWaveformCacheBudget();
        return cachedPreview.slice;
      }
      final committed = _waveformSliceCache.remove(cacheKey);
      if (committed != null) {
        _markWaveformSliceActive(laneId, committed);
        _waveformSliceCache[cacheKey] = committed;
        _enforceWaveformCacheBudget();
        return committed;
      }
    } else {
      final cached = _waveformSliceCache.remove(cacheKey);
      if (cached != null) {
        _markWaveformSliceActive(laneId, cached);
        _waveformSliceCache[cacheKey] = cached;
        _enforceWaveformCacheBudget();
        return cached;
      }
    }

    final waveformFor = widget.waveformFor;
    final source = waveformFor == null
        ? richWaveformForTrack(track, sampleCount: sourceSampleCount)
        : waveformFor(track, sourceSampleCount);
    final waveform = source.sliced(
      sourceStartMs: clip.sourceStartMs,
      sourceEndMs: clip.sourceEndMs,
      targetSampleCount: sampleCount,
    );
    final slice = _WaveformSlice(
      waveform: waveform,
      peaks: waveform.peaks,
      onPaintCacheSizeChanged: _scheduleWaveformCacheBudgetEnforcement,
    );
    _markWaveformSliceActive(laneId, slice);
    if (preview) {
      final generation = _previewGenerations[laneId];
      if (generation != null) {
        _previewWaveformSlices[laneId] = _PreviewWaveformSlice(
          generation: generation,
          cacheKey: cacheKey,
          slice: slice,
        );
        _enforceWaveformCacheBudget();
      }
    } else {
      _cacheWaveformSlice(cacheKey, slice);
    }
    return slice;
  }

  Object _analysisRevisionFor(Track track) {
    final analysis = track.analysis;
    if (analysis == null) return 'none';
    final summary = analysis.summary;
    final waveform = summary?.waveform;
    final peaks = waveform?.peaks ?? const <double>[];
    return Object.hash(
      analysis.status,
      analysis.updatedAt?.microsecondsSinceEpoch,
      peaks.length,
      peaks.isEmpty ? null : peaks.first,
      peaks.isEmpty ? null : peaks.last,
      summary?.beatGrid?.beatsMs.length,
      summary?.downbeats?.positionsMs.length,
      summary?.transients?.strongestMs.length,
      analysis.overrides?.toJson().toString(),
    );
  }

  int _targetWaveformSamples(
    TimelineClip clip,
    double clipWidth,
    double devicePixelRatio,
    double viewportPixelsPerSecond,
    int activeSampleCap,
  ) {
    if (!clipWidth.isFinite || clipWidth <= 0) return _minWaveformSamples;
    final pixelRatio = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    final screenSamples =
        clipWidth * pixelRatio / _waveformPhysicalPixelsPerSample;
    final zoomSamples = clip.selectedDurationMs /
        1000 *
        viewportPixelsPerSecond /
        TimelineWaveformData.maxUsefulFrameSpacingPx;
    final target = math
        .max(screenSamples, zoomSamples)
        .round()
        .clamp(_minWaveformSamples, _maxWaveformSamples)
        .toInt();
    return math.min(_waveformSampleBucket(target), activeSampleCap).toInt();
  }

  int _waveformSampleBucket(int target) {
    var bucket = _minWaveformSamples;
    while (bucket < target && bucket < _maxWaveformSamples) {
      bucket *= 2;
    }
    return bucket.clamp(_minWaveformSamples, _maxWaveformSamples).toInt();
  }

  void _cacheWaveformSlice(
    _WaveformSliceCacheKey cacheKey,
    _WaveformSlice slice,
  ) {
    if (slice.waveform.frames.length > _maxCachedWaveformFrames ||
        slice.estimatedBytes > _maxAggregateWaveformBytes) {
      return;
    }
    _waveformSliceCache.remove(cacheKey);
    _waveformSliceCache[cacheKey] = slice;
    _enforceWaveformCacheBudget();
  }

  void _markWaveformSliceActive(String laneId, _WaveformSlice slice) {
    final previous = _activeWaveformSlices[laneId];
    _activeWaveformSlices[laneId] = slice;
    if (previous != null && !identical(previous, slice)) {
      _queueWaveformGeometryRelease(previous);
    }
  }

  void _attachActiveWaveformSlice(String laneId, _WaveformSlice slice) {
    _markWaveformSliceActive(laneId, slice);
    _scheduleWaveformCacheBudgetEnforcement();
  }

  void _detachActiveWaveformSlice(String laneId, _WaveformSlice slice) {
    if (identical(_activeWaveformSlices[laneId], slice)) {
      _activeWaveformSlices.remove(laneId);
      _scheduleWaveformCacheBudgetEnforcement();
    }
  }

  void _scheduleWaveformCacheBudgetEnforcement() {
    if (!mounted || _waveformBudgetEnforcementScheduled) return;
    _waveformBudgetEnforcementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _releasePendingWaveformGeometry();
        _enforceWaveformCacheBudget(allowActiveGeometryTrim: true);
        _releasePendingWaveformGeometry();
      }
      _waveformBudgetEnforcementScheduled = false;
    });
  }

  void _enforceWaveformCacheBudget({bool allowActiveGeometryTrim = false}) {
    final activeSlices = HashSet<_WaveformSlice>.identity()
      ..addAll(_activeWaveformSlices.values);

    while (true) {
      final usage = _waveformCacheUsage();
      if (usage.frames <= _maxCachedWaveformFrames &&
          usage.bytes <= _maxAggregateWaveformBytes) {
        return;
      }
      if (_evictOldestInactiveWaveformSlice(activeSlices)) {
        continue;
      }
      if (allowActiveGeometryTrim &&
          usage.bytes > _maxAggregateWaveformBytes &&
          _trimActiveWaveformGeometry(
            activeSlices,
            usage.bytes - _maxAggregateWaveformBytes,
          )) {
        continue;
      }
      if (allowActiveGeometryTrim) {
        assert(
          usage.frames <= _maxCachedWaveformFrames &&
              usage.bytes <= _maxAggregateWaveformBytes,
          'Mounted waveform allocations exceeded their pre-build budget',
        );
      }
      return;
    }
  }

  ({int frames, int bytes}) _waveformCacheUsage() {
    final seen = HashSet<_WaveformSlice>.identity();
    var frames = 0;
    var bytes = 0;

    void include(_WaveformSlice slice) {
      if (!seen.add(slice)) return;
      frames += slice.waveform.frames.length;
      bytes += slice.estimatedBytes;
    }

    for (final slice in _activeWaveformSlices.values) {
      include(slice);
    }
    for (final slice in _waveformSliceCache.values) {
      include(slice);
    }
    for (final preview in _previewWaveformSlices.values) {
      include(preview.slice);
    }
    return (frames: frames, bytes: bytes);
  }

  bool _evictOldestInactiveWaveformSlice(
    Set<_WaveformSlice> activeSlices,
  ) {
    for (final entry in _waveformSliceCache.entries.toList(growable: false)) {
      if (activeSlices.contains(entry.value)) continue;
      _waveformSliceCache.remove(entry.key);
      _queueWaveformGeometryRelease(entry.value);
      return true;
    }
    for (final entry
        in _previewWaveformSlices.entries.toList(growable: false)) {
      if (activeSlices.contains(entry.value.slice)) continue;
      _previewWaveformSlices.remove(entry.key);
      _queueWaveformGeometryRelease(entry.value.slice);
      return true;
    }
    return false;
  }

  void _queueWaveformGeometryRelease(_WaveformSlice slice) {
    _pendingWaveformGeometryReleases.add(slice);
    _scheduleWaveformCacheBudgetEnforcement();
  }

  void _releasePendingWaveformGeometry() {
    for (final slice
        in _pendingWaveformGeometryReleases.toList(growable: false)) {
      final stillRetained = _activeWaveformSlices.values.any(
            (value) => identical(value, slice),
          ) ||
          _waveformSliceCache.values.any((value) => identical(value, slice)) ||
          _previewWaveformSlices.values.any(
            (value) => identical(value.slice, slice),
          );
      if (!stillRetained) {
        slice.paintCache.clearRetainedGeometry();
      }
    }
    _pendingWaveformGeometryReleases.clear();
  }

  bool _trimActiveWaveformGeometry(
    Set<_WaveformSlice> activeSlices,
    int bytesToFree,
  ) {
    final caches = HashSet<TimelineWaveformPaintCache>.identity();
    for (final slice in activeSlices) {
      caches.add(slice.paintCache);
    }
    final ordered = caches.toList(growable: false)
      ..sort(
        (first, second) =>
            second.estimatedByteSize.compareTo(first.estimatedByteSize),
      );
    var remaining = bytesToFree;
    var freedAny = false;
    for (final cache in ordered) {
      if (remaining <= 0) break;
      final target = math.max(
        TimelineWaveformPaintCache.minimumRetainedByteSize,
        cache.estimatedByteSize - remaining,
      );
      final freed = cache.trimRetainedGeometryToBytes(target);
      if (freed <= 0) continue;
      remaining -= freed;
      freedAny = true;
    }
    return freedAny;
  }

  double _effectiveMaxPixelsPerSecond(Map<Track, MixClip> placed) {
    var maxPixelsPerSecond = TimelineViewport.maxPixelsPerSecond;
    for (final entry in placed.entries) {
      final clip = entry.value;
      final available = waveformCoveredSampleCountForTrack(
        entry.key,
        sourceStartMs: clip.placement.sourceStartMs,
        sourceEndMs: clip.placement.sourceEndMs,
      );
      if (available == null || available <= 0 || clip.timelineDurationMs <= 0) {
        continue;
      }
      maxPixelsPerSecond = math.min(
        maxPixelsPerSecond,
        waveformMaxUsefulPixelsPerSecond(
          realFrameCount: available,
          timelineDurationMs: clip.timelineDurationMs,
        ),
      );
    }
    return math.max(TimelineViewport.minPixelsPerSecond, maxPixelsPerSecond);
  }

  MixClip? _dominantClipAt(List<MixClip> clips, int timelineMs) {
    final active = clips
        .where((clip) => clip.isActiveAt(timelineMs))
        .toList(growable: false);
    if (active.isEmpty) return null;
    return active.reduce((current, candidate) {
      final currentGain = current.gainAt(timelineMs);
      final candidateGain = candidate.gainAt(timelineMs);
      if (candidateGain > currentGain) return candidate;
      if (candidateGain < currentGain) return current;
      return candidate.timelineStartMs >= current.timelineStartMs
          ? candidate
          : current;
    });
  }

  String _playheadTimeLabel(int playheadMs, MixClip? clip) {
    if (clip == null) return 'Mix ${_formatClock(playheadMs)}';
    final localMs = clip.sourcePositionAt(playheadMs);
    return 'Mix ${_formatClock(playheadMs)} · Song ${_formatClock(localMs)}';
  }

  Widget _playheadBadge(BuildContext context, String label) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 148),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.inverseSurface.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onInverseSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  bool _clipMatchesTrack(MixClip clip, Track track) {
    final clipQueueItemId = clip.queueItemId;
    if (track.queueItemId.isNotEmpty &&
        clipQueueItemId != null &&
        clipQueueItemId.isNotEmpty) {
      return clipQueueItemId == track.queueItemId;
    }

    final playbackTrackId = track.playbackTrackId;
    if (playbackTrackId != null && playbackTrackId.isNotEmpty) {
      return clip.trackId == playbackTrackId;
    }

    final ids = <String>{
      track.id,
      track.queueItemId,
      if (track.sourceCandidateId != null) track.sourceCandidateId!,
      if (track.sourceUrl != null) track.sourceUrl!,
    };
    return ids.contains(clip.trackId) || ids.contains(clip.queueItemId);
  }

  List<Widget> _buildOverlapBands(
    BuildContext context,
    List<MixClip> clips,
    TimelineViewport viewport,
    double paneWidth,
  ) {
    final bands = <Widget>[];
    for (var i = 0; i < clips.length; i++) {
      for (var j = i + 1; j < clips.length; j++) {
        final first = clips[i];
        final second = clips[j];
        final overlapStart = math.max(
          first.timelineStartMs,
          second.timelineStartMs,
        );
        final overlapEnd = math.min(first.timelineEndMs, second.timelineEndMs);
        if (overlapEnd <= overlapStart) continue;
        final overlapDurationMs = overlapEnd - overlapStart;

        final overlapStartX = viewport.msToX(overlapStart);
        final overlapEndX = viewport.msToX(overlapEnd);
        final visibleStartX = overlapStartX.clamp(0.0, paneWidth).toDouble();
        final visibleEndX = overlapEndX.clamp(0.0, paneWidth).toDouble();
        final left = StackedWaveformTimeline.railWidth + visibleStartX;
        final minBandWidth = math.min(2.0, paneWidth);
        final width = (visibleEndX - visibleStartX).clamp(
          minBandWidth,
          paneWidth,
        );
        final midpointMs = overlapStart + (overlapDurationMs ~/ 2);
        final averageGain =
            ((first.gainAt(midpointMs) + second.gainAt(midpointMs)) / 2)
                .clamp(0.0, 1.0)
                .toDouble();
        final diagnostics = diagnoseTransition(
          first,
          second,
          snapMode: _snapMode.beatSnapMode,
        );
        bands.add(
          Positioned(
            key: bands.isEmpty
                ? const ValueKey('transition_window')
                : ValueKey(
                    'timeline_overlap_band_'
                    '${_mixClipLaneId(first)}_'
                    '${_mixClipLaneId(second)}',
                  ),
            left: left,
            top: 0,
            bottom: 0,
            width: width,
            child: _transitionBand(
              context,
              overlapDurationMs,
              averageGain,
              diagnostics,
            ),
          ),
        );
      }
    }
    return bands;
  }

  double _clipDisplayGain(MixClip clip) {
    if (clip.selectedDurationMs <= 0) return 0;
    final midpointMs = clip.timelineStartMs +
        ((clip.timelineEndMs - clip.timelineStartMs) ~/ 2);
    return clip.gainAt(midpointMs).clamp(0.0, 1.0).toDouble();
  }

  Widget _buildLane(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
    double paneWidth,
    int activeSampleCap,
  ) {
    final left = viewport.msToX(lane.timelineStartMs);
    final width = (viewport.msToX(lane.timelineEndMs) -
            viewport.msToX(lane.timelineStartMs))
        .clamp(8.0, double.infinity);
    return SizedBox(
      width: double.infinity,
      height: lane.height,
      child: ClipRect(
        child: Stack(
          children: [
            _buildLaneSpan(context, lane, viewport),
            Positioned(
              left: left,
              top: 8,
              bottom: 8,
              width: width,
              child: _buildClipSurface(
                context,
                lane,
                viewport,
                width,
                left,
                paneWidth,
                activeSampleCap,
              ),
            ),
            _buildLaneIdentity(
              context,
              lane,
              viewport,
              paneWidth,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLaneSpan(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
  ) {
    final left = viewport.msToX(0);
    final width = (viewport.msToX(lane.timelineEndMs) - left)
        .clamp(0.0, double.infinity)
        .toDouble();
    if (width <= 0) return const SizedBox.shrink();

    return Positioned(
      key: ValueKey('timeline_lane_span_${lane.laneId}'),
      left: left,
      top: 8,
      bottom: 8,
      width: width,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: lane.accent.withValues(
              alpha: lane.role == LaneRole.current ? 0.035 : 0.022,
            ),
            border: Border(
              bottom: BorderSide(color: lane.accent.withValues(alpha: 0.10)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLaneIdentity(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
    double paneWidth,
  ) {
    const leftInset = 8.0;
    const topInset = 12.0;
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final minVisibleWidth =
        TimelineLaneHeader.minimumVisibleWidthForTextScale(textScale);
    final maxWidth = math.min(
      260.0,
      math.max(0.0, paneWidth - 16),
    );
    final laneEndX = viewport.msToX(lane.timelineEndMs);
    final visibleEndX = laneEndX.clamp(0.0, paneWidth).toDouble();
    final width = (visibleEndX - leftInset).clamp(0.0, maxWidth).toDouble();
    if (width < minVisibleWidth) return const SizedBox.shrink();

    return Positioned(
      left: leftInset,
      top: topInset,
      width: width,
      child: IgnorePointer(
        child: ClipRect(
          child: SizedBox(
            width: width,
            child: TimelineLaneHeader(
              key: ValueKey('timeline_lane_header_${lane.laneId}'),
              track: lane.track,
              role: lane.role,
              statusLabel: lane.status,
              accent: lane.accent,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildClipSurface(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
    double clipWidth,
    double clipLeft,
    double paneWidth,
    int activeSampleCap,
  ) {
    final laneId = lane.laneId;
    final selected = _isLaneSelected(laneId);
    final editBusy = _isTimelineEditBusy(lane.track);
    final canMove = widget.onTimelineStartChanged != null && !editBusy;
    final selectedTrim = TrimRange.full(lane.clip.selectedDurationMs);
    final waveformSlice = _waveformSliceForClip(
      lane.track,
      lane.clip,
      laneId,
      _previewClips[laneId] == lane.clip,
      clipWidth,
      MediaQuery.devicePixelRatioOf(context),
      viewport.pixelsPerSecond,
      activeSampleCap,
    );
    final visibleStartPx = (-clipLeft).clamp(0.0, clipWidth).toDouble();
    final visibleEndPx =
        (paneWidth - clipLeft).clamp(0.0, clipWidth).toDouble();
    final paintWindow = _waveformPaintWindow(
      visibleStartPx: visibleStartPx,
      visibleEndPx: visibleEndPx,
      clipWidth: clipWidth,
    );
    final body = TimelineClipWidget(
      track: lane.track,
      laneId: laneId,
      peaks: waveformSlice.peaks,
      waveform: waveformSlice.waveform,
      mixClip: lane.mixClip,
      mappingRevision: lane.mixClip.rateAutomation,
      paintCache: waveformSlice.paintCache,
      viewportPixelsPerMs: viewport.pixelsPerSecond / 1000,
      viewportOriginMs: viewport.offsetMs,
      visibleStartFraction: paintWindow.startFraction,
      visibleEndFraction: paintWindow.endFraction,
      trim: selectedTrim,
      role: lane.role,
      accent: lane.accent,
      stateLabel: lane.status,
      snapMarkerCount: _snapMode.markerCount,
      gain: _clipDisplayGain(lane.mixClip),
      showGainBadge: widget.timelineModel?.clips.isNotEmpty ?? false,
      showInLaneChip: false,
    );

    return _ActiveWaveformSliceLease(
      laneId: laneId,
      slice: waveformSlice,
      onAttach: _attachActiveWaveformSlice,
      onDetach: _detachActiveWaveformSlice,
      child: Stack(
        children: [
          Positioned.fill(
            child: Semantics(
              key: ValueKey('timeline_clip_semantics_$laneId'),
              label: editBusy
                  ? 'Saving ${lane.track.title} timeline edit'
                  : widget.onTimelineStartChanged == null
                      ? 'Select ${lane.track.title} in timeline'
                      : 'Move ${lane.track.title} in timeline',
              container: true,
              button: true,
              onTap: () => _selectLane(laneId),
              onIncrease:
                  canMove ? () => _moveClipFromSemantics(lane, 1) : null,
              onDecrease:
                  canMove ? () => _moveClipFromSemantics(lane, -1) : null,
              child: GestureDetector(
                key: ValueKey('timeline_clip_body_drag_$laneId'),
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: () => _selectLane(laneId),
                onHorizontalDragStart: canMove
                    ? (_) => _beginClipDrag(lane)
                    : editBusy
                        ? (_) {}
                        : null,
                onHorizontalDragUpdate: canMove
                    ? (details) => _updateClipDrag(
                          lane,
                          viewport,
                          details.primaryDelta ?? 0,
                          useIncrementalDelta: true,
                        )
                    : editBusy
                        ? (_) {}
                        : null,
                onHorizontalDragEnd: canMove
                    ? (_) => _finishClipDrag(lane)
                    : editBusy
                        ? (_) {}
                        : null,
                onHorizontalDragCancel: canMove
                    ? () => _cancelClipDrag(laneId)
                    : editBusy
                        ? () {}
                        : null,
                onLongPressStart:
                    selected && canMove ? (_) => _beginClipDrag(lane) : null,
                onLongPressMoveUpdate: selected && canMove
                    ? (details) => _updateClipDrag(
                          lane,
                          viewport,
                          details.offsetFromOrigin.dx,
                        )
                    : null,
                onLongPressEnd:
                    selected && canMove ? (_) => _finishClipDrag(lane) : null,
                onLongPressCancel:
                    selected && canMove ? () => _cancelClipDrag(laneId) : null,
                child: body,
              ),
            ),
          ),
          if (selected) ...[
            _trimHandle(
              key: ValueKey('timeline_trim_start_$laneId'),
              alignStart: true,
              accent: lane.accent,
              enabled: widget.onTrimStartChanged != null && !editBusy,
              onDragStart: () => _beginTrimDrag(lane, _TrimEdge.start),
              onDragUpdate: (deltaPx) =>
                  _updateTrimDrag(lane, viewport, deltaPx),
              onDragEnd: () => _finishTrimDrag(lane),
              onDragCancel: () => _cancelTrimDrag(laneId),
            ),
            _trimHandle(
              key: ValueKey('timeline_trim_end_$laneId'),
              alignStart: false,
              accent: lane.accent,
              enabled: widget.onTrimEndChanged != null && !editBusy,
              onDragStart: () => _beginTrimDrag(lane, _TrimEdge.end),
              onDragUpdate: (deltaPx) =>
                  _updateTrimDrag(lane, viewport, deltaPx),
              onDragEnd: () => _finishTrimDrag(lane),
              onDragCancel: () => _cancelTrimDrag(laneId),
            ),
          ],
        ],
      ),
    );
  }

  ({double startFraction, double endFraction}) _waveformPaintWindow({
    required double visibleStartPx,
    required double visibleEndPx,
    required double clipWidth,
  }) {
    if (clipWidth <= 0) return (startFraction: 0, endFraction: 1);
    if (visibleEndPx <= visibleStartPx) {
      final edge = visibleStartPx >= clipWidth ? 1.0 : 0.0;
      return (startFraction: edge, endFraction: edge);
    }
    final startPx =
        (((visibleStartPx - _waveformPaintWindowPx) / _waveformPaintWindowPx)
                    .floor() *
                _waveformPaintWindowPx)
            .clamp(0.0, clipWidth)
            .toDouble();
    final endPx =
        (((visibleEndPx + _waveformPaintWindowPx) / _waveformPaintWindowPx)
                    .ceil() *
                _waveformPaintWindowPx)
            .clamp(startPx, clipWidth)
            .toDouble();
    return (
      startFraction: startPx / clipWidth,
      endFraction: endPx / clipWidth,
    );
  }

  void _beginClipDrag(_LaneModel lane) {
    if (_isTimelineEditBusy(lane.track)) return;
    final laneId = lane.laneId;
    setState(() {
      _selectedTrackId = laneId;
      _activeClipDragTrackId = laneId;
      _activeClipDragStartClip = lane.clip;
      _activeClipDragGeneration = _claimPreview(laneId);
      _storePreviewClip(lane.track, lane.clip);
    });
  }

  void _updateClipDrag(
    _LaneModel lane,
    TimelineViewport viewport,
    double deltaPx, {
    bool useIncrementalDelta = false,
  }) {
    if (_activeClipDragTrackId != lane.laneId) return;
    final baseClip = useIncrementalDelta
        ? (_previewClipFor(lane.track, lane.clip) ?? lane.clip)
        : _activeClipDragStartClip;
    if (baseClip == null) return;
    final deltaMs = _timelineDeltaMs(viewport, deltaPx);
    final snappedStart = snapTimelineStartMsToMusicalGrid(
      requestedStartMs: math.max(0, baseClip.timelineStartMs + deltaMs),
      mode: _snapMode,
      clip: baseClip,
      tempo: lane.mixClip.tempo,
    );
    if (snappedStart == baseClip.timelineStartMs) return;
    setState(() {
      _storePreviewClip(lane.track, baseClip.withTimelineStartMs(snappedStart));
    });
  }

  void _moveClipFromSemantics(
    _LaneModel lane,
    int direction,
  ) {
    final callback = widget.onTimelineStartChanged;
    if (callback == null || direction == 0 || _isTimelineEditBusy(lane.track)) {
      return;
    }
    final intervalMs = _snapGridFor(_snapMode, lane.mixClip.tempo).intervalMs ??
        _fallbackSnapIntervalMs(_snapMode);
    final requestedStartMs = math
        .max(
          0,
          lane.clip.timelineStartMs + direction * math.max(1, intervalMs),
        )
        .toInt();
    final nextStartMs = snapTimelineStartMsToMusicalGrid(
      requestedStartMs: requestedStartMs,
      mode: _snapMode,
      clip: lane.clip,
      tempo: lane.mixClip.tempo,
    );
    if (nextStartMs == lane.clip.timelineStartMs) return;
    _startTimelineEdit(
      track: lane.track,
      callback: callback,
      valueMs: nextStartMs,
      kind: _TimelineEditKind.placement,
    );
  }

  void _finishClipDrag(_LaneModel lane) {
    final laneId = lane.laneId;
    if (_activeClipDragTrackId != laneId) return;
    final preview = _previewClipFor(lane.track, lane.clip) ?? lane.clip;
    final startClip = _activeClipDragStartClip;
    final generation = _activeClipDragGeneration;
    final changed = startClip == null ||
        preview.timelineStartMs != startClip.timelineStartMs;
    setState(() {
      _activeClipDragTrackId = null;
      _activeClipDragStartClip = null;
      _activeClipDragGeneration = null;
      if (!changed) {
        _removePreviewClip(
          laneId,
          generation: generation,
        );
      }
    });
    if (!changed) return;
    _startTimelineEdit(
      track: lane.track,
      laneId: laneId,
      callback: widget.onTimelineStartChanged,
      valueMs: preview.timelineStartMs,
      previewGeneration: generation,
      kind: _TimelineEditKind.placement,
    );
  }

  void _startTimelineEdit({
    required Track track,
    String? laneId,
    required TimelineClipEditCallback? callback,
    required int valueMs,
    required _TimelineEditKind kind,
    int? previewGeneration,
  }) {
    final resolvedLaneId = laneId ?? _timelineLaneId(track);
    if (callback == null ||
        _timelineEditTransactions.containsKey(resolvedLaneId)) {
      if (mounted && previewGeneration != null) {
        setState(
          () => _removePreviewClip(
            resolvedLaneId,
            generation: previewGeneration,
          ),
        );
      }
      return;
    }

    final transaction = _TimelineEditTransaction(
      epoch: _timelineEditEpoch,
      laneId: resolvedLaneId,
      track: track,
      operation: () => callback(track, valueMs),
      previewGeneration: previewGeneration,
      kind: kind,
    );
    setState(() => _timelineEditTransactions[resolvedLaneId] = transaction);
    unawaited(_runTimelineEdit(resolvedLaneId, transaction));
  }

  Future<void> _runTimelineEdit(
    String laneId,
    _TimelineEditTransaction transaction,
  ) async {
    var succeeded = false;
    try {
      await transaction.operation();
      succeeded = true;
    } catch (error, stackTrace) {
      _reportTimelineEditError(transaction, error, stackTrace);
    }

    if (!mounted ||
        transaction.epoch != _timelineEditEpoch ||
        !identical(_timelineEditTransactions[laneId], transaction)) {
      return;
    }

    setState(() {
      _timelineEditTransactions.remove(laneId);
      if (succeeded &&
          (transaction.kind == _TimelineEditKind.trimStart ||
              transaction.kind == _TimelineEditKind.trimEnd)) {
        _promotePreviewWaveformSlice(
          transaction.laneId,
          transaction.previewGeneration,
        );
      }
      _removePreviewClip(
        transaction.laneId,
        generation: transaction.previewGeneration,
      );
    });
  }

  void _reportTimelineEditError(
    _TimelineEditTransaction transaction,
    Object error,
    StackTrace stackTrace,
  ) {
    final operation = switch (transaction.kind) {
      _TimelineEditKind.placement => 'timeline placement',
      _TimelineEditKind.trimStart => 'trim start',
      _TimelineEditKind.trimEnd => 'trim end',
      _TimelineEditKind.pitchMode => 'pitch mode',
    };
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Open Music Player timeline',
        context: ErrorDescription(
          'while saving the $operation for ${transaction.track.title}',
        ),
      ),
    );
  }

  bool _isTimelineEditBusy(Track track) =>
      _timelineEditTransactions.containsKey(_timelineLaneId(track));

  void _cancelClipDrag(String trackId) {
    if (_activeClipDragTrackId != trackId) return;
    final generation = _activeClipDragGeneration;
    setState(() {
      _removePreviewClip(trackId, generation: generation);
      _activeClipDragTrackId = null;
      _activeClipDragStartClip = null;
      _activeClipDragGeneration = null;
    });
  }

  void _beginTrimDrag(_LaneModel lane, _TrimEdge edge) {
    if (_isTimelineEditBusy(lane.track)) return;
    final laneId = lane.laneId;
    setState(() {
      _selectedTrackId = laneId;
      _activeTrimTrackId = laneId;
      _activeTrimEdge = edge;
      _activeTrimStartClip = lane.clip;
      _activeTrimGeneration = _claimPreview(laneId);
      _storePreviewClip(lane.track, lane.clip);
    });
  }

  void _updateTrimDrag(
    _LaneModel lane,
    TimelineViewport viewport,
    double deltaPx,
  ) {
    if (_activeTrimTrackId != lane.laneId) return;
    final edge = _activeTrimEdge;
    if (edge == null) return;
    final baseClip = _previewClipFor(lane.track, lane.clip) ?? lane.clip;
    final deltaMs = _timelineDeltaMs(viewport, deltaPx);
    if (deltaMs == 0) return;
    final requestedSourceMs = switch (edge) {
      _TrimEdge.start => baseClip.sourceStartMs + deltaMs,
      _TrimEdge.end => baseClip.sourceEndMs + deltaMs,
    };
    final snappedSourceMs = snapSourceMsToMusicalGrid(
      requestedSourceMs: requestedSourceMs,
      mode: _snapMode,
      clip: baseClip,
      tempo: lane.mixClip.tempo,
    );
    final next = switch (edge) {
      _TrimEdge.start => baseClip.withSourceRange(
          sourceStartMs: snappedSourceMs,
          sourceEndMs: baseClip.sourceEndMs,
        ),
      _TrimEdge.end => baseClip.withSourceRange(
          sourceStartMs: baseClip.sourceStartMs,
          sourceEndMs: snappedSourceMs,
        ),
    };
    if (next == baseClip) return;
    setState(() => _storePreviewClip(lane.track, next));
  }

  void _finishTrimDrag(_LaneModel lane) {
    final laneId = lane.laneId;
    if (_activeTrimTrackId != laneId) return;
    final edge = _activeTrimEdge;
    final preview = _previewClipFor(lane.track, lane.clip) ?? lane.clip;
    final startClip = _activeTrimStartClip;
    final generation = _activeTrimGeneration;
    TimelineClipEditCallback? callback;
    int? valueMs;
    _TimelineEditKind? kind;
    if (edge != null && startClip != null) {
      switch (edge) {
        case _TrimEdge.start:
          if (preview.sourceStartMs != startClip.sourceStartMs) {
            callback = widget.onTrimStartChanged;
            valueMs = preview.sourceStartMs;
            kind = _TimelineEditKind.trimStart;
          }
          break;
        case _TrimEdge.end:
          if (preview.sourceEndMs != startClip.sourceEndMs) {
            callback = widget.onTrimEndChanged;
            valueMs = preview.sourceEndMs;
            kind = _TimelineEditKind.trimEnd;
          }
          break;
      }
    }
    setState(() {
      _activeTrimTrackId = null;
      _activeTrimEdge = null;
      _activeTrimStartClip = null;
      _activeTrimGeneration = null;
      if (valueMs == null || kind == null) {
        _removePreviewClip(
          laneId,
          generation: generation,
        );
      }
    });
    if (valueMs == null || kind == null) return;
    _startTimelineEdit(
      track: lane.track,
      laneId: laneId,
      callback: callback,
      valueMs: valueMs,
      previewGeneration: generation,
      kind: kind,
    );
  }

  void _cancelTrimDrag(String trackId) {
    if (_activeTrimTrackId != trackId) return;
    final generation = _activeTrimGeneration;
    setState(() {
      _removePreviewClip(trackId, generation: generation);
      _activeTrimTrackId = null;
      _activeTrimEdge = null;
      _activeTrimStartClip = null;
      _activeTrimGeneration = null;
    });
  }

  void _selectLane(String laneId) {
    if (_selectedTrackId == laneId) return;
    setState(() => _selectedTrackId = laneId);
  }

  void _clearSelectedTrack() {
    if (_selectedTrackId == null ||
        _activeClipDragTrackId != null ||
        _activeTrimTrackId != null) {
      return;
    }
    setState(() => _selectedTrackId = null);
  }

  Widget _trimHandle({
    required Key key,
    required bool alignStart,
    required Color accent,
    required bool enabled,
    required VoidCallback onDragStart,
    required ValueChanged<double> onDragUpdate,
    required VoidCallback onDragEnd,
    required VoidCallback onDragCancel,
  }) {
    return Positioned(
      left: alignStart ? 0 : null,
      right: alignStart ? null : 0,
      top: 0,
      bottom: 0,
      width: 44,
      child: Semantics(
        label: alignStart ? 'Trim start handle' : 'Trim end handle',
        child: IgnorePointer(
          ignoring: !enabled,
          child: GestureDetector(
            key: key,
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: enabled ? (_) => onDragStart() : null,
            onHorizontalDragUpdate: enabled
                ? (details) => onDragUpdate(details.primaryDelta ?? 0)
                : null,
            onHorizontalDragEnd: enabled ? (_) => onDragEnd() : null,
            onHorizontalDragCancel: enabled ? onDragCancel : null,
            child: Align(
              alignment:
                  alignStart ? Alignment.centerLeft : Alignment.centerRight,
              child: Container(
                width: 10,
                margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: enabled ? 0.88 : 0.35),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  int _timelineDeltaMs(TimelineViewport viewport, double deltaXPx) {
    if (!deltaXPx.isFinite || deltaXPx == 0) return 0;
    return ((deltaXPx / viewport.pixelsPerSecond) * 1000).round();
  }

  _LaneModel? _selectedLaneForRegion(List<_LaneModel> lanes) {
    for (final lane in lanes) {
      final hasRuntimeTempo =
          widget.clipTempoStates.containsKey(lane.mixClip.id);
      final hasPitchFallback =
          widget.pitchFallbackClipIds.contains(lane.mixClip.id);
      if (_isLaneSelected(lane.laneId) &&
          (_hasTimelineSelectionControls(lane) ||
              !lane.mixClip.tempo.isEmpty ||
              hasRuntimeTempo ||
              hasPitchFallback)) {
        return lane;
      }
    }
    return null;
  }

  bool _hasTimelineSelectionControls(_LaneModel lane) {
    final movable =
        lane.role == LaneRole.upcoming || lane.role == LaneRole.collapsed;
    return widget.onPitchModeChanged != null ||
        widget.onEditAnalysis != null ||
        (movable &&
            (widget.onMoveEarlier != null || widget.onMoveLater != null));
  }

  Widget _timelineSelectionRegion(
    BuildContext context,
    _LaneModel lane,
    List<MixClip> peerClips,
    int playheadMs,
  ) {
    final theme = Theme.of(context);
    final track = lane.track;
    final laneId = lane.laneId;
    final movable =
        lane.role == LaneRole.upcoming || lane.role == LaneRole.collapsed;
    final hasControls = _hasTimelineSelectionControls(lane);
    final tempoChip = _selectedTempoChip(context, lane, playheadMs);
    final transitionHint = _selectedTransitionHint(context, lane, peerClips);
    return DecoratedBox(
      key: ValueKey('timeline_selection_region_$laneId'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tempoChip != null) tempoChip,
                  if (transitionHint != null) transitionHint,
                ],
              ),
            ),
            if (hasControls) ...[
              const SizedBox(width: 8),
              SizedBox(
                width: _selectionControlsWidth,
                child: Align(
                  alignment: Alignment.topRight,
                  child: Material(
                    key: ValueKey('timeline_selection_toolbar_$laneId'),
                    color: theme.colorScheme.surface.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onPitchModeChanged != null)
                          _pitchModeMenu(lane, _isTimelineEditBusy(track)),
                        if (widget.onEditAnalysis != null ||
                            (movable &&
                                (widget.onMoveEarlier != null ||
                                    widget.onMoveLater != null)))
                          _trackActionsMenu(track, lane, movable),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget? _selectedTempoChip(
    BuildContext context,
    _LaneModel lane,
    int playheadMs,
  ) {
    final tempo = lane.mixClip.tempo;
    final pitchFallback = _hasPitchFallback(lane.mixClip);
    final runtime = widget.clipTempoStates[lane.mixClip.id];
    final modeledSpeed = lane.mixClip.playbackRateAt(playheadMs);
    final effectiveSpeed = runtime?.effectiveSpeed ?? modeledSpeed;
    final effectiveBpm = runtime?.effectiveBpm ??
        (tempo.nativeBpm == null
            ? null
            : effectiveBpmForRate(
                nativeBpm: tempo.nativeBpm!,
                rate: effectiveSpeed,
              ));
    final showLiveTempo =
        runtime != null || (effectiveSpeed - 1).abs() >= 0.005;
    final labels = <String>[
      if (showLiveTempo && effectiveBpm != null && effectiveBpm > 0)
        'Live ${_formatBpm(effectiveBpm)} BPM',
      if ((effectiveSpeed - 1).abs() >= 0.005)
        '${effectiveSpeed.toStringAsFixed(2)}x',
      if (tempo.nativeBpm != null) '${_formatBpm(tempo.nativeBpm!)} BPM',
      if (tempo.bpmConfidence != null)
        '${(tempo.bpmConfidence!.clamp(0, 1) * 100).round()}%',
      if (_formatKey(tempo.musicalKey, tempo.camelot) != null)
        _formatKey(tempo.musicalKey, tempo.camelot)!,
      if (tempo.downbeatsMs.isNotEmpty)
        '${tempo.downbeatsMs.length} ${tempo.downbeatsMs.length == 1 ? 'downbeat' : 'downbeats'}'
      else if (tempo.nativeBpm != null)
        'No downbeat',
      if (pitchFallback) 'Pitch fallback',
    ];
    if (labels.isEmpty) return null;
    final theme = Theme.of(context);
    final warning = tempo.nativeBpm == null ||
        !tempo.hasReliableBpm ||
        tempo.downbeatsMs.isEmpty ||
        pitchFallback;
    final color = warning
        ? const Color(0xFFFF8F00)
        : theme.colorScheme.onSurface.withValues(alpha: 0.92);
    return Tooltip(
      message: labels.join(' · '),
      child: Container(
        key: ValueKey('timeline_tempo_${lane.laneId}'),
        constraints: const BoxConstraints(maxWidth: 184),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          labels.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }

  bool _hasPitchFallback(MixClip clip) =>
      widget.pitchFallbackClipIds.contains(clip.id);

  Widget _pitchModeMenu(_LaneModel lane, bool editBusy) {
    final track = lane.track;
    final clip = lane.mixClip;
    final laneId = lane.laneId;
    final followsTempo = pitchModeFollowsTempo(clip.rateAutomation.pitchMode);
    final label = followsTempo
        ? 'Pitch follows tempo'
        : 'Key lock: preserve pitch while tempo changes';
    return Semantics(
      key: ValueKey('timeline_pitch_mode_semantics_$laneId'),
      label: label,
      button: true,
      enabled: !editBusy,
      excludeSemantics: editBusy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: editBusy ? () {} : null,
        child: AbsorbPointer(
          absorbing: editBusy,
          child: PopupMenuButton<String>(
            key: ValueKey('timeline_pitch_mode_$laneId'),
            tooltip: label,
            enabled: !editBusy,
            initialValue:
                followsTempo ? pitchModeFollowTempo : pitchModePreserve,
            onSelected: (mode) => _startPitchModeEdit(track, laneId, mode),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                key: ValueKey('timeline_pitch_key_lock_$laneId'),
                value: pitchModePreserve,
                checked: !followsTempo,
                child: const Text(
                  'Key lock: preserve pitch while tempo changes',
                ),
              ),
              CheckedPopupMenuItem(
                key: ValueKey('timeline_pitch_follows_tempo_$laneId'),
                value: pitchModeFollowTempo,
                checked: followsTempo,
                child: const Text('Pitch follows tempo'),
              ),
            ],
            icon: Icon(
              followsTempo ? Icons.graphic_eq : Icons.lock_outline,
              size: 20,
              semanticLabel: label,
            ),
          ),
        ),
      ),
    );
  }

  void _startPitchModeEdit(Track track, String laneId, String pitchMode) {
    final callback = widget.onPitchModeChanged;
    if (callback == null || _timelineEditTransactions.containsKey(laneId)) {
      return;
    }

    final transaction = _TimelineEditTransaction(
      epoch: _timelineEditEpoch,
      laneId: laneId,
      track: track,
      operation: () => callback(track, pitchMode),
      previewGeneration: null,
      kind: _TimelineEditKind.pitchMode,
    );
    setState(() => _timelineEditTransactions[laneId] = transaction);
    unawaited(_runTimelineEdit(laneId, transaction));
  }

  Widget _trackActionsMenu(Track track, _LaneModel lane, bool movable) {
    final laneId = lane.laneId;
    return PopupMenuButton<_TimelineTrackAction>(
      key: ValueKey('timeline_track_actions_$laneId'),
      tooltip: 'Track actions for ${track.title}',
      onSelected: (action) {
        switch (action) {
          case _TimelineTrackAction.correctAnalysis:
            widget.onEditAnalysis?.call(
              track,
              initialFirstDownbeatMs: _analysisAnchorForLane(
                lane,
                _resolvedPlayheadMs(_livePlayheadMs.value),
              ),
            );
            break;
          case _TimelineTrackAction.moveEarlierInQueue:
            widget.onMoveEarlier?.call(track);
            break;
          case _TimelineTrackAction.moveLaterInQueue:
            widget.onMoveLater?.call(track);
            break;
        }
      },
      itemBuilder: (context) => [
        if (widget.onEditAnalysis != null)
          PopupMenuItem(
            key: ValueKey('timeline_correct_analysis_$laneId'),
            value: _TimelineTrackAction.correctAnalysis,
            child: const Text('Correct analysis'),
          ),
        if (movable && widget.onMoveEarlier != null)
          PopupMenuItem(
            key: ValueKey('timeline_move_earlier_$laneId'),
            value: _TimelineTrackAction.moveEarlierInQueue,
            child: const Text('Move earlier in queue'),
          ),
        if (movable && widget.onMoveLater != null)
          PopupMenuItem(
            key: ValueKey('timeline_move_later_$laneId'),
            value: _TimelineTrackAction.moveLaterInQueue,
            child: const Text('Move later in queue'),
          ),
      ],
      icon: const Icon(Icons.more_horiz, size: 20),
    );
  }

  int? _analysisAnchorForLane(_LaneModel lane, int playheadMs) {
    if (!lane.mixClip.isActiveAt(playheadMs)) return null;
    return lane.mixClip
        .sourcePositionAt(playheadMs)
        .clamp(0, lane.clip.sourceDurationMs)
        .toInt();
  }

  Widget? _selectedTransitionHint(
    BuildContext context,
    _LaneModel lane,
    List<MixClip> peerClips,
  ) {
    final diagnostics = _bestSelectedTransitionDiagnostics(lane, peerClips);
    if (diagnostics == null) return null;
    final labels = diagnostics.compactLabels.take(3).toList(growable: false);
    if (labels.isEmpty) return null;

    final theme = Theme.of(context);
    final accent = switch (diagnostics.severity) {
      TransitionDiagnosticSeverity.error => theme.colorScheme.error,
      TransitionDiagnosticSeverity.warning =>
        SoundQPlayerTheme.of(context).queuePending,
      TransitionDiagnosticSeverity.info =>
        SoundQPlayerTheme.of(context).timelineCurrent,
    };
    return Semantics(
      label:
          'Selected transition ${diagnostics.severity.name}. ${_formatClock(diagnostics.overlapDurationMs)}. ${diagnostics.semanticsLabel}',
      child: Container(
        key: ValueKey('timeline_transition_hint_${lane.laneId}'),
        constraints: const BoxConstraints(maxWidth: 250),
        margin: const EdgeInsets.fromLTRB(6, 0, 6, 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              diagnostics.hasWarnings
                  ? Icons.warning_amber_rounded
                  : Icons.sync_alt,
              size: 14,
              color: accent,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                labels.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  TransitionDiagnostics? _bestSelectedTransitionDiagnostics(
    _LaneModel lane,
    List<MixClip> peerClips,
  ) {
    final candidates = <TransitionDiagnostics>[];
    for (final clip in peerClips) {
      if (clip.id == lane.mixClip.id || clip.trackId == lane.mixClip.trackId) {
        continue;
      }
      final overlapStart = math.max(
        lane.mixClip.timelineStartMs,
        clip.timelineStartMs,
      );
      final overlapEnd = math.min(
        lane.mixClip.timelineEndMs,
        clip.timelineEndMs,
      );
      if (overlapEnd <= overlapStart) continue;
      candidates.add(
        diagnoseTransition(
          lane.mixClip,
          clip,
          snapMode: _snapMode.beatSnapMode,
        ),
      );
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final severity = _severityRank(a.severity).compareTo(
        _severityRank(b.severity),
      );
      if (severity != 0) return severity;
      return b.overlapDurationMs.compareTo(a.overlapDurationMs);
    });
    return candidates.first;
  }

  int _severityRank(TransitionDiagnosticSeverity severity) =>
      switch (severity) {
        TransitionDiagnosticSeverity.error => 0,
        TransitionDiagnosticSeverity.warning => 1,
        TransitionDiagnosticSeverity.info => 2,
      };

  String? _formatKey(String? musicalKey, String? camelot) {
    if (musicalKey != null && camelot != null) return '$musicalKey · $camelot';
    return musicalKey ?? camelot;
  }

  Widget _buildRuler(
    BuildContext context,
    TimelineViewport viewport,
    double paneWidth,
  ) {
    final theme = Theme.of(context);
    final ruler = Container(
      key: const ValueKey('timeline_ruler'),
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _RulerPainter(
                viewport: viewport,
                color: theme.dividerColor,
                textColor: theme.textTheme.labelSmall?.color ?? Colors.grey,
              ),
            ),
          ),
          _buildRulerPlayhead(viewport, paneWidth),
          Positioned(
            left: 8,
            bottom: 4,
            child: Text(
              'Mix time',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );

    if (!_hasScrubHandlers) {
      return ruler;
    }

    return GestureDetector(
      key: const ValueKey('timeline_ruler_scrub_surface'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (details) =>
          _beginScrubAt(viewport, paneWidth, details.localPosition.dx),
      onHorizontalDragUpdate: (details) =>
          _updateScrubAt(viewport, paneWidth, details.localPosition.dx),
      onHorizontalDragEnd: (_) => _endScrub(),
      onHorizontalDragCancel: _endScrub,
      child: ruler,
    );
  }

  Widget _buildRulerPlayhead(
    TimelineViewport viewport,
    double paneWidth,
  ) {
    return ValueListenableBuilder<int>(
      valueListenable: _livePlayheadMs,
      builder: (context, livePositionMs, _) {
        final playheadMs = _resolvedPlayheadMs(livePositionMs);
        final playheadPaneX = viewport.msToX(playheadMs);
        final visible = playheadPaneX.isFinite &&
            playheadPaneX >= 0 &&
            playheadPaneX <= paneWidth;
        if (!visible) return const SizedBox.shrink();
        return Positioned(
          key: const ValueKey('timeline_ruler_playhead'),
          top: 0,
          bottom: 0,
          left: StackedWaveformTimeline.railWidth + playheadPaneX,
          width: 2,
          child: const IgnorePointer(
            child: ColoredBox(color: Color(0xFFD32F2F)),
          ),
        );
      },
    );
  }

  Widget _transitionBand(
    BuildContext context,
    int durationMs,
    double gain,
    TransitionDiagnostics diagnostics,
  ) {
    final theme = Theme.of(context);
    final accent = switch (diagnostics.severity) {
      TransitionDiagnosticSeverity.error => theme.colorScheme.error,
      TransitionDiagnosticSeverity.warning =>
        SoundQPlayerTheme.of(context).queuePending,
      TransitionDiagnosticSeverity.info =>
        SoundQPlayerTheme.of(context).timelineCurrent,
    };
    final alpha = (0.025 + gain * 0.055).clamp(0.025, 0.08).toDouble();
    final labels = diagnostics.compactLabels.take(2).toList(growable: false);
    final hint =
        labels.isEmpty ? 'gain ${(gain * 100).round()}%' : labels.join(' · ');
    return Semantics(
      label:
          'Transition ${_formatClock(durationMs)}. ${diagnostics.semanticsLabel}',
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            color: accent.withValues(alpha: alpha),
            border: Border.symmetric(
              vertical: BorderSide(
                color: accent.withValues(alpha: 0.35 + gain * 0.35),
              ),
            ),
          ),
          alignment: Alignment.topCenter,
          padding: const EdgeInsets.only(top: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'transition ${_formatClock(durationMs)} · $hint',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _panViewport(TimelineViewport viewport, double deltaXPx) {
    if (!deltaXPx.isFinite || deltaXPx == 0) return;
    final baseViewport = _manualOffsetMs == null
        ? viewport
        : viewport.panToOffsetMs(_manualOffsetMs!);
    final next = baseViewport.panByPixels(deltaXPx);
    if (next.offsetMs == baseViewport.offsetMs) return;
    setState(() => _manualOffsetMs = next.offsetMs);
  }

  void _beginViewportScale(
    TimelineViewport viewport,
    ScaleStartDetails details,
  ) {
    _scaleStartViewport = viewport;
    _scaleStartZoom = _zoom;
    _scaleLastLocalFocalX = details.localFocalPoint.dx;
  }

  void _updateViewportScale(
    TimelineViewport viewport,
    ScaleUpdateDetails details,
  ) {
    if (details.pointerCount > 1 || (details.scale - 1).abs() > 0.01) {
      final startViewport = _scaleStartViewport ?? viewport;
      final startZoom = _scaleStartZoom ?? _zoom;
      final nextZoom =
          (startZoom * details.scale).clamp(_minZoom, _maxZoom).toDouble();
      final nextPps = (startViewport.pixelsPerSecond * (nextZoom / startZoom))
          .clamp(
            TimelineViewport.minPixelsPerSecond,
            _effectiveMaxPixelsPerSecond(_resolveTimelineLayout().placed),
          )
          .toDouble();
      final focalX =
          (details.localFocalPoint.dx - StackedWaveformTimeline.railWidth)
              .clamp(0.0, viewport.widthPx)
              .toDouble();
      final next = startViewport.zoomAround(
        newPixelsPerSecond: nextPps,
        focalXPx: focalX,
      );
      setState(() {
        _zoom = nextZoom;
        _manualOffsetMs = next.offsetMs;
      });
      return;
    }

    final previousFocalX = _scaleLastLocalFocalX;
    var dragDeltaPx = details.focalPointDelta.dx;
    if (previousFocalX != null) {
      final localDeltaPx = details.localFocalPoint.dx - previousFocalX;
      if (localDeltaPx != 0) {
        dragDeltaPx = localDeltaPx;
      }
    }
    _scaleLastLocalFocalX = details.localFocalPoint.dx;
    _panViewport(viewport, -dragDeltaPx);
  }

  bool get _hasScrubHandlers =>
      widget.onScrubStart != null &&
      widget.onScrubUpdate != null &&
      widget.onScrubEnd != null;

  int _timelineMsForPointer(
    TimelineViewport viewport,
    double paneWidth,
    double localX,
  ) {
    final paneX = (localX - StackedWaveformTimeline.railWidth)
        .clamp(0.0, paneWidth)
        .toDouble();
    return viewport.xToMs(paneX).clamp(0, viewport.durationMs).toInt();
  }

  void _beginScrubAt(
    TimelineViewport viewport,
    double paneWidth,
    double localX,
  ) {
    final ms = _timelineMsForPointer(viewport, paneWidth, localX);
    setState(() {
      _isScrubbing = true;
      _preserveViewportForScrub = true;
      _manualOffsetMs ??= viewport.offsetMs;
      _lastScrubMs = ms;
    });
    widget.onScrubStart?.call();
  }

  void _updateScrubAt(
    TimelineViewport viewport,
    double paneWidth,
    double localX,
  ) {
    if (!_isScrubbing) {
      _beginScrubAt(viewport, paneWidth, localX);
    }
    final effectiveViewport = _autoPanViewportNearScrubEdge(
      viewport,
      paneWidth,
      localX,
    );
    final ms = _timelineMsForPointer(effectiveViewport, paneWidth, localX);
    _lastScrubMs = ms;
    widget.onScrubUpdate?.call(ms);
  }

  void _endScrub() {
    final ms = _lastScrubMs ?? widget.playheadPositionMs;
    setState(() {
      _isScrubbing = false;
      _lastScrubMs = null;
    });
    final end = widget.onScrubEnd;
    if (end != null) {
      end(ms).whenComplete(_releaseScrubViewportLockAfterFrame);
    } else {
      _releaseScrubViewportLockAfterFrame();
    }
  }

  TimelineViewport _autoPanViewportNearScrubEdge(
    TimelineViewport viewport,
    double paneWidth,
    double localX,
  ) {
    final baseViewport = _manualOffsetMs == null
        ? viewport
        : viewport.panToOffsetMs(_manualOffsetMs!);
    final paneX = (localX - StackedWaveformTimeline.railWidth)
        .clamp(0.0, paneWidth)
        .toDouble();
    final leftDistance = paneX;
    final rightDistance = paneWidth - paneX;
    var panPx = 0.0;

    if (leftDistance < _scrubEdgeScrollZonePx) {
      final intensity =
          ((_scrubEdgeScrollZonePx - leftDistance) / _scrubEdgeScrollZonePx)
              .clamp(0.0, 1.0);
      panPx = -_scrubMaxEdgeScrollPx * intensity;
    } else if (rightDistance < _scrubEdgeScrollZonePx) {
      final intensity =
          ((_scrubEdgeScrollZonePx - rightDistance) / _scrubEdgeScrollZonePx)
              .clamp(0.0, 1.0);
      panPx = _scrubMaxEdgeScrollPx * intensity;
    }

    if (panPx == 0) return baseViewport;
    final next = baseViewport.panByPixels(panPx);
    if (next.offsetMs != baseViewport.offsetMs) {
      setState(() => _manualOffsetMs = next.offsetMs);
    }
    return next;
  }

  void _releaseScrubViewportLockAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isScrubbing) return;
      _preserveViewportForScrub = false;
    });
  }

  void _showOptionsPanel(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          void updateSnap(SnapMarkerMode mode) {
            if (!mounted) return;
            setState(() {
              _snapMode = mode;
              _resolvedLayout = null;
            });
            setSheetState(() {});
            widget.onTransitionSnapModeChanged?.call(mode.beatSnapMode);
          }

          return SafeArea(
            child: Padding(
              key: const ValueKey('timeline_options_panel'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Timeline options',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Snap markers',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in SnapMarkerMode.values)
                        ChoiceChip(
                          key: ValueKey('timeline_snap_${mode.name}'),
                          label: Text(mode.label),
                          selected: _snapMode == mode,
                          onSelected: (_) => updateSnap(mode),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Draws second/`:` tick marks along the ruler so the shared mix-time scale is
/// legible above the lanes.
class _RulerPainter extends CustomPainter {
  final TimelineViewport viewport;
  final Color color;
  final Color textColor;

  _RulerPainter({
    required this.viewport,
    required this.color,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tick = Paint()
      ..color = color
      ..strokeWidth = 1;
    final majorStepMs = _majorStepMsFor(viewport.pixelsPerSecond);
    final minorStepMs = math.max(5000, majorStepMs ~/ 4);
    final firstTickMs = (viewport.offsetMs ~/ minorStepMs) * minorStepMs;
    final lastTickMs = (viewport.offsetMs + viewport.visibleDurationMs).clamp(
      0,
      viewport.durationMs,
    );
    var lastLabelRight = -double.infinity;
    for (var ms = firstTickMs; ms <= lastTickMs; ms += minorStepMs) {
      final x = viewport.msToX(ms);
      if (x < 0 || x > size.width) continue;
      final major = ms % majorStepMs == 0;
      canvas.drawLine(
        Offset(x, size.height - (major ? 10 : 6)),
        Offset(x, size.height),
        tick,
      );
      if (!major) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: _formatClock(ms),
          style: TextStyle(color: textColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (x < lastLabelRight + 6) continue;
      tp.paint(canvas, Offset(x + 2, 2));
      lastLabelRight = x + 2 + tp.width;
    }
  }

  int _majorStepMsFor(double pixelsPerSecond) {
    const minLabelSpacingPx = 64.0;
    const candidates = <int>[
      15000,
      30000,
      60000,
      120000,
      300000,
      600000,
      900000,
      1800000,
      3600000,
    ];
    for (final stepMs in candidates) {
      final spacing = (stepMs / 1000) * pixelsPerSecond;
      if (spacing >= minLabelSpacingPx) return stepMs;
    }
    return candidates.last;
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.viewport != viewport ||
      old.color != color ||
      old.textColor != textColor;
}

/// Timeline-shaped loading surface: ruler + ghost lane geometry, never a
/// centred spinner. Preserves layout so the real timeline drops in without a
/// jump.
class TimelineLoadingSurface extends StatelessWidget {
  const TimelineLoadingSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return _TimelineChrome(
      key: const ValueKey('timeline_loading_surface'),
      laneHeights: const [114, 146, 114],
      laneBuilder: (i) => _ShimmerLane(),
    );
  }
}

/// Timeline-shaped empty surface: faint grid + empty lane placeholder + add
/// copy. Not a centred generic empty state.
class TimelineEmptySurface extends StatelessWidget {
  const TimelineEmptySurface({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TimelineChrome(
      key: const ValueKey('timeline_empty_surface'),
      laneHeights: const [146],
      laneBuilder: (i) => Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: theme.dividerColor,
            style: BorderStyle.solid,
          ),
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.2,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, color: theme.disabledColor),
              const SizedBox(height: 4),
              Text(
                'Empty timeline — search above to add tracks',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Timeline-shaped error surface: inline banner above the timeline geometry +
/// retry. Not a centred generic error card.
class TimelineErrorSurface extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const TimelineErrorSurface({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('timeline_error_surface'),
      children: [
        Material(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Could not load timeline: $message',
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                TextButton(
                  key: const ValueKey('timeline_error_retry'),
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _TimelineChrome(
            laneHeights: const [114, 146],
            laneBuilder: (i) => _ShimmerLane(),
          ),
        ),
      ],
    );
  }
}

/// Shared timeline scaffold (ruler strip + lane stack geometry + mock mode bar)
/// so loading / empty / error surfaces keep the same shape as the live
/// timeline.
class _TimelineChrome extends StatelessWidget {
  final List<double> laneHeights;
  final Widget Function(int index) laneBuilder;

  const _TimelineChrome({
    super.key,
    required this.laneHeights,
    required this.laneBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.4,
            ),
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Mix time',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: Column(
            children: [
              for (var i = 0; i < laneHeights.length; i++)
                SizedBox(
                  height: laneHeights[i],
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: StackedWaveformTimeline.railWidth,
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: theme.dividerColor.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: laneBuilder(i)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ShimmerLane extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

String _formatClock(int ms) {
  final totalSeconds = (ms.abs() / 1000).round();
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _formatBpm(double bpm) {
  if (bpm.roundToDouble() == bpm) return bpm.round().toString();
  return bpm.toStringAsFixed(1);
}
