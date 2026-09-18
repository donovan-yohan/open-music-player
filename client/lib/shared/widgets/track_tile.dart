import 'now_playing_row.dart';
import 'package:flutter/material.dart';
import '../../models/track_analysis.dart';
import '../models/track.dart';
import 'song_metadata_chips.dart';
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
    final theme = Theme.of(context);
    final titleStyle =
        ListTileTheme.of(context).titleTextStyle ?? theme.textTheme.bodyLarge;
    final subtitleStyle = theme.textTheme.bodySmall;
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
        // Playback selection must not replace the action/focus subtree.
        // Reserve readable metadata and large-text space even when neutral.
        final useExpandedLayout = hasMetadata || enlargedText;

        if (useExpandedLayout) {
          final expandedMetadataMaxWidth =
              (availableWidth * 0.55).clamp(150.0, 220.0).toDouble();
          return _buildExpandedTextTile(
            context,
            theme: theme,
            titleStyle: titleStyle,
            subtitleStyle: subtitleStyle,
            subtitle: subtitle,
            metadataMaxWidth: expandedMetadataMaxWidth,
          );
        }

        return ListTile(
          onTap: onTap,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: leading ?? _buildCoverArt(),
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
        );
      },
    );
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
    required TextStyle? titleStyle,
    required TextStyle? subtitleStyle,
    required String subtitle,
    required double metadataMaxWidth,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            leading ?? _buildCoverArt(),
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
        if (SongRowTreatment.presentationOf(context) !=
            SongRowPresentation.none)
          const SongRowStatusBadge(),
        if (trailing != null)
          trailing!
        else ...[
          if (action != null) action!,
          Text(
            duration,
            style: theme.textTheme.bodySmall,
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
