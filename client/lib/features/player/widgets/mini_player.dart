import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../../app/theme.dart';
import '../../../core/audio/playback_state.dart';

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
            ? playback.position.inMilliseconds / playback.duration.inMilliseconds
            : 0.0;

        return GestureDetector(
          onTap: () => context.push('/player'),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: AppTheme.darkCard,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 2,
                  backgroundColor: AppTheme.darkSurface,
                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primaryGreen),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
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
                                  errorBuilder: (_, __, ___) => _buildPlaceholder(),
                                )
                              : _buildPlaceholder(),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                style: const TextStyle(
                                  color: AppTheme.lightText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.artist ?? 'Unknown Artist',
                                style: const TextStyle(
                                  color: AppTheme.greyText,
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
                            color: AppTheme.lightText,
                          ),
                          onPressed: playback.togglePlayPause,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 48,
      height: 48,
      color: AppTheme.darkSurface,
      child: const Icon(
        Icons.music_note,
        color: AppTheme.greyText,
        size: 24,
      ),
    );
  }
}
