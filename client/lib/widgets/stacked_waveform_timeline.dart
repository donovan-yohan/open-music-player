import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../models/timeline_clip.dart';
import '../models/timeline_viewport.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import 'timeline_clip_widget.dart';

/// Static visual prototype of issue #19 phase 2: a stacked compact-waveform
/// timeline for the phone-first mix planner (~390x844).
///
/// The dominant object is a stack of overlapping waveform lanes sharing a single
/// global playhead — not list rows or cards. Previous / current / upcoming clips
/// are placed on one timeline with synthetic transition windows so overlap is
/// visible. Offscreen clips surface as left history / right future teasers.
///
/// This is a prototype: there is no audio engine, BPM, key, beat grid or
/// time-stretch. Placement is synthesised from queue order + source trim only,
/// keeping source trim strictly separate from timeline placement.
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
  });

  /// Synthetic crossfade/transition window between adjacent clips (ms). Visual
  /// only — there is no real mixer.
  static const int transitionMs = 18000;

  /// Left pinned header rail width (matches design `x 0-88`).
  static const double railWidth = TimelineLaneHeader.railWidth;

  static const Color currentAccent = Color(0xFF2E7D32); // high-contrast green
  static const Color previousAccent = Color(0xFF607D8B);
  static const Color upcomingAccent = Color(0xFF1565C0);

  @override
  State<StackedWaveformTimeline> createState() =>
      _StackedWaveformTimelineState();
}

enum _TimelineMode { browse, edit }

class _LaneModel {
  final Track track;
  final TimelineClip clip;
  final LaneRole role;
  final Color accent;
  final String status;
  final double height;

  _LaneModel({
    required this.track,
    required this.clip,
    required this.role,
    required this.accent,
    required this.status,
    required this.height,
  });
}

class _StackedWaveformTimelineState extends State<StackedWaveformTimeline> {
  static const _zoomLevels = [0.5, 1.0, 1.5, 2.0, 3.0];

  _TimelineMode _mode = _TimelineMode.browse;
  int _zoomIndex = 1;
  int? _manualOffsetMs;
  TimelineViewport? _lastViewport;

  double get _zoom => _zoomLevels[_zoomIndex];

  @override
  void didUpdateWidget(covariant StackedWaveformTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.currentTrack.id != widget.currentTrack.id) {
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
        _buildModeBar(context),
      ],
    );
  }

  Widget _buildTimeline(BuildContext context, double paneWidth) {
    // --- Synthesise global placement from queue order + source trim. ---
    final ordered = <Track>[
      if (widget.previousTrack != null) widget.previousTrack!,
      widget.currentTrack,
      ...widget.upcomingTracks.take(2),
    ];

    final placed = <Track, TimelineClip>{};
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
      final clip = widget.clipFor?.call(track, defaultClip) ?? defaultClip;
      placed[track] = clip;
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

    // Playhead sits just past the incoming transition so history has "ended".
    final playheadMs = currentClip.timelineStartMs +
        StackedWaveformTimeline.transitionMs +
        8000;

    final basePps = totalMs <= 0
        ? TimelineViewport.minPixelsPerSecond
        : (paneWidth / (totalMs / 1000));
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
    _lastViewport = viewport;

    // --- Build lane models in stack order (history → future, top to bottom). ---
    final lanes = <_LaneModel>[];
    if (widget.previousTrack != null) {
      lanes.add(
        _LaneModel(
          track: widget.previousTrack!,
          clip: placed[widget.previousTrack!]!,
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
        clip: currentClip,
        role: LaneRole.current,
        accent: StackedWaveformTimeline.currentAccent,
        status: 'Now playing',
        height: 146,
      ),
    );
    final upcoming = widget.upcomingTracks.take(2).toList();
    for (var i = 0; i < upcoming.length; i++) {
      final collapsed = i == 1;
      lanes.add(
        _LaneModel(
          track: upcoming[i],
          clip: placed[upcoming[i]]!,
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

    // Transition window = overlap of current clip and the first upcoming clip.
    Widget? transitionBand;
    if (upcoming.isNotEmpty) {
      final nextClip = placed[upcoming.first]!;
      final overlap = currentClip.overlapInterval(
        nextClip.timelineStartMs,
        nextClip.timelineEndMs,
      );
      if (overlap != null) {
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
        transitionBand = Positioned(
          key: const ValueKey('transition_window'),
          left: left,
          top: 0,
          bottom: 0,
          width: width,
          child: _transitionBand(context, overlap.durationMs),
        );
      }
    }

    final historyAgoMs = playheadMs -
        (placed[widget.previousTrack]?.timelineEndMs ?? playheadMs);
    final futureInMs = (upcoming.isNotEmpty
            ? placed[upcoming.first]!.timelineStartMs
            : playheadMs) -
        playheadMs;

    return GestureDetector(
      key: const ValueKey('timeline_pan_surface'),
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _mode == _TimelineMode.browse
          ? (details) => _panViewport(viewport, -(details.primaryDelta ?? 0))
          : null,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRuler(context, viewport),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final lane in lanes)
                        _buildLane(context, lane, viewport),
                    ],
                  ),
                ),
              ),
            ],
          ),

          if (transitionBand != null) transitionBand,

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

          // Left-edge history teaser for the offscreen played clip.
          if (widget.previousTrack != null)
            Positioned(
              key: const ValueKey('left_history_teaser'),
              left: StackedWaveformTimeline.railWidth + 4,
              top: 6,
              child: _edgeTeaser(
                context,
                icon: Icons.history,
                label: '${widget.previousTrack!.title} · ended '
                    '${_formatClock(historyAgoMs.abs())} ago',
                accent: StackedWaveformTimeline.previousAccent,
                onTap: () => _jumpToClip(
                  placed[widget.previousTrack!]!,
                  viewport,
                  alignEnd: true,
                ),
              ),
            ),

          // Right-edge future teaser / countdown for the offscreen next clip.
          if (upcoming.isNotEmpty)
            Positioned(
              key: const ValueKey('right_future_teaser'),
              right: 4,
              top: 6,
              child: _edgeTeaser(
                context,
                icon: Icons.fast_forward,
                label: '${upcoming.first.title} · starts in '
                    '${_formatClock(futureInMs.abs())}',
                accent: StackedWaveformTimeline.upcomingAccent,
                onTap: () => _jumpToClip(placed[upcoming.first]!, viewport),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLane(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
  ) {
    final left = viewport.msToX(lane.clip.timelineStartMs);
    final width = (viewport.msToX(lane.clip.timelineEndMs) -
            viewport.msToX(lane.clip.timelineStartMs))
        .clamp(8.0, double.infinity);

    return SizedBox(
      height: lane.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TimelineLaneHeader(
            key: ValueKey('timeline_lane_header_${lane.track.id}'),
            track: lane.track,
            role: lane.role,
            statusLabel: lane.status,
            accent: lane.accent,
          ),
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned(
                    left: left,
                    top: 8,
                    bottom: 8,
                    width: width,
                    child: _buildClipSurface(context, lane, viewport),
                  ),
                  if (lane.role == LaneRole.upcoming ||
                      lane.role == LaneRole.collapsed)
                    Positioned(
                      right: 6,
                      top: 12,
                      child: _timelineMoveControls(context, lane.track),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClipSurface(
    BuildContext context,
    _LaneModel lane,
    TimelineViewport viewport,
  ) {
    final editMode = _mode == _TimelineMode.edit;
    final trim = TrimRange.clamped(
      trackDurationMs: lane.clip.sourceDurationMs,
      startOffsetMs: lane.clip.sourceStartMs,
      endOffsetMs: lane.clip.sourceEndMs,
    );
    final body = TimelineClipWidget(
      track: lane.track,
      peaks: widget.peaksFor(lane.track),
      trim: trim,
      role: lane.role,
      accent: lane.accent,
      stateLabel: lane.status,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: ValueKey('timeline_clip_body_drag_${lane.track.id}'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate:
                editMode && widget.onTimelineStartChanged != null
                    ? (details) {
                        final deltaMs = _timelineDeltaMs(
                          viewport,
                          details.primaryDelta ?? 0,
                        );
                        if (deltaMs == 0) return;
                        widget.onTimelineStartChanged!(
                          lane.track,
                          math.max(0, lane.clip.timelineStartMs + deltaMs),
                        );
                      }
                    : null,
            child: body,
          ),
        ),
        if (editMode) ...[
          _trimHandle(
            key: ValueKey('timeline_trim_start_${lane.track.id}'),
            alignStart: true,
            accent: lane.accent,
            enabled: widget.onTrimStartChanged != null,
            onDragUpdate: (deltaPx) {
              final deltaMs = _timelineDeltaMs(viewport, deltaPx);
              if (deltaMs == 0) return;
              widget.onTrimStartChanged!(
                lane.track,
                lane.clip.sourceStartMs + deltaMs,
              );
            },
          ),
          _trimHandle(
            key: ValueKey('timeline_trim_end_${lane.track.id}'),
            alignStart: false,
            accent: lane.accent,
            enabled: widget.onTrimEndChanged != null,
            onDragUpdate: (deltaPx) {
              final deltaMs = _timelineDeltaMs(viewport, deltaPx);
              if (deltaMs == 0) return;
              widget.onTrimEndChanged!(
                lane.track,
                lane.clip.sourceEndMs + deltaMs,
              );
            },
          ),
        ],
      ],
    );
  }

  Widget _trimHandle({
    required Key key,
    required bool alignStart,
    required Color accent,
    required bool enabled,
    required ValueChanged<double> onDragUpdate,
  }) {
    return Positioned(
      left: alignStart ? 0 : null,
      right: alignStart ? null : 0,
      top: 0,
      bottom: 0,
      width: 44,
      child: Semantics(
        label: alignStart ? 'Trim start handle' : 'Trim end handle',
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: enabled
              ? (details) => onDragUpdate(details.primaryDelta ?? 0)
              : null,
          child: Align(
            alignment:
                alignStart ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              width: 10,
              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: enabled ? 0.88 : 0.35),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: Colors.white.withValues(alpha: 0.75)),
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

  Widget _buildRuler(BuildContext context, TimelineViewport viewport) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: StackedWaveformTimeline.railWidth,
            child: Center(
              child: Text(
                'Mix time',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Expanded(
            child: CustomPaint(
              painter: _RulerPainter(
                viewport: viewport,
                color: theme.dividerColor,
                textColor: theme.textTheme.labelSmall?.color ?? Colors.grey,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _transitionBand(BuildContext context, int durationMs) {
    const accent = StackedWaveformTimeline.currentAccent;
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          border: Border.symmetric(
            vertical: BorderSide(color: accent.withValues(alpha: 0.5)),
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
              'transition ${_formatClock(durationMs)}',
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
        ),
      ),
    );
  }

  Widget _edgeTeaser(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color accent,
    VoidCallback? onTap,
  }) {
    return Semantics(
      button: onTap != null,
      label: label,
      child: Material(
        color: accent.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 150, minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: Colors.white),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _panViewport(TimelineViewport viewport, double deltaXPx) {
    if (!deltaXPx.isFinite || deltaXPx == 0) return;
    final next = viewport.panByPixels(deltaXPx);
    if (next.offsetMs == viewport.offsetMs) return;
    setState(() => _manualOffsetMs = next.offsetMs);
  }

  void _jumpToClip(
    TimelineClip clip,
    TimelineViewport viewport, {
    bool alignEnd = false,
  }) {
    final target = alignEnd
        ? clip.timelineEndMs - viewport.visibleDurationMs
        : clip.timelineStartMs;
    final next = viewport.panToOffsetMs(target);
    setState(() => _manualOffsetMs = next.offsetMs);
  }

  void _setZoomIndex(int newIndex) {
    final clampedIndex = newIndex.clamp(0, _zoomLevels.length - 1).toInt();
    if (clampedIndex == _zoomIndex) return;

    final viewport = _lastViewport;
    final oldZoom = _zoom;
    final newZoom = _zoomLevels[clampedIndex];
    setState(() {
      _zoomIndex = clampedIndex;
      if (viewport != null) {
        final nextPps = (viewport.pixelsPerSecond * (newZoom / oldZoom))
            .clamp(
              TimelineViewport.minPixelsPerSecond,
              TimelineViewport.maxPixelsPerSecond,
            )
            .toDouble();
        _manualOffsetMs = viewport
            .zoomAround(
              newPixelsPerSecond: nextPps,
              focalXPx: viewport.widthPx / 2,
            )
            .offsetMs;
      }
    });
  }

  Widget _buildModeBar(BuildContext context) {
    final theme = Theme.of(context);
    final leadingControls = [
      _modeButton(
        label: 'Browse',
        icon: Icons.pan_tool_alt,
        selected: _mode == _TimelineMode.browse,
        onTap: () => setState(() => _mode = _TimelineMode.browse),
      ),
      const SizedBox(width: 4),
      _modeButton(
        label: 'Edit',
        icon: Icons.edit,
        selected: _mode == _TimelineMode.edit,
        onTap: () => setState(() => _mode = _TimelineMode.edit),
      ),
    ];
    final trailingControls = [
      IconButton(
        key: const ValueKey('timeline_zoom_out'),
        icon: const Icon(Icons.zoom_out),
        tooltip: 'Zoom out timeline',
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
        onPressed: _zoomIndex == 0 ? null : () => _setZoomIndex(_zoomIndex - 1),
      ),
      Container(
        key: const ValueKey('timeline_zoom_label'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${_zoom.toStringAsFixed(1)}x',
          style: theme.textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      IconButton(
        key: const ValueKey('timeline_zoom_in'),
        icon: const Icon(Icons.zoom_in),
        tooltip: 'Zoom in timeline',
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
        onPressed: _zoomIndex == _zoomLevels.length - 1
            ? null
            : () => _setZoomIndex(_zoomIndex + 1),
      ),
      IconButton(
        key: const ValueKey('timeline_zoom_reset'),
        icon: const Icon(Icons.zoom_out_map),
        tooltip: 'Reset timeline zoom',
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
        onPressed: _zoomIndex == 1 ? null : () => _setZoomIndex(1),
      ),
    ];

    return Container(
      key: const ValueKey('timeline_mode_bar'),
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...leadingControls,
                const SizedBox(width: 16),
                ...trailingControls,
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _modeButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? StackedWaveformTimeline.currentAccent.withValues(alpha: 0.15)
              : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? StackedWaveformTimeline.currentAccent
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
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
    // One label every ~15s, scaled to whatever fits.
    const stepMs = 15000;
    final total = viewport.durationMs;
    for (var ms = 0; ms <= total; ms += stepMs) {
      final x = viewport.msToX(ms);
      if (x < 0 || x > size.width) continue;
      canvas.drawLine(Offset(x, size.height - 8), Offset(x, size.height), tick);
      final tp = TextPainter(
        text: TextSpan(
          text: _formatClock(ms),
          style: TextStyle(color: textColor, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 2, 2));
    }
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
