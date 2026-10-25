import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../core/engine/timeline_model.dart';
import '../models/stem_edits.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../shared/widgets/song_metadata_chips.dart';
import '../shared/widgets/track_artwork.dart';
import 'timeline_waveform_painter.dart';

/// Visual role of a lane in the stacked timeline. Drives emphasis (contrast,
/// height) so the current mix line dominates while history/future stay
/// secondary.
enum LaneRole { previous, current, upcoming, collapsed }

/// List-like identity strip for a timeline lane: artwork, title, artist.
///
/// Desktop reserves a duration-independent cell; phone metadata remains
/// overlaid and clipped at the lane's temporal end.
class TimelineLaneHeader extends StatelessWidget {
  final QueueTrack track;
  final String? laneId;
  final LaneRole role;
  final String statusLabel;
  final Color accent;
  final VoidCallback? onTap;
  final double? gain;

  const TimelineLaneHeader({
    super.key,
    required this.track,
    this.laneId,
    required this.role,
    required this.statusLabel,
    required this.accent,
    this.onTap,
    this.gain,
  });

  bool get _active => role == LaneRole.current;

  static double heightForTextScale(double textScale) {
    final safeScale = textScale.clamp(1.0, 4.0);
    if (safeScale < 1.3) {
      return (48 + ((safeScale - 1) * 12)).clamp(48, 52).toDouble();
    }
    if (safeScale <= 2) {
      return (140 + ((safeScale - 1.3) * (4 / 0.7))).clamp(140, 144).toDouble();
    }
    return (144 + ((safeScale - 2) * 115)).clamp(144, 374).toDouble();
  }

  static double minimumVisibleWidthForTextScale(double textScale) =>
      textScale >= 1.3 ? 140 : 56;

  static double desktopHeight(BuildContext context, {required bool showGain}) {
    final text = Theme.of(context).textTheme;
    var height = 17.0; // vertical padding and the shared bottom rule
    for (final style in [
      text.labelSmall,
      text.bodyMedium,
      text.bodySmall,
      if (showGain) text.labelSmall?.copyWith(fontFamily: 'IBM Plex Mono')
    ]) {
      final painter = TextPainter(
          text: TextSpan(text: 'Ag', style: style),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: TextDirection.ltr)
        ..layout();
      height += painter.height;
      painter.dispose();
    }
    return height.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = role == LaneRole.previous;
    if (MediaQuery.sizeOf(context).width >= 960) {
      return _DesktopLaneIdentity(
          track: track,
          role: role,
          statusLabel: statusLabel,
          accent: accent,
          onTap: onTap,
          gain: gain);
    }
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final headerHeight = heightForTextScale(textScale);

    return Semantics(
      container: true,
      label:
          '$statusLabel: ${track.title} by ${track.artist ?? 'Unknown artist'}',
      child: Material(
        color: theme.colorScheme.surface.withValues(
          alpha: _active ? 0.86 : 0.72,
        ),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: accent.withValues(alpha: _active ? 0.42 : 0.18),
            ),
          ),
          child: textScale >= 1.3
              ? _accessibleLayout(theme, muted)
              : Row(
                  children: [
                    _artwork(),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final largeText =
                              textScale >= 1.2 || constraints.maxWidth < 190;
                          if (largeText) {
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _titleRow(
                                  theme,
                                  muted,
                                  '${track.title} · ${track.artist ?? 'Unknown artist'}',
                                ),
                                const SizedBox(height: 2),
                                Flexible(
                                  child: SongMetadataChips(
                                    analysis: track.analysis,
                                    singleLine: true,
                                    compact: true,
                                  ),
                                ),
                              ],
                            );
                          }

                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _titleRow(theme, muted, track.title),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      track.artist ?? 'Unknown artist',
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: muted
                                            ? theme.disabledColor
                                            : theme
                                                .colorScheme.onSurfaceVariant,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (constraints.maxWidth >= 150)
                                    Flexible(
                                      flex: 2,
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: SongMetadataChips(
                                          analysis: track.analysis,
                                          singleLine: true,
                                          compact: true,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _accessibleLayout(ThemeData theme, bool muted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _artwork(),
            const SizedBox(width: 8),
            Expanded(
              child: _titleRow(
                theme,
                muted,
                '${track.title} · ${track.artist ?? 'Unknown artist'}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: SongMetadataChips(analysis: track.analysis),
          ),
        ),
      ],
    );
  }

  Widget _titleRow(ThemeData theme, bool muted, String title) {
    return Row(
      children: [
        if (_active) ...[
          Icon(Icons.equalizer, size: 13, color: accent),
          const SizedBox(width: 3),
        ],
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: _active ? FontWeight.bold : FontWeight.w600,
              color: muted ? theme.disabledColor : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _artwork() {
    return TrackArtwork(
      url: track.artworkUrl,
      kind: track.artworkKind,
      cacheKey: 'timeline:${track.queueItemId}:${track.artworkKind.wireValue}:'
          '${track.artworkUrl ?? "none"}',
      width: 36,
      height: 36,
    );
  }
}

/// The reserved desktop identity cell follows the existing lane scroll owner.
/// Native InkWell owns keyboard activation and Tooltip owns disclosure.
class _DesktopLaneIdentity extends StatefulWidget {
  const _DesktopLaneIdentity(
      {required this.track,
      required this.role,
      required this.statusLabel,
      required this.accent,
      this.onTap,
      this.gain});
  final QueueTrack track;
  final LaneRole role;
  final String statusLabel;
  final Color accent;
  final VoidCallback? onTap;
  final double? gain;

  @override
  State<_DesktopLaneIdentity> createState() => _DesktopLaneIdentityState();
}

class _DesktopLaneIdentityState extends State<_DesktopLaneIdentity> {
  final _tooltip = GlobalKey<TooltipState>();
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  void _revealFocused() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focused) _tooltip.currentState?.ensureTooltipVisible();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final feedback = _focused || _hovered || _pressed;
    final background = _pressed
        ? colors.onSurface
        : feedback
            ? colors.secondary
            : colors.surface;
    final foreground = feedback ? colors.onSecondary : colors.onSurface;
    final secondary = feedback ? foreground : colors.onSurfaceVariant;
    final active = widget.role == LaneRole.current;
    final name =
        '${widget.track.title}\n${widget.track.artist ?? 'Unknown artist'}';
    return Tooltip(
      key: _tooltip,
      message: name,
      excludeFromSemantics: true,
      constraints: BoxConstraints(
          maxWidth: math.min(560, MediaQuery.sizeOf(context).width - 32)),
      decoration: BoxDecoration(color: colors.inverseSurface),
      textStyle:
          theme.textTheme.bodyMedium?.copyWith(color: colors.onInverseSurface),
      child: Material(
        color: background,
        child: InkWell(
          onTap: widget.onTap,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          onFocusChange: (value) {
            setState(() => _focused = value);
            if (value) {
              _revealFocused();
            } else {
              Tooltip.dismissAllToolTips();
            }
          },
          onHover: (value) {
            setState(() => _hovered = value);
            if (!value && _focused) _revealFocused();
          },
          onHighlightChanged: (value) => setState(() => _pressed = value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            foregroundDecoration: _focused
                ? BoxDecoration(border: Border.all(color: foreground))
                : null,
            decoration: BoxDecoration(
                border: Border(
              left: BorderSide(
                  color: active ? colors.primary : Colors.transparent,
                  width: 3),
              bottom: BorderSide(color: theme.dividerColor),
            )),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: feedback
                            ? foreground
                            : active
                                ? colors.primary
                                : secondary)),
                Text(widget.track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w600)),
                Text(widget.track.artist ?? 'Unknown artist',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        theme.textTheme.bodySmall?.copyWith(color: secondary)),
                if (widget.gain case final gain?)
                  Text('gain ${(gain.clamp(0, 1) * 100).round()}%',
                      key:
                          ValueKey('timeline_gain_${widget.track.queueItemId}'),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: secondary,
                          fontFamily: 'IBM Plex Mono',
                          fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The waveform body of a clip placed in the timeline pane.
///
/// Fills its positioned box with the transient-preserving waveform, an active
/// outline for the current lane, and a lightweight in-lane chip carrying the
/// short title / state / selected duration.
class TimelineClipWidget extends StatelessWidget {
  static final Expando<_OffsetMarkerViews> _offsetMarkerViews = Expando();

  static const double _maxBoundaryPhysicalWidth = 4096;
  static const double _maxBoundaryPhysicalHeight = 512;

  final QueueTrack track;
  final String? laneId;
  final List<double> peaks;
  final TimelineWaveformData? waveform;
  final MixClip? mixClip;
  final Object? mappingRevision;
  final TimelineWaveformPaintCache? paintCache;
  final double viewportPixelsPerMs;
  final int viewportOriginMs;
  final double visibleStartFraction;
  final double visibleEndFraction;
  final TrimRange trim;
  final LaneRole role;
  final Color accent;
  final String stateLabel;
  final int snapMarkerCount;
  final double gain;
  final bool showGainBadge;
  final bool showInLaneChip;

  /// Optional ADR 0006 stem gain change points for this clip, in **absolute
  /// source milliseconds**.
  ///
  /// When empty (the default) this widget adds no extra subtree at all, so
  /// rendering is identical to a build without stem edits.
  final List<StemGainEvent> stemChangePoints;

  const TimelineClipWidget({
    super.key,
    required this.track,
    this.laneId,
    required this.peaks,
    this.waveform,
    this.mixClip,
    this.mappingRevision,
    this.paintCache,
    required this.viewportPixelsPerMs,
    required this.viewportOriginMs,
    this.visibleStartFraction = 0,
    this.visibleEndFraction = 1,
    required this.trim,
    required this.role,
    required this.accent,
    required this.stateLabel,
    this.snapMarkerCount = 0,
    this.gain = 1,
    this.showGainBadge = false,
    this.showInLaneChip = true,
    this.stemChangePoints = const <StemGainEvent>[],
  });

  bool get _active => role == LaneRole.current;
  bool get _muted => role == LaneRole.previous;
  String get _laneIdentity {
    final explicitLaneId = laneId;
    if (explicitLaneId != null && explicitLaneId.isNotEmpty) {
      return explicitLaneId;
    }
    return track.queueItemId.isNotEmpty ? track.queueItemId : track.id;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gainScalar = gain.clamp(0.0, 1.0).toDouble();
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    final radius = desktop ? BorderRadius.zero : BorderRadius.circular(6);
    final waveAlpha =
        (_muted ? 0.45 : 0.62 + (gainScalar * 0.38)).clamp(0.0, 1.0).toDouble();
    final waveColor = accent.withValues(alpha: waveAlpha);
    final projectedBeatMarkers = _projectedBeatMarkersForSelectedTempoScale();

    return ClipRRect(
      key: ValueKey('timeline_clip_$_laneIdentity'),
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: accent.withValues(
            alpha: _active ? 0.10 + gainScalar * 0.08 : 0.05,
          ),
          borderRadius: radius,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final waveformPaint = CustomPaint(
                    key: ValueKey('timeline_waveform_$_laneIdentity'),
                    painter: TimelineWaveformPainter(
                      peaks: peaks,
                      waveform: waveform,
                      projectedBeatMarkers: projectedBeatMarkers,
                      mixClip: mixClip,
                      mappingRevision: mappingRevision,
                      laneIdentity: _laneIdentity,
                      paintCache: paintCache,
                      viewportPixelsPerMs: viewportPixelsPerMs,
                      viewportOriginMs: viewportOriginMs,
                      visibleStartFraction: visibleStartFraction,
                      visibleEndFraction: visibleEndFraction,
                      color: waveColor,
                      dimColor: theme.disabledColor.withValues(alpha: 0.35),
                      handleColor: accent.withValues(alpha: 0.9),
                      snapMarkerColor: accent.withValues(alpha: 0.62),
                      trimStartFraction: trim.startFraction,
                      trimEndFraction: trim.endFraction,
                      snapMarkerCount: snapMarkerCount,
                    ),
                  );
                  final devicePixelRatio =
                      MediaQuery.devicePixelRatioOf(context);
                  final isolatePaint =
                      constraints.maxWidth * devicePixelRatio <=
                              _maxBoundaryPhysicalWidth &&
                          constraints.maxHeight * devicePixelRatio <=
                              _maxBoundaryPhysicalHeight;
                  return isolatePaint
                      ? RepaintBoundary(child: waveformPaint)
                      : waveformPaint;
                },
              ),
            ),
            if (stemChangePoints.isNotEmpty)
              Positioned.fill(child: _stemChangePointOverlay()),
            if (showInLaneChip)
              Positioned(
                  left: 4,
                  top: 4,
                  right: 4,
                  child: _inLaneChip(theme, desktop)),
            if (showGainBadge)
              Positioned(
                key: ValueKey('timeline_gain_$_laneIdentity'),
                right: 6,
                bottom: 6,
                child: _gainBadge(theme, gainScalar, desktop),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: _active ? accent : accent.withValues(alpha: 0.35),
                      width: _active ? 1.5 + gainScalar : 1,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Source-ms origin of this clip's box. Stem change points are stored in
  /// absolute source time, but the box only spans the selected source range.
  int get _stemSourceStartMs =>
      mixClip?.placement.sourceStartMs ?? waveform?.sourceStartMs ?? 0;

  int get _stemSelectedDurationMs {
    final fromClip = mixClip?.placement.selectedDurationMs;
    if (fromClip != null && fromClip > 0) return fromClip;
    final fromTrim = trim.selectedDurationMs;
    return fromTrim > 0 ? fromTrim : 0;
  }

  Widget _stemChangePointOverlay() {
    final startMs = _stemSourceStartMs;
    final durationMs = _stemSelectedDurationMs;
    if (durationMs <= 0) return const SizedBox.shrink();

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (!width.isFinite || width <= 0) return const SizedBox.shrink();
          return Stack(
            children: [
              for (final event in stemChangePoints)
                if (_stemTickFraction(event, startMs, durationMs)
                    case final fraction?)
                  Positioned(
                    key: ValueKey(
                      'timeline_stem_marker_${_laneIdentity}_'
                      '${event.channel}_${event.atMs}',
                    ),
                    left: (fraction * width)
                        .clamp(0.0, math.max(0.0, width - 2))
                        .toDouble(),
                    top: 0,
                    bottom: 0,
                    width: 2,
                    child: TimelineStemChangePointTick(
                      channel: event.channel,
                      isCut: event.isCut,
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }

  static double? _stemTickFraction(
    StemGainEvent event,
    int sourceStartMs,
    int selectedDurationMs,
  ) {
    final offsetMs = event.atMs - sourceStartMs;
    if (offsetMs < 0 || offsetMs > selectedDurationMs) return null;
    return offsetMs / selectedDurationMs;
  }

  List<int>? _projectedBeatMarkersForSelectedTempoScale() {
    final source = waveform;
    final clip = mixClip;
    if (source == null || clip == null) return null;
    if (!clip.rateAutomation.segments.any(
      (segment) => segment.tempoScale != 1,
    )) {
      return null;
    }
    final sourceStartMs = source.sourceStartMs;
    final absoluteMarkers = _markersOffsetBy(source.beatsMs, sourceStartMs);
    final projectedMarkers =
        clip.projectTempoSegmentBeatMarkers(absoluteMarkers);
    return _markersOffsetBy(projectedMarkers, -sourceStartMs);
  }

  static List<int> _markersOffsetBy(List<int> markers, int offsetMs) {
    if (offsetMs == 0) return markers;
    final views = _offsetMarkerViews[markers] ?? _OffsetMarkerViews();
    _offsetMarkerViews[markers] = views;
    return views.byOffset.putIfAbsent(
      offsetMs,
      () => _OffsetMarkerList(markers, offsetMs),
    );
  }

  Widget _gainBadge(ThemeData theme, double gainScalar, bool desktop) {
    final gainPercent = (gainScalar * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface,
        borderRadius: desktop ? BorderRadius.zero : BorderRadius.circular(10),
      ),
      child: Text(
        'gain $gainPercent%',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onInverseSurface,
          fontFamily: desktop ? 'IBM Plex Mono' : null,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _inLaneChip(ThemeData theme, bool desktop) {
    final dur = _formatMs(trim.selectedDurationMs);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.82),
        borderRadius: desktop ? BorderRadius.zero : BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_active)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(Icons.equalizer, size: 12, color: accent),
            ),
          Flexible(
            child: Text(
              '${track.title} · $stateLabel · $dur',
              style: theme.textTheme.labelSmall?.copyWith(
                color: _muted ? theme.disabledColor : null,
                fontWeight: _active ? FontWeight.bold : FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A single thin channel-colored tick marking one stem gain change point on a
/// clip lane. Purely a marker — it carries no playback or transport state.
class TimelineStemChangePointTick extends StatelessWidget {
  const TimelineStemChangePointTick({
    super.key,
    required this.channel,
    required this.isCut,
  });

  final String channel;
  final bool isCut;

  @override
  Widget build(BuildContext context) {
    final color = stemChannelColor(channel);
    return Semantics(
      label: '$channel change point',
      child: ColoredBox(
        color: color.withValues(alpha: isCut ? 0.95 : 0.6),
      ),
    );
  }
}

class _OffsetMarkerViews {
  final Map<int, List<int>> byOffset = {};
}

class _OffsetMarkerList extends ListBase<int> {
  final List<int> _source;
  final int _offsetMs;

  _OffsetMarkerList(this._source, this._offsetMs);

  @override
  int get length => _source.length;

  @override
  int operator [](int index) => _source[index] + _offsetMs;

  @override
  void operator []=(int index, int value) {
    throw UnsupportedError('Marker offset views are read-only.');
  }

  @override
  set length(int value) {
    throw UnsupportedError('Marker offset views are read-only.');
  }
}

String _formatMs(int ms) {
  final totalSeconds = (ms / 1000).round();
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
