import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/api/api_client.dart';
import '../../../core/audio/playback_context.dart';
import '../../../core/audio/playback_state.dart';
import '../../../core/audio/player_presentation.dart';
import '../../../core/services/playlist_service.dart';
import '../../playlists/add_to_playlist.dart';
import 'playback_context_label.dart';
import 'radio_waiting.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.playlistService});

  /// Injectable for tests; defaults to a service over the app-wide
  /// [ApiClient], matching how the library rows build theirs.
  final PlaylistService? playlistService;

  @override
  Widget build(BuildContext context) {
    // The sheet is presented from this context, above the dark chrome the
    // mobile bar wraps itself in below, so the picker keeps the app's theme.
    final hostContext = context;
    // Everything except the progress bar changes only when the track or the
    // play/pause state changes. Rebuilding the whole mini player on every
    // position tick added avoidable per-frame work to every screen that shows
    // it — including the library list while it is being scrolled.
    final miniPlayer = Selector<PlaybackState, _MiniPlayerSnapshot>(
      selector: (_, playback) => _MiniPlayerSnapshot(
        presentation: PlayerPresentation.fromSnapshot(playback.snapshot),
        hasTrack: playback.hasTrack,
        item: playback.currentItem,
        isPlaying: playback.isPlaying,
        isPending: playback.isResolvingSignedUrl,
        playbackContext: playback.playbackContext,
      ),
      builder: (context, snapshot, _) {
        if (snapshot.isPending ||
            snapshot.presentation == PlayerPresentation.waiting) {
          return Container(
            key: const ValueKey('pending_mini_player'),
            constraints: const BoxConstraints(minHeight: 64),
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: ExcludeSemantics(child: CircularProgressIndicator()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PlaybackContextLabel(snapshot.playbackContext),
                        Text(snapshot.presentation == PlayerPresentation.waiting
                            ? snapshot.presentation.label
                            : 'Starting playback…'),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: snapshot.presentation == PlayerPresentation.waiting
                      ? 'Cancel'
                      : 'Cancel playback',
                  constraints:
                      const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      cancelRadio(hostContext, context.read<PlaybackState>()),
                ),
              ],
            ),
          );
        }
        if (!snapshot.hasTrack || snapshot.item == null) {
          return const SizedBox.shrink();
        }

        final item = snapshot.item!;

        final colors = Theme.of(context).colorScheme;
        final playerTheme = SoundQPlayerTheme.of(context);
        final isMobilePoster = MediaQuery.sizeOf(context).width < 960;
        return GestureDetector(
          onTap: () => context.push('/player'),
          // A long press instead of another always-visible icon: the bar is
          // four controls wide already and grows with the text scale.
          onLongPress: () => _addToPlaylist(hostContext, item.id),
          child: Container(
            key: const ValueKey('spotify_like_mini_player'),
            constraints: const BoxConstraints(minHeight: 64),
            margin: isMobilePoster
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(8, 0, 8, 8),
            decoration: isMobilePoster
                ? const BoxDecoration(
                    color: AppTheme.surfaceRaised,
                    border: Border(top: BorderSide(color: AppTheme.outline)),
                  )
                : BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _MiniPlayerProgressBar(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(
                          isMobilePoster ? 0 : 4,
                        ),
                        child: item.artUri != null
                            ? Image.network(
                                item.artUri.toString(),
                                width: 48,
                                height: 48,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    _buildPlaceholder(context),
                              )
                            : _buildPlaceholder(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (snapshot.presentation ==
                                PlayerPresentation.ended)
                              Semantics(
                                  liveRegion: true,
                                  child: const Text('Queue ended')),
                            PlaybackContextLabel(
                              snapshot.playbackContext,
                              style: TextStyle(
                                color: playerTheme.playhead,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0,
                              ),
                            ),
                            Text(
                              item.title,
                              style: TextStyle(
                                color: colors.onSurface,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.artist ?? 'Unknown Artist',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          snapshot.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: isMobilePoster
                              ? AppTheme.background
                              : colors.onSurface,
                        ),
                        tooltip: snapshot.presentation.actionLabel,
                        onPressed:
                            snapshot.presentation == PlayerPresentation.ended
                                ? context.read<PlaybackState>().play
                                : context.read<PlaybackState>().togglePlayPause,
                        style: isMobilePoster
                            ? IconButton.styleFrom(
                                backgroundColor: AppTheme.orange,
                              )
                            : null,
                      ),
                      IconButton(
                        icon: Icon(Icons.queue_music, color: colors.onSurface),
                        tooltip: 'Open queue',
                        onPressed: () => context.go('/queue'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (MediaQuery.sizeOf(context).width >= 960) return miniPlayer;
    return Theme(data: AppTheme.darkTheme, child: miniPlayer);
  }

  /// Source-backed queue items play before the backend has a track row, so a
  /// non-numeric media id means there is nothing a playlist could reference.
  void _addToPlaylist(BuildContext context, String mediaItemId) {
    final trackId = int.tryParse(mediaItemId);
    if (trackId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This track is not in your library yet')),
      );
      return;
    }
    unawaited(
      showAddToPlaylistSheet(
        context,
        playlistService:
            playlistService ?? PlaylistService(api: context.read<ApiClient>()),
        trackIds: [trackId],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 48,
      height: 48,
      color: colors.surfaceContainerHighest,
      child: Icon(Icons.music_note, color: colors.onSurfaceVariant, size: 24),
    );
  }
}

/// The fields the mini player chrome renders, so a position tick that changes
/// none of them does not rebuild it.
class _MiniPlayerSnapshot {
  const _MiniPlayerSnapshot({
    required this.presentation,
    required this.hasTrack,
    required this.item,
    required this.isPlaying,
    required this.isPending,
    required this.playbackContext,
  });

  final PlayerPresentation presentation;
  final bool hasTrack;
  final MediaItem? item;
  final bool isPlaying;
  final bool isPending;
  final PlaybackContext? playbackContext;

  @override
  bool operator ==(Object other) =>
      other is _MiniPlayerSnapshot &&
      other.presentation == presentation &&
      other.hasTrack == hasTrack &&
      other.isPlaying == isPlaying &&
      other.isPending == isPending &&
      other.playbackContext == playbackContext &&
      other.item?.id == item?.id &&
      other.item?.title == item?.title &&
      other.item?.artist == item?.artist &&
      other.item?.artUri == item?.artUri;

  @override
  int get hashCode => Object.hash(
        presentation,
        hasTrack,
        isPlaying,
        isPending,
        playbackContext,
        item?.id,
        item?.title,
        item?.artist,
        item?.artUri,
      );
}

/// The only part of the mini player that follows the playback position.
class _MiniPlayerProgressBar extends StatelessWidget {
  const _MiniPlayerProgressBar();

  @override
  Widget build(BuildContext context) {
    final playerTheme = SoundQPlayerTheme.of(context);
    final progress = context.select<PlaybackState, double>((playback) {
      final total = playback.duration.inMilliseconds;
      if (total <= 0) return 0;
      return (playback.position.inMilliseconds / total).clamp(0.0, 1.0);
    });
    return LinearProgressIndicator(
      value: progress,
      minHeight: 2,
      backgroundColor: playerTheme.waveformBase,
      valueColor: AlwaysStoppedAnimation<Color>(playerTheme.playhead),
    );
  }
}
