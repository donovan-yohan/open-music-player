import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../../app/theme.dart';
import '../../core/audio/playback_state.dart';
import '../../core/services/analysis_service.dart';
import '../../core/services/api_client.dart';
import '../../models/track_analysis.dart';
import 'widgets/song_info_sheet.dart';

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
                  playback.playbackContext?.label ??
                      item?.album ??
                      'Unknown Album',
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
                icon: const Icon(Icons.info_outline),
                tooltip: 'Song info',
                onPressed:
                    item == null ? null : () => _showSongInfo(context, item),
              ),
              IconButton(
                icon: const Icon(Icons.queue_music),
                onPressed: () => context.push('/queue'),
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final horizontalPadding =
                          constraints.maxWidth <= 360 ? 20.0 : 32.0;

                      return Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: horizontalPadding),
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
                      );
                    },
                  ),
                ),
        );
      },
    );
  }

  void _showSongInfo(BuildContext context, MediaItem item) {
    final trackId = int.tryParse(item.id);
    final analysisService = AnalysisService(context.read<ApiClient>());
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.darkSurface,
      showDragHandle: false,
      builder: (_) => SongInfoSheet(
        title: item.title,
        artist: item.artist,
        analysisLoader: () {
          if (trackId == null || trackId <= 0) {
            // No numeric track id (e.g. a placeholder item) — surface the
            // read-only "unavailable" state without hitting the API.
            return Future<TrackAnalysis>.error(
              StateError('missing track id'),
            );
          }
          return analysisService.getTrackAnalysis(trackId);
        },
      ),
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
                ? (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0)
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
    return PlaybackControls(
      isPlaying: playback.isPlaying,
      shuffleEnabled: playback.shuffleEnabled,
      loopMode: playback.loopMode,
      onShuffle: playback.toggleShuffle,
      onPrevious: playback.skipToPrevious,
      onPlayPause: playback.togglePlayPause,
      onNext: playback.skipToNext,
      onLoop: playback.cycleLoopMode,
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

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

@visibleForTesting
class PlaybackControls extends StatelessWidget {
  const PlaybackControls({
    super.key,
    required this.isPlaying,
    required this.shuffleEnabled,
    required this.loopMode,
    required this.onShuffle,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onLoop,
  });

  final bool isPlaying;
  final bool shuffleEnabled;
  final LoopMode loopMode;
  final VoidCallback onShuffle;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onLoop;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final playButtonSize = constraints.maxWidth < 296 ? 64.0 : 72.0;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _ControlIconButton(
              icon: Icons.shuffle,
              color: shuffleEnabled ? AppTheme.primaryGreen : AppTheme.greyText,
              iconSize: 28,
              onPressed: onShuffle,
            ),
            _ControlIconButton(
              icon: Icons.skip_previous,
              color: AppTheme.lightText,
              iconSize: 40,
              onPressed: onPrevious,
            ),
            SizedBox.square(
              dimension: playButtonSize,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.lightText,
                ),
                child: IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.black,
                  ),
                  iconSize: playButtonSize < 72 ? 36 : 40,
                  onPressed: onPlayPause,
                ),
              ),
            ),
            _ControlIconButton(
              icon: Icons.skip_next,
              color: AppTheme.lightText,
              iconSize: 40,
              onPressed: onNext,
            ),
            _ControlIconButton(
              icon: _loopIcon(loopMode),
              color: loopMode != LoopMode.off
                  ? AppTheme.primaryGreen
                  : AppTheme.greyText,
              iconSize: 28,
              onPressed: onLoop,
            ),
          ],
        );
      },
    );
  }

  static IconData _loopIcon(LoopMode mode) {
    switch (mode) {
      case LoopMode.one:
        return Icons.repeat_one;
      case LoopMode.all:
      case LoopMode.off:
        return Icons.repeat;
    }
  }
}

class _ControlIconButton extends StatelessWidget {
  const _ControlIconButton({
    required this.icon,
    required this.color,
    required this.iconSize,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final double iconSize;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: Icon(icon, color: color),
        iconSize: iconSize,
        onPressed: onPressed,
      ),
    );
  }
}
