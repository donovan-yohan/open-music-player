import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../core/engine/timeline_model.dart';
import '../models/timeline_clip.dart';
import '../models/timeline_viewport.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import 'timeline_clip_widget.dart';

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
  final TrimRange Function(Track) trimRangeFor;
  final TimelineClip Function(Track, TimelineClip)? clipFor;
  final void Function(Track, int)? onTimelineStartChanged;
  final void Function(Track, int)? onTrimStartChanged;
  final void Function(Track, int)? onTrimEndChanged;
  final ValueChanged<Track>? onMoveEarlier;
  final ValueChanged<Track>? onMoveLater;
  final TimelineModel? timelineModel;
  final int playheadPositionMs;
  final Stream<int>? positionMsStream;
  final VoidCallback? onScrubStart;
  final ValueChanged<int>? onScrubUpdate;
  final Future<void> Function(int globalMs)? onScrubEnd;

  const StackedWaveformTimeline({
    super.key,
    required this.previousTrack,
    required this.currentTrack,
    required this.upcomingTracks,
    required this.peaksFor,
    required this.trimRangeFor,
    this.clipFor,
    this.onTimelineStartChanged,
    this.onTrimStartChanged,
    this.onTrimEndChanged,
    this.onMoveEarlier,
    this.onMoveLater,
    this.timelineModel,
    this.playheadPositionMs = 0,
    this.positionMsStream,
    this.onScrubStart,
    this.onScrubUpdate,
    this.onScrubEnd,
  });

  /// Synthetic crossfade/transition window between adjacent clips (ms). Visual
  /// only — there is no real mixer.
  static const int transitionMs = 18000;

  /// Timeline metadata is overlaid on top of the lane so the waveform keeps the
  /// full phone width for direct manipulation.
  static const double railWidth = 0;

  static const Color currentAccent = Color(0xFFE65100); // high-contrast orange
  static const Color previousAccent = Color(0xFF607D8B);
  static const Color upcomingAccent = Color(0xFF1565C0);

  @override
  State<StackedWaveformTimeline> createState() =>
      _StackedWaveformTimelineState();
}

enum SnapMarkerMode { free, beat1, beat4, beat16 }

enum _TrimEdge { start, end }

extension on SnapMarkerMode {
  int get markerCount => switch (this) {
        SnapMarkerMode.free => 0,
        SnapMarkerMode.beat1 => 1,
        SnapMarkerMode.beat4 => 4,
        SnapMarkerMode.beat16 => 16,
      };

  int get snapMs => switch (this) {
        SnapMarkerMode.free => 1,
        SnapMarkerMode.beat1 => 500,
        SnapMarkerMode.beat4 => 2000,
        SnapMarkerMode.beat16 => 8000,
      };

  String get label => switch (this) {
        SnapMarkerMode.free => 'Free',
        SnapMarkerMode.beat1 => '1 beat',
        SnapMarkerMode.beat4 => '4 beats',
        SnapMarkerMode.beat16 => '16 beats',
      };
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
}

class _StackedWaveformTimelineState extends State<StackedWaveformTimeline> {
  static const double _minZoom = 0.5;
  static const double _maxZoom = 4.0;
  static const double _scrubEdgeScrollZonePx = 56;
  static const double _scrubMaxEdgeScrollPx = 32;

  SnapMarkerMode _snapMode = SnapMarkerMode.beat1;
  double _zoom = 1.0;
  int? _manualOffsetMs;
  String? _selectedTrackId;
  String? _activeClipDragTrackId;
  TimelineClip? _activeClipDragStartClip;
  String? _activeTrimTrackId;
  _TrimEdge? _activeTrimEdge;
  TimelineClip? _activeTrimStartClip;
  final Map<String, TimelineClip> _previewClips = {};
  TimelineViewport? _scaleStartViewport;
  double? _scaleStartZoom;
  double? _scaleLastLocalFocalX;
  bool _isScrubbing = false;
  bool _preserveViewportForScrub = false;
  int? _lastScrubMs;

  @override
  void didUpdateWidget(covariant StackedWaveformTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.currentTrack.id != widget.currentTrack.id) {
      if (_isScrubbing || _preserveViewportForScrub) {
        if (!_isScrubbing) {
          _preserveViewportForScrub = false;
        }
        return;
      }
      _manualOffsetMs = null;
      _selectedTrackId = null;
      _activeClipDragTrackId = null;
      _activeClipDragStartClip = null;
      _activeTrimTrackId = null;
      _activeTrimEdge = null;
      _activeTrimStartClip = null;
      _previewClips.clear();
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
              return StreamBuilder<int>(
                stream: widget.positionMsStream,
                initialData: widget.playheadPositionMs,
                builder: (context, snapshot) => _buildTimeline(
                  context,
                  paneWidth,
                  snapshot.data ?? widget.playheadPositionMs,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTimeline(
    BuildContext context,
    double paneWidth,
    int livePlayheadMs,
  ) {
    // --- Resolve global placement from the live engine model when available. ---
    final ordered = <Track>[
      if (widget.previousTrack != null) widget.previousTrack!,
      widget.currentTrack,
      ...widget.upcomingTracks,
    ];

    final placed = <Track, MixClip>{};
    final usedLiveClipIds = <String>{};
    var cursor = 0;
    for (final track in ordered) {
      final trim = widget.trimRangeFor(track);
      final defaultClip = TimelineClip.clamped(
        id: 'clip_${track.id}',
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
      placed[track] = liveClip == null
          ? MixClip(placement: clip)
          : _copyMixClipWithPlacement(liveClip, clip);
      // Next clip overlaps the tail by one transition window. A zero-duration
      // clip has timelineEndMs == timelineStartMs, so the naive lower bound
      // (start + 1) can exceed the upper bound and invert the clamp; cap the
      // lower bound at the clip end.
      final lower = math.min(clip.timelineStartMs + 1, clip.timelineEndMs);
      cursor = (clip.timelineEndMs - StackedWaveformTimeline.transitionMs)
          .clamp(lower, clip.timelineEndMs);
    }

    final currentClip = placed[widget.currentTrack]!;
    final totalMs = placed.values
        .map((c) => c.timelineEndMs)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final engineBacked = widget.positionMsStream != null ||
        (widget.timelineModel?.clips.isNotEmpty ?? false);
    final playheadMs = engineBacked
        ? livePlayheadMs.clamp(0, totalMs).toInt()
        : currentClip.timelineStartMs +
            StackedWaveformTimeline.transitionMs +
            8000;

    final fitPps = totalMs <= 0
        ? TimelineViewport.minPixelsPerSecond
        : (paneWidth / (totalMs / 1000));
    final basePps = math.max(fitPps, TimelineViewport.minPixelsPerSecond);
    final pps = (basePps * _zoom).clamp(
      TimelineViewport.minPixelsPerSecond,
      TimelineViewport.maxPixelsPerSecond,
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
    final lanes = <_LaneModel>[];
    if (widget.previousTrack != null) {
      lanes.add(
        _LaneModel(
          track: widget.previousTrack!,
          mixClip: placed[widget.previousTrack!]!,
          role: LaneRole.previous,
          accent: StackedWaveformTimeline.previousAccent,
          status: 'Played',
          height: 114,
        ),
      );
    }
    lanes.add(
      _LaneModel(
        track: widget.currentTrack,
        mixClip: currentClip,
        role: LaneRole.current,
        accent: StackedWaveformTimeline.currentAccent,
        status: 'Now playing',
        height: 146,
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
          accent: StackedWaveformTimeline.upcomingAccent,
          status: i == 0 ? 'Up next' : 'Later',
          height: collapsed ? 84 : 114,
        ),
      );
    }

    final playheadPaneX = viewport.msToX(playheadMs);
    final isPlayheadVisible = playheadPaneX.isFinite &&
        playheadPaneX >= 0 &&
        playheadPaneX <= paneWidth;

    final overlapBands = _buildOverlapBands(
      context,
      placed.values.toList(growable: false),
      viewport,
      paneWidth,
    );

    final dominantClip = _dominantClipAt(
      placed.values.toList(growable: false),
      playheadMs,
    );
    final playheadLabel = _playheadTimeLabel(playheadMs, dominantClip);
    final badgeLeft = (StackedWaveformTimeline.railWidth + playheadPaneX + 6)
        .clamp(4.0, math.max(4.0, paneWidth - 152))
        .toDouble();

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
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRuler(context, viewport, paneWidth),
              Expanded(
                child: SingleChildScrollView(
                  key: const PageStorageKey('timeline_lane_scroll'),
                  child: Column(
                    children: [
                      for (final lane in lanes)
                        _buildLane(context, lane, viewport, paneWidth),
                    ],
                  ),
                ),
              ),
            ],
          ),
          ...overlapBands,

          // Global playhead crossing the ruler + every lane. Hide it when it is
          // outside the visible pane instead of pinning it to an edge, which
          // would misleadingly imply the playhead is visible at that boundary.
          if (isPlayheadVisible)
            Positioned(
              key: const ValueKey('timeline_playhead'),
              top: 0,
              bottom: 0,
              left: StackedWaveformTimeline.railWidth + playheadPaneX,
              width: 2,
              child: Semantics(
                label: 'Mix playhead at ${_formatClock(playheadMs)}',
                child: const ColoredBox(color: Color(0xFFD32F2F)),
              ),
            ),

          if (isPlayheadVisible)
            Positioned(
              key: const ValueKey('timeline_playhead_time_badge'),
              top: 42,
              left: badgeLeft,
              child: _playheadBadge(context, playheadLabel),
            ),

          if (isPlayheadVisible && _hasScrubHandlers)
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
      _previewClips[track.id];

  void _storePreviewClip(Track track, TimelineClip clip) {
    _previewClips[track.id] = clip;
  }

  void _removePreviewClip(String trackId) {
    _previewClips.remove(trackId);
  }

  bool _isTrackSelected(String trackId) => _selectedTrackId == trackId;

  bool _isEditingTrack(String trackId) =>
      _isTrackSelected(trackId) ||
      _activeClipDragTrackId == trackId ||
      _activeTrimTrackId == trackId;

  MixClip _copyMixClipWithPlacement(MixClip clip, TimelineClip placement) =>
      MixClip(
        placement: placement,
        envelope: clip.envelope,
        audioSourceRef: clip.audioSourceRef,
        queueItemId: clip.queueItemId,
      );

  List<double> _peaksForClip(Track track, TimelineClip clip) {
    final peaks = widget.peaksFor(track);
    if (peaks.isEmpty || clip.sourceDurationMs <= 0) return peaks;

    final startFraction =
        (clip.sourceStartMs / clip.sourceDurationMs).clamp(0.0, 1.0);
    final endFraction =
        (clip.sourceEndMs / clip.sourceDurationMs).clamp(0.0, 1.0);
    final startIndex = (peaks.length * startFraction).floor();
    var endIndex = (peaks.length * endFraction).ceil();
    if (endIndex <= startIndex) {
      endIndex = startIndex + 1 < peaks.length ? startIndex + 1 : peaks.length;
    }
    if (startIndex <= 0 && endIndex >= peaks.length) return peaks;
    final safeStart = startIndex.clamp(0, peaks.length).toInt();
    final safeEnd = endIndex.clamp(safeStart, peaks.length).toInt();
    return peaks.sublist(safeStart, safeEnd).toList(growable: false);
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
    final localMs =
        (playheadMs - clip.timelineStartMs + clip.placement.sourceStartMs)
            .clamp(clip.placement.sourceStartMs, clip.placement.sourceEndMs)
            .toInt();
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
    final ids = <String>{
      track.id,
      track.queueItemId,
      if (track.playbackTrackId != null) track.playbackTrackId!,
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
        final overlap = first.placement.overlapInterval(
          second.timelineStartMs,
          second.timelineEndMs,
        );
        if (overlap == null) continue;

        final overlapStartX = viewport.msToX(overlap.startMs);
        final overlapEndX = viewport.msToX(overlap.endMs);
        final visibleStartX = overlapStartX.clamp(0.0, paneWidth).toDouble();
        final visibleEndX = overlapEndX.clamp(0.0, paneWidth).toDouble();
        final left = StackedWaveformTimeline.railWidth + visibleStartX;
        final minBandWidth = math.min(2.0, paneWidth);
        final width = (visibleEndX - visibleStartX).clamp(
          minBandWidth,
          paneWidth,
        );
        final midpointMs = overlap.startMs + (overlap.durationMs ~/ 2);
        final averageGain =
            ((first.gainAt(midpointMs) + second.gainAt(midpointMs)) / 2)
                .clamp(0.0, 1.0)
                .toDouble();
        bands.add(
          Positioned(
            key: bands.isEmpty
                ? const ValueKey('transition_window')
                : ValueKey('timeline_overlap_band_${first.id}_${second.id}'),
            left: left,
            top: 0,
            bottom: 0,
            width: width,
            child: _transitionBand(context, overlap.durationMs, averageGain),
          ),
        );
      }
    }
    return bands;
  }

  double _clipDisplayGain(MixClip clip) {
    if (clip.selectedDurationMs <= 0) return 0;
    final midpointMs = clip.timelineStartMs + (clip.selectedDurationMs ~/ 2);
    return clip.gainAt(midpointMs).clamp(0.0, 1.0).toDouble();
  }

  Widget _buildLane(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
    double paneWidth,
  ) {
    final left = viewport.msToX(lane.clip.timelineStartMs);
    final width = (viewport.msToX(lane.clip.timelineEndMs) -
            viewport.msToX(lane.clip.timelineStartMs))
        .clamp(8.0, double.infinity);
    final selected = _isTrackSelected(lane.track.id);

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
              child: _buildClipSurface(context, lane, viewport),
            ),
            if (selected &&
                (lane.role == LaneRole.upcoming ||
                    lane.role == LaneRole.collapsed))
              Positioned(
                right: 6,
                top: 12,
                child: _timelineMoveControls(context, lane.track),
              ),
            _buildLaneIdentity(context, lane, viewport, paneWidth),
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
    final width = (viewport.msToX(lane.clip.timelineEndMs) - left)
        .clamp(0.0, double.infinity)
        .toDouble();
    if (width <= 0) return const SizedBox.shrink();

    return Positioned(
      key: ValueKey('timeline_lane_span_${lane.track.id}'),
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
              bottom: BorderSide(
                color: lane.accent.withValues(alpha: 0.10),
              ),
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
    if (_isEditingTrack(lane.track.id)) return const SizedBox.shrink();

    const leftInset = 8.0;
    const topInset = 12.0;
    const minVisibleWidth = 56.0;
    final maxWidth = math.min(260.0, math.max(0.0, paneWidth - 16));
    final laneEndX = viewport.msToX(lane.clip.timelineEndMs);
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
              key: ValueKey('timeline_lane_header_${lane.track.id}'),
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
  ) {
    final selected = _isTrackSelected(lane.track.id);
    final selectedTrim = TrimRange.full(lane.clip.selectedDurationMs);
    final body = TimelineClipWidget(
      track: lane.track,
      peaks: _peaksForClip(lane.track, lane.clip),
      trim: selectedTrim,
      role: lane.role,
      accent: lane.accent,
      stateLabel: lane.status,
      snapMarkerCount: _snapMode.markerCount,
      gain: _clipDisplayGain(lane.mixClip),
      showGainBadge: widget.timelineModel?.clips.isNotEmpty ?? false,
      showInLaneChip: false,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: ValueKey('timeline_clip_body_drag_${lane.track.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _selectTrack(lane.track.id),
            onHorizontalDragStart:
                selected && widget.onTimelineStartChanged != null
                    ? (_) => _beginClipDrag(lane)
                    : null,
            onHorizontalDragUpdate:
                selected && widget.onTimelineStartChanged != null
                    ? (details) => _updateClipDrag(
                          lane,
                          viewport,
                          details.primaryDelta ?? 0,
                          useIncrementalDelta: true,
                        )
                    : null,
            onHorizontalDragEnd: (_) => _finishClipDrag(lane),
            onHorizontalDragCancel: () => _cancelClipDrag(lane.track.id),
            onLongPressStart: selected && widget.onTimelineStartChanged != null
                ? (_) => _beginClipDrag(lane)
                : null,
            onLongPressMoveUpdate:
                selected && widget.onTimelineStartChanged != null
                    ? (details) => _updateClipDrag(
                          lane,
                          viewport,
                          details.offsetFromOrigin.dx,
                        )
                    : null,
            onLongPressEnd: (_) => _finishClipDrag(lane),
            onLongPressCancel: () => _cancelClipDrag(lane.track.id),
            child: body,
          ),
        ),
        if (selected) ...[
          _trimHandle(
            key: ValueKey('timeline_trim_start_${lane.track.id}'),
            alignStart: true,
            accent: lane.accent,
            enabled: widget.onTrimStartChanged != null,
            onDragStart: () => _beginTrimDrag(lane, _TrimEdge.start),
            onDragUpdate: (deltaPx) => _updateTrimDrag(lane, viewport, deltaPx),
            onDragEnd: () => _finishTrimDrag(lane),
            onDragCancel: () => _cancelTrimDrag(lane.track.id),
          ),
          _trimHandle(
            key: ValueKey('timeline_trim_end_${lane.track.id}'),
            alignStart: false,
            accent: lane.accent,
            enabled: widget.onTrimEndChanged != null,
            onDragStart: () => _beginTrimDrag(lane, _TrimEdge.end),
            onDragUpdate: (deltaPx) => _updateTrimDrag(lane, viewport, deltaPx),
            onDragEnd: () => _finishTrimDrag(lane),
            onDragCancel: () => _cancelTrimDrag(lane.track.id),
          ),
        ],
      ],
    );
  }

  void _beginClipDrag(_LaneModel lane) {
    setState(() {
      _selectedTrackId = lane.track.id;
      _activeClipDragTrackId = lane.track.id;
      _activeClipDragStartClip = lane.clip;
      _storePreviewClip(lane.track, lane.clip);
    });
  }

  void _updateClipDrag(
    _LaneModel lane,
    TimelineViewport viewport,
    double deltaPx, {
    bool useIncrementalDelta = false,
  }) {
    if (_activeClipDragTrackId != lane.track.id) return;
    final baseClip = useIncrementalDelta
        ? (_previewClipFor(lane.track, lane.clip) ?? lane.clip)
        : _activeClipDragStartClip;
    if (baseClip == null) return;
    final deltaMs = _timelineDeltaMs(viewport, deltaPx);
    final snappedStart = _snapTimelineMs(
      math.max(0, baseClip.timelineStartMs + deltaMs),
    );
    if (snappedStart == baseClip.timelineStartMs) return;
    setState(() {
      _storePreviewClip(lane.track, baseClip.withTimelineStartMs(snappedStart));
    });
  }

  void _finishClipDrag(_LaneModel lane) {
    if (_activeClipDragTrackId != lane.track.id) return;
    final preview = _previewClipFor(lane.track, lane.clip) ?? lane.clip;
    final startClip = _activeClipDragStartClip;
    setState(() {
      _activeClipDragTrackId = null;
      _activeClipDragStartClip = null;
    });
    if (startClip == null ||
        preview.timelineStartMs != startClip.timelineStartMs) {
      widget.onTimelineStartChanged?.call(lane.track, preview.timelineStartMs);
    }
  }

  void _cancelClipDrag(String trackId) {
    if (_activeClipDragTrackId != trackId) return;
    setState(() {
      _removePreviewClip(trackId);
      _activeClipDragTrackId = null;
      _activeClipDragStartClip = null;
    });
  }

  void _beginTrimDrag(_LaneModel lane, _TrimEdge edge) {
    setState(() {
      _selectedTrackId = lane.track.id;
      _activeTrimTrackId = lane.track.id;
      _activeTrimEdge = edge;
      _activeTrimStartClip = lane.clip;
      _storePreviewClip(lane.track, lane.clip);
    });
  }

  void _updateTrimDrag(
    _LaneModel lane,
    TimelineViewport viewport,
    double deltaPx,
  ) {
    if (_activeTrimTrackId != lane.track.id) return;
    final edge = _activeTrimEdge;
    if (edge == null) return;
    final baseClip = _previewClipFor(lane.track, lane.clip) ?? lane.clip;
    final deltaMs = _timelineDeltaMs(viewport, deltaPx);
    if (deltaMs == 0) return;
    final next = switch (edge) {
      _TrimEdge.start => baseClip.withSourceRange(
          sourceStartMs: baseClip.sourceStartMs + deltaMs,
          sourceEndMs: baseClip.sourceEndMs,
        ),
      _TrimEdge.end => baseClip.withSourceRange(
          sourceStartMs: baseClip.sourceStartMs,
          sourceEndMs: baseClip.sourceEndMs + deltaMs,
        ),
    };
    if (next == baseClip) return;
    setState(() => _storePreviewClip(lane.track, next));
  }

  void _finishTrimDrag(_LaneModel lane) {
    if (_activeTrimTrackId != lane.track.id) return;
    final edge = _activeTrimEdge;
    final preview = _previewClipFor(lane.track, lane.clip) ?? lane.clip;
    final startClip = _activeTrimStartClip;
    setState(() {
      _activeTrimTrackId = null;
      _activeTrimEdge = null;
      _activeTrimStartClip = null;
    });
    if (edge == null || startClip == null) return;
    switch (edge) {
      case _TrimEdge.start:
        if (preview.sourceStartMs != startClip.sourceStartMs) {
          widget.onTrimStartChanged?.call(lane.track, preview.sourceStartMs);
        }
        break;
      case _TrimEdge.end:
        if (preview.sourceEndMs != startClip.sourceEndMs) {
          widget.onTrimEndChanged?.call(lane.track, preview.sourceEndMs);
        }
        break;
    }
  }

  void _cancelTrimDrag(String trackId) {
    if (_activeTrimTrackId != trackId) return;
    setState(() {
      _removePreviewClip(trackId);
      _activeTrimTrackId = null;
      _activeTrimEdge = null;
      _activeTrimStartClip = null;
    });
  }

  void _selectTrack(String trackId) {
    if (_selectedTrackId == trackId) return;
    setState(() => _selectedTrackId = trackId);
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

  int _snapTimelineMs(int ms) {
    final snapMs = _snapMode.snapMs;
    if (snapMs <= 1) return ms;
    return ((ms / snapMs).round() * snapMs).clamp(0, 2147483647).toInt();
  }

  Widget _timelineMoveControls(BuildContext context, Track track) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('timeline_move_earlier_${track.id}'),
            tooltip: 'Move ${track.title} earlier',
            icon: const Icon(Icons.keyboard_arrow_up),
            iconSize: 20,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            onPressed: widget.onMoveEarlier == null
                ? null
                : () => widget.onMoveEarlier!(track),
          ),
          IconButton(
            key: ValueKey('timeline_move_later_${track.id}'),
            tooltip: 'Move ${track.title} later',
            icon: const Icon(Icons.keyboard_arrow_down),
            iconSize: 20,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            onPressed: widget.onMoveLater == null
                ? null
                : () => widget.onMoveLater!(track),
          ),
        ],
      ),
    );
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

  Widget _transitionBand(BuildContext context, int durationMs, double gain) {
    const accent = StackedWaveformTimeline.currentAccent;
    final alpha = (0.08 + gain * 0.18).clamp(0.08, 0.26).toDouble();
    return IgnorePointer(
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
              'transition ${_formatClock(durationMs)} · gain ${(gain * 100).round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 10),
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
            TimelineViewport.maxPixelsPerSecond,
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
            setState(() => _snapMode = mode);
            setSheetState(() {});
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
