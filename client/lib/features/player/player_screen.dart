import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../../app/theme.dart';
import '../../core/audio/playback_state.dart';

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlaybackState>(
      builder: (context, playback, _) {
        final item = playback.currentItem;

        return Scaffold(
          backgroundColor: AppTheme.darkBackground,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Column(
              children: [
                const Text(
                  'PLAYING FROM',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.greyText,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  item?.album ?? 'Unknown Album',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            centerTitle: true,
            actions: [
              IconButton(
                icon: const Icon(Icons.queue_music),
                onPressed: () {
                  _showQueueSheet(context, playback);
                },
              ),
            ],
          ),
          body: item == null
              ? const Center(
                  child: Text(
                    'No track playing',
                    style: TextStyle(color: AppTheme.greyText),
                  ),
                )
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        const Spacer(flex: 1),
                        _buildAlbumArt(item.artUri?.toString()),
                        const Spacer(flex: 1),
                        _buildTrackInfo(item.title, item.artist),
                        const SizedBox(height: 24),
                        _buildProgressBar(playback),
                        const SizedBox(height: 24),
                        _buildControls(playback),
                        const SizedBox(height: 16),
                        _buildSecondaryControls(playback),
                        const Spacer(flex: 1),
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _buildAlbumArt(String? artUrl) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: artUrl != null
              ? Image.network(
                  artUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildArtPlaceholder(),
                )
              : _buildArtPlaceholder(),
        ),
      ),
    );
  }

  Widget _buildArtPlaceholder() {
    return Container(
      color: AppTheme.darkCard,
      child: const Center(
        child: Icon(
          Icons.music_note,
          size: 80,
          color: AppTheme.greyText,
        ),
      ),
    );
  }

  Widget _buildTrackInfo(String title, String? artist) {
    return Column(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: AppTheme.lightText,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          artist ?? 'Unknown Artist',
          style: const TextStyle(
            fontSize: 16,
            color: AppTheme.greyText,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildProgressBar(PlaybackState playback) {
    final position = playback.position;
    final duration = playback.duration;

    return Column(
      children: [
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: AppTheme.primaryGreen,
            inactiveTrackColor: AppTheme.darkCard,
            thumbColor: AppTheme.lightText,
            overlayColor: AppTheme.primaryGreen.withOpacity(0.2),
          ),
          child: Slider(
            value: duration.inMilliseconds > 0
                ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                : 0.0,
            onChanged: (value) {
              final newPosition = Duration(
                milliseconds: (value * duration.inMilliseconds).round(),
              );
              playback.seek(newPosition);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(position),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.greyText,
                ),
              ),
              Text(
                _formatDuration(duration),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.greyText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls(PlaybackState playback) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(
            Icons.shuffle,
            color: playback.shuffleEnabled
                ? AppTheme.primaryGreen
                : AppTheme.greyText,
          ),
          iconSize: 28,
          onPressed: playback.toggleShuffle,
        ),
        IconButton(
          icon: const Icon(Icons.skip_previous, color: AppTheme.lightText),
          iconSize: 40,
          onPressed: playback.skipToPrevious,
        ),
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.lightText,
          ),
          child: IconButton(
            icon: Icon(
              playback.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.black,
            ),
            iconSize: 40,
            onPressed: playback.togglePlayPause,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.skip_next, color: AppTheme.lightText),
          iconSize: 40,
          onPressed: playback.skipToNext,
        ),
        IconButton(
          icon: Icon(
            _getLoopIcon(playback.loopMode),
            color: playback.loopMode != LoopMode.off
                ? AppTheme.primaryGreen
                : AppTheme.greyText,
          ),
          iconSize: 28,
          onPressed: playback.cycleLoopMode,
        ),
      ],
    );
  }

  Widget _buildSecondaryControls(PlaybackState playback) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: const Icon(Icons.devices, color: AppTheme.greyText),
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.favorite_border, color: AppTheme.greyText),
          onPressed: () {},
        ),
        IconButton(
          icon: const Icon(Icons.share, color: AppTheme.greyText),
          onPressed: () {},
        ),
      ],
    );
  }

  IconData _getLoopIcon(LoopMode mode) {
    switch (mode) {
      case LoopMode.one:
        return Icons.repeat_one;
      case LoopMode.all:
      case LoopMode.off:
        return Icons.repeat;
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _showQueueSheet(BuildContext context, PlaybackState playback) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.darkSurface,
      builder: (context) {
        return SafeArea(
          child: Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.greyText,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Queue',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.lightText,
                  ),
                ),
              ),
              Expanded(
                child: playback.queue.isEmpty
                    ? const Center(
                        child: Text(
                          'Queue is empty',
                          style: TextStyle(color: AppTheme.greyText),
                        ),
                      )
                    : ListView.builder(
                        itemCount: playback.queue.length,
                        itemBuilder: (context, index) {
                          final item = playback.queue[index];
                          final isCurrentTrack = index == playback.currentIndex;

                          return ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: item.artUri != null
                                  ? Image.network(
                                      item.artUri.toString(),
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          _buildQueuePlaceholder(),
                                    )
                                  : _buildQueuePlaceholder(),
                            ),
                            title: Text(
                              item.title,
                              style: TextStyle(
                                color: isCurrentTrack
                                    ? AppTheme.primaryGreen
                                    : AppTheme.lightText,
                                fontWeight: isCurrentTrack
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              item.artist ?? 'Unknown Artist',
                              style: const TextStyle(color: AppTheme.greyText),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isCurrentTrack
                                ? const Icon(
                                    Icons.equalizer,
                                    color: AppTheme.primaryGreen,
                                  )
                                : null,
                            onTap: () {
                              playback.skipToIndex(index);
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQueuePlaceholder() {
    return Container(
      width: 48,
      height: 48,
      color: AppTheme.darkCard,
      child: const Icon(
        Icons.music_note,
        color: AppTheme.greyText,
        size: 24,
      ),
    );
  }
}
