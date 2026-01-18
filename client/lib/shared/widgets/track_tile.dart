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
  });

  factory TrackTile.fromTrack(
    Track track, {
    VoidCallback? onTap,
    VoidCallback? onMorePressed,
    Widget? leading,
    Widget? trailing,
    bool showDragHandle = false,
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
    );
  }

  factory TrackTile.fromLibraryTrack(
    LibraryTrack track, {
    VoidCallback? onTap,
    VoidCallback? onMorePressed,
    Widget? leading,
    Widget? trailing,
    bool showDragHandle = false,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: leading ?? _buildCoverArt(theme),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        [artist, album].where((s) => s != null && s.isNotEmpty).join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: trailing ?? _buildTrailing(context),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          duration,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (onMorePressed != null)
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: onMorePressed,
            iconSize: 20,
          ),
        if (showDragHandle)
          ReorderableDragStartListener(
            index: 0,
            child: const Icon(Icons.drag_handle),
          ),
      ],
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
