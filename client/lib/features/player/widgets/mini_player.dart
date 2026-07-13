import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/audio/playback_state.dart';
import 'playback_context_label.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlaybackState>(
      builder: (context, playback, _) {
        if (!playback.hasTrack) {
          return const SizedBox.shrink();
        }

        final item = playback.currentItem!;
        final progress = playback.duration.inMilliseconds > 0
            ? playback.position.inMilliseconds /
                playback.duration.inMilliseconds
            : 0.0;

        final colors = Theme.of(context).colorScheme;
        final playerTheme = SoundQPlayerTheme.of(context);
        return GestureDetector(
          onTap: () => context.push('/player'),
          child: Container(
            key: const ValueKey('spotify_like_mini_player'),
            constraints: const BoxConstraints(minHeight: 64),
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 2,
                  backgroundColor: playerTheme.waveformBase,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(playerTheme.playhead),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
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
                              playback.playbackContext,
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
                          playback.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: colors.onSurface,
                        ),
                        tooltip: playback.isPlaying ? 'Pause' : 'Play',
                        onPressed: playback.togglePlayPause,
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.queue_music,
                          color: colors.onSurface,
                        ),
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
