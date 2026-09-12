import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/audio/playback_context.dart';
import '../../../core/audio/playback_state.dart';
import 'playback_context_label.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Everything except the progress bar changes only when the track or the
    // play/pause state changes. Rebuilding the whole mini player on every
    // position tick added avoidable per-frame work to every screen that shows
    // it — including the library list while it is being scrolled.
    final miniPlayer = Selector<PlaybackState, _MiniPlayerSnapshot>(
      selector: (_, playback) => _MiniPlayerSnapshot(
        hasTrack: playback.hasTrack,
        item: playback.currentItem,
        isPlaying: playback.isPlaying,
        playbackContext: playback.playbackContext,
      ),
      builder: (context, snapshot, _) {
        if (!snapshot.hasTrack || snapshot.item == null) {
          return const SizedBox.shrink();
        }

        final item = snapshot.item!;

        final colors = Theme.of(context).colorScheme;
        final playerTheme = SoundQPlayerTheme.of(context);
        final isMobilePoster = MediaQuery.sizeOf(context).width < 960;
        return GestureDetector(
          onTap: () => context.push('/player'),
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
                        tooltip: snapshot.isPlaying ? 'Pause' : 'Play',
                        onPressed:
                            context.read<PlaybackState>().togglePlayPause,
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
    required this.hasTrack,
    required this.item,
    required this.isPlaying,
    required this.playbackContext,
  });

  final bool hasTrack;
  final MediaItem? item;
  final bool isPlaying;
  final PlaybackContext? playbackContext;

  @override
  bool operator ==(Object other) =>
      other is _MiniPlayerSnapshot &&
      other.hasTrack == hasTrack &&
      other.isPlaying == isPlaying &&
      other.playbackContext == playbackContext &&
      other.item?.id == item?.id &&
      other.item?.title == item?.title &&
      other.item?.artist == item?.artist &&
      other.item?.artUri == item?.artUri;

  @override
  int get hashCode => Object.hash(
        hasTrack,
        isPlaying,
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
