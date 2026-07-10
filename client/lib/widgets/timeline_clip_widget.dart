import 'package:flutter/material.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import '../models/waveform.dart';
import '../shared/widgets/song_metadata_chips.dart';
import 'timeline_waveform_painter.dart';

/// Visual role of a lane in the stacked timeline. Drives emphasis (contrast,
/// height) so the current mix line dominates while history/future stay
/// secondary.
enum LaneRole { previous, current, upcoming, collapsed }

/// List-like identity strip for a timeline lane: artwork, title, artist.
///
/// The timeline decides how much horizontal space remains before the lane's
/// end and clips this widget accordingly. That keeps future songs readable like
/// queue rows while letting ended songs disappear off the left edge.
class TimelineLaneHeader extends StatelessWidget {
  final Track track;
  final LaneRole role;
  final String statusLabel;
  final Color accent;

  const TimelineLaneHeader({
    super.key,
    required this.track,
    required this.role,
    required this.statusLabel,
    required this.accent,
  });

  bool get _active => role == LaneRole.current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = role == LaneRole.previous;

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
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: accent.withValues(alpha: _active ? 0.42 : 0.18),
            ),
          ),
          child: Row(
            children: [
              _artwork(theme),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_active) ...[
                          Icon(Icons.equalizer, size: 13, color: accent),
                          const SizedBox(width: 3),
                        ],
                        Expanded(
                          child: Text(
                            track.title,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight:
                                  _active ? FontWeight.bold : FontWeight.w600,
                              color: muted ? theme.disabledColor : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    LayoutBuilder(
                      builder: (context, constraints) => Row(
                        children: [
                          Expanded(
                            child: Text(
                              track.artist ?? 'Unknown artist',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted
                                    ? theme.disabledColor
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (constraints.maxWidth >= 150)
                            SongMetadataChips(analysis: track.analysis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _artwork(ThemeData theme) {
    final url = track.coverUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 36,
        height: 36,
        child: url == null || url.isEmpty
            ? _artworkFallback()
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _artworkFallback(),
              ),
      ),
    );
  }

  Widget _artworkFallback() {
    return Container(
      color: accent.withValues(alpha: 0.16),
      child: Icon(Icons.music_note, size: 18, color: accent),
    );
  }
}

/// The waveform body of a clip placed in the timeline pane.
///
/// Fills its positioned box with the transient-preserving waveform, an active
/// outline for the current lane, and a lightweight in-lane chip carrying the
/// short title / state / selected duration.
class TimelineClipWidget extends StatelessWidget {
  final Track track;
  final List<double> peaks;
  final TimelineWaveformData? waveform;
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

  const TimelineClipWidget({
    super.key,
    required this.track,
    required this.peaks,
    this.waveform,
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
  });

  bool get _active => role == LaneRole.current;
  bool get _muted => role == LaneRole.previous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gainScalar = gain.clamp(0.0, 1.0).toDouble();
    final waveAlpha =
        (_muted ? 0.45 : 0.62 + (gainScalar * 0.38)).clamp(0.0, 1.0).toDouble();
    final waveColor = accent.withValues(alpha: waveAlpha);

    return Container(
      key: ValueKey('timeline_clip_${track.id}'),
      decoration: BoxDecoration(
        color: accent.withValues(
          alpha: _active ? 0.10 + gainScalar * 0.08 : 0.05,
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _active ? accent : accent.withValues(alpha: 0.35),
          width: _active ? 1.5 + gainScalar : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              key: ValueKey('timeline_waveform_${track.id}'),
              painter: TimelineWaveformPainter(
                peaks: peaks,
                waveform: waveform,
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
            ),
          ),
          if (showInLaneChip)
            Positioned(left: 4, top: 4, right: 4, child: _inLaneChip(theme)),
          if (showGainBadge)
            Positioned(
              key: ValueKey('timeline_gain_${track.id}'),
              right: 6,
              bottom: 6,
              child: _gainBadge(theme, gainScalar),
            ),
        ],
      ),
    );
  }

  Widget _gainBadge(ThemeData theme, double gainScalar) {
    final gainPercent = (gainScalar * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.inverseSurface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'gain $gainPercent%',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onInverseSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _inLaneChip(ThemeData theme) {
    final dur = _formatMs(trim.selectedDurationMs);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(10),
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

String _formatMs(int ms) {
  final totalSeconds = (ms / 1000).round();
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
