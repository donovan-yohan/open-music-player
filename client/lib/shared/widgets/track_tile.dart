import 'now_playing_row.dart';
import 'package:flutter/material.dart';
import '../../models/track_analysis.dart';
import '../models/track.dart';
import 'song_list_item.dart';
import 'track_artwork.dart';

class TrackTile extends StatelessWidget {
  final String? trackId;
  final String? queueItemId;
  final String title;
  final String? artist;
  final String? album;
  final String duration;
  final String? coverArtUrl;
  final TrackArtworkKind? artworkKind;
  final VoidCallback? onTap;
  final VoidCallback? onMorePressed;
  final Widget? leading;
  final Widget? trailing;

  /// An extra row action (a like heart, say) rendered alongside the default
  /// duration/more affordances. Unlike [trailing] it augments them instead of
  /// replacing them, so a surface can add a heart without re-implementing the
  /// duration text.
  final Widget? action;
  final bool showDragHandle;
  final TrackAnalysis? analysis;

  const TrackTile({
    super.key,
    required this.title,
    this.trackId,
    this.queueItemId,
    this.artist,
    this.album,
    required this.duration,
    this.coverArtUrl,
    this.artworkKind,
    this.onTap,
    this.onMorePressed,
    this.leading,
    this.trailing,
    this.action,
    this.showDragHandle = false,
    this.analysis,
  });

  factory TrackTile.fromTrack(
    Track track, {
    VoidCallback? onTap,
    VoidCallback? onMorePressed,
    Widget? leading,
    Widget? trailing,
    Widget? action,
    bool showDragHandle = false,
  }) {
    return TrackTile(
      trackId: track.id.toString(),
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: track.formattedDuration,
      coverArtUrl: track.displayArtworkUrl,
      artworkKind: track.artworkKind,
      onTap: onTap,
      onMorePressed: onMorePressed,
      leading: leading,
      trailing: trailing,
      action: action,
      showDragHandle: showDragHandle,
      analysis: track.analysis,
    );
  }

  @override
  Widget build(BuildContext context) {
    return NowPlayingRow(
      trackId: trackId,
      queueItemId: queueItemId,
      child: Builder(builder: _buildContent),
    );
  }

  Widget _buildContent(BuildContext context) {
    final subtitle = [artist, album]
        .where((value) => value != null && value.isNotEmpty)
        .join(' • ');
    return LayoutBuilder(
        builder: (context, constraints) => SongListItem(
              onTap: onTap,
              leading: leading ?? _buildCoverArt(),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: subtitle.isEmpty
                  ? null
                  : Text(subtitle,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              analysis: analysis,
              trailing: _buildTrailingActions(context,
                  hideDuration: constraints.maxWidth < 360 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.3 &&
                      analysis != null &&
                      action != null &&
                      onMorePressed != null),
            ));
  }

  Widget _buildCoverArt() {
    final resolvedKind = artworkKind ??
        (safeTrackArtworkUrl(coverArtUrl) == null
            ? TrackArtworkKind.none
            : TrackArtworkKind.coverArt);
    return TrackArtwork(
      url: coverArtUrl,
      kind: resolvedKind,
      cacheKey: '${resolvedKind.wireValue}:${coverArtUrl ?? "none"}',
    );
  }

  Widget _buildTrailingActions(BuildContext context,
      {bool hideDuration = false}) {
    final theme = Theme.of(context);

    return Semantics(
        container: true,
        label: hideDuration ? duration : null,
        child: Wrap(
          key: const ValueKey('track_tile_actions'),
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 2,
          children: [
            if (trailing != null)
              trailing!
            else ...[
              if (action != null) action!,
              // Keep both buttons and a readable key at narrow phone widths.
              // Duration remains exposed to assistive technology.
              if (!hideDuration)
                Text(duration, style: theme.textTheme.bodySmall),
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
        ));
  }
}
