import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/track_analysis.dart';
import '../models/track.dart';
import '../models/library_track.dart';
import 'song_metadata_chips.dart';

class TrackTile extends StatelessWidget {
  final String title;
  final String? artist;
  final String? album;
  final String duration;
  final String? coverArtUrl;
  final VoidCallback? onTap;
  final VoidCallback? onMorePressed;
  final Widget? leading;
  final Widget? trailing;
  final bool showDragHandle;
  final bool isCurrent;
  final String? activeLabel;
  final TrackAnalysis? analysis;

  const TrackTile({
    super.key,
    required this.title,
    this.artist,
    this.album,
    required this.duration,
    this.coverArtUrl,
    this.onTap,
    this.onMorePressed,
    this.leading,
    this.trailing,
    this.showDragHandle = false,
    this.isCurrent = false,
    this.activeLabel,
    this.analysis,
  });

  factory TrackTile.fromTrack(
    Track track, {
    VoidCallback? onTap,
    VoidCallback? onMorePressed,
    Widget? leading,
    Widget? trailing,
    bool showDragHandle = false,
    bool isCurrent = false,
    String? activeLabel,
  }) {
    return TrackTile(
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.formattedDuration,
      coverArtUrl: track.coverArtUrl,
      onTap: onTap,
      onMorePressed: onMorePressed,
      leading: leading,
      trailing: trailing,
      showDragHandle: showDragHandle,
      isCurrent: isCurrent,
      activeLabel: activeLabel,
      analysis: track.analysis,
    );
  }

  factory TrackTile.fromLibraryTrack(
    LibraryTrack track, {
    VoidCallback? onTap,
    VoidCallback? onMorePressed,
    Widget? leading,
    Widget? trailing,
    bool showDragHandle = false,
    bool isCurrent = false,
    String? activeLabel,
  }) {
    return TrackTile(
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.formattedDuration,
      coverArtUrl: track.coverArtUrl,
      onTap: onTap,
      onMorePressed: onMorePressed,
      leading: leading,
      trailing: trailing,
      showDragHandle: showDragHandle,
      isCurrent: isCurrent,
      activeLabel: activeLabel,
      analysis: track.analysis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = theme.colorScheme.primary;
    final titleStyle = isCurrent
        ? theme.textTheme.bodyLarge?.copyWith(
            color: activeColor,
            fontWeight: FontWeight.w700,
          )
        : theme.textTheme.bodyLarge;
    final subtitleStyle = isCurrent
        ? theme.textTheme.bodySmall?.copyWith(
            color: activeColor.withValues(alpha: 0.85),
          )
        : theme.textTheme.bodySmall;
    final subtitle = [
      artist,
      album,
    ].where((value) => value != null && value.isNotEmpty).join(' • ');
    final summary = analysis?.summary;
    final hasMetadata = summary?.bpm?.numericValue != null ||
        summary?.key?.textValue != null ||
        summary?.camelot?.textValue != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final trailingMaxWidth =
            (availableWidth * 0.38).clamp(96.0, 168.0).toDouble();
        final enlargedText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final hasNowPlayingBadge = isCurrent && activeLabel != null;

        final useExpandedLayout = hasMetadata &&
            (hasNowPlayingBadge || (enlargedText && availableWidth < 480));

        if (useExpandedLayout) {
          final expandedMetadataMaxWidth =
              (availableWidth * 0.55).clamp(150.0, 220.0).toDouble();
          return _buildExpandedTextTile(
            context,
            theme: theme,
            activeColor: activeColor,
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            subtitle: subtitle,
            metadataMaxWidth: expandedMetadataMaxWidth,
          );
        }

        return Container(
          decoration: BoxDecoration(
            border: isCurrent
                ? Border(left: BorderSide(color: activeColor, width: 3))
                : null,
          ),
          child: ListTile(
            onTap: onTap,
            selected: isCurrent,
            selectedTileColor: activeColor.withValues(alpha: 0.10),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: leading ?? _buildCoverArt(theme),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
            subtitle: subtitle.isEmpty
                ? null
                : Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: subtitleStyle,
                  ),
            trailing: _buildTrailing(
              context,
              hasMetadata,
              trailingMaxWidth,
            ),
          ),
        );
      },
    );
  }

  Widget _buildCoverArt(ThemeData theme) {
    if (coverArtUrl != null && coverArtUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CachedNetworkImage(
          imageUrl: coverArtUrl!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          memCacheWidth: 96, // 2x for retina displays
          memCacheHeight: 96,
          placeholder: (_, __) => _CoverArtPlaceholder(theme: theme),
          errorWidget: (_, __, ___) => _CoverArtPlaceholder(theme: theme),
        ),
      );
    }
    return _CoverArtPlaceholder(theme: theme);
  }

  Widget _buildTrailing(
    BuildContext context,
    bool hasMetadata,
    double maxWidth,
  ) {
    final actions = _buildTrailingActions(context);
    if (!hasMetadata) return actions;

    final metadata = Align(
      widthFactor: 1,
      alignment: Alignment.centerRight,
      child: SongMetadataChips(
        analysis: analysis,
        singleLine: true,
        compact: true,
      ),
    );
    return ConstrainedBox(
      key: const ValueKey('track_tile_trailing'),
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: metadata),
          const SizedBox(width: 6),
          actions,
        ],
      ),
    );
  }

  Widget _buildExpandedTextTile(
    BuildContext context, {
    required ThemeData theme,
    required Color activeColor,
    required TextStyle? titleStyle,
    required TextStyle? subtitleStyle,
    required String subtitle,
    required double metadataMaxWidth,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isCurrent ? activeColor.withValues(alpha: 0.10) : null,
        border: isCurrent
            ? Border(left: BorderSide(color: activeColor, width: 3))
            : null,
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading ?? _buildCoverArt(theme),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleStyle,
                      ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        key: const ValueKey('track_tile_trailing'),
                        constraints: BoxConstraints(
                          maxWidth: metadataMaxWidth,
                        ),
                        child: Align(
                          widthFactor: 1,
                          alignment: Alignment.centerRight,
                          child: SongMetadataChips(
                            analysis: analysis,
                            singleLine: true,
                            compact: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _buildTrailingActions(context),
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

  Widget _buildTrailingActions(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      key: const ValueKey('track_tile_actions'),
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 2,
      children: [
        if (trailing != null)
          trailing!
        else ...[
          if (isCurrent && activeLabel != null)
            _NowPlayingBadge(
              label: activeLabel!,
              color: theme.colorScheme.primary,
            )
          else if (isCurrent) ...[
            Icon(Icons.equalizer, size: 18, color: theme.colorScheme.primary),
          ],
          Text(
            duration,
            style: isCurrent
                ? theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  )
                : theme.textTheme.bodySmall,
          ),
          if (onMorePressed != null)
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: onMorePressed,
              iconSize: 20,
            ),
          if (showDragHandle)
            const ReorderableDragStartListener(
              index: 0,
              child: Icon(Icons.drag_handle),
            ),
        ],
      ],
    );
  }
}

class _NowPlayingBadge extends StatelessWidget {
  const _NowPlayingBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Container(
        key: const ValueKey('track_tile_now_playing_badge'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.equalizer, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder widget for cover art - extracted for reuse and const optimization
class _CoverArtPlaceholder extends StatelessWidget {
  final ThemeData theme;

  const _CoverArtPlaceholder({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(Icons.music_note, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
