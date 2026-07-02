import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/track.dart';
import '../models/library_track.dart';

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

    return Container(
      decoration: BoxDecoration(
        color: isCurrent ? activeColor.withValues(alpha: 0.10) : null,
        border: isCurrent
            ? Border(left: BorderSide(color: activeColor, width: 3))
            : null,
      ),
      child: ListTile(
        onTap: onTap,
        selected: isCurrent,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.28,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: leading ?? _buildCoverArt(theme),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        subtitle: Text(
          [artist, album].where((s) => s != null && s.isNotEmpty).join(' • '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: subtitleStyle,
        ),
        trailing: trailing ?? _buildTrailing(context),
      ),
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

  Widget _buildTrailing(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isCurrent && activeLabel != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _NowPlayingBadge(
              label: activeLabel!,
              color: theme.colorScheme.primary,
            ),
          )
        else if (isCurrent) ...[
          Icon(
            Icons.equalizer,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
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
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
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
      child: Icon(
        Icons.music_note,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
