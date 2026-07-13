import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../../app/theme.dart';
import '../../core/audio/playback_context.dart';
import '../../core/audio/playback_state.dart';
import '../../core/services/analysis_service.dart';
import '../../core/services/api_client.dart';
import '../../models/track_analysis.dart';
import 'widgets/song_info_sheet.dart';

enum _PlayerTimeMode { song, queue }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  _PlayerTimeMode _timeMode = _PlayerTimeMode.song;

  @override
  Widget build(BuildContext context) {
    return Consumer<PlaybackState>(
      builder: (context, playback, _) {
        final colors = Theme.of(context).colorScheme;
        final item = playback.currentItem;
        final queueModeAvailable = _queueModeAvailable(playback);
        final activeTimeMode =
            queueModeAvailable ? _timeMode : _PlayerTimeMode.song;

        return Scaffold(
          backgroundColor: Theme.of(context).colorScheme.surface,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Column(
              children: [
                Text(
                  'PLAYING FROM',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  playback.playbackContext?.label ??
                      item?.album ??
                      'Unknown Album',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
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
                // Queue lives inside the ShellRoute (_shellNavigatorKey). Using
                // push() from this root-level player route re-instantiates the
                // shell navigator, reserving that GlobalKey twice and tripping
                // navigator.dart's keyReservation assertion. go() switches to
                // the queue tab on the single shell, matching the mini-player.
                onPressed: () => context.go('/queue'),
              ),
            ],
          ),
          body: item == null
              ? Center(
                  child: Text(
                    'No track playing',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
                            _buildAlbumArt(context, item.artUri?.toString()),
                            const Spacer(flex: 1),
                            _buildTrackInfo(
                              context,
                              _displayTitle(item, playback, activeTimeMode),
                              _displaySubtitle(playback, activeTimeMode),
                            ),
                            if (playback
                                .snapshot.pitchPreservationFallback) ...[
                              const SizedBox(height: 12),
                              _buildPitchFallbackWarning(context),
                            ],
                            const SizedBox(height: 24),
                            _buildProgressBar(
                              context,
                              playback,
                              activeTimeMode,
                              queueModeAvailable: queueModeAvailable,
                            ),
                            const SizedBox(height: 24),
                            _buildControls(playback),
                            const SizedBox(height: 16),
                            _buildSecondaryControls(context),
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

  Widget _buildPitchFallbackWarning(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final warning = SoundQPlayerTheme.of(context).queuePending;
    return Container(
      key: const ValueKey('player_pitch_fallback_warning'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: warning.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.tune,
            size: 18,
            color: warning,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Pitch lock unavailable. Tempo match may alter pitch.',
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  bool _queueModeAvailable(PlaybackState playback) {
    final snapshot = playback.snapshot;
    return snapshot.globalDuration.inMilliseconds > 0 &&
        (playback.queue.length > 1 ||
            playback.playbackContext != null ||
            snapshot.globalDuration != playback.duration);
  }

  void _showSongInfo(BuildContext context, MediaItem item) {
    final trackId = int.tryParse(item.id);
    final analysisService = AnalysisService(context.read<ApiClient>());
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
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

  Widget _buildAlbumArt(BuildContext context, String? artUrl) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
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
                  errorBuilder: (_, __, ___) => _buildArtPlaceholder(context),
                )
              : _buildArtPlaceholder(context),
        ),
      ),
    );
  }

  Widget _buildArtPlaceholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('player_art_placeholder'),
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note,
          size: 80,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }

  String _displayTitle(
    MediaItem item,
    PlaybackState playback,
    _PlayerTimeMode mode,
  ) {
    if (mode == _PlayerTimeMode.queue) {
      return playback.playbackContext?.label ?? 'Playback Queue';
    }
    return item.title;
  }

  String? _displaySubtitle(PlaybackState playback, _PlayerTimeMode mode) {
    final item = playback.currentItem;
    if (mode == _PlayerTimeMode.song) {
      return item?.artist ?? 'Unknown Artist';
    }

    final count = playback.queue.length;
    final kind = switch (playback.playbackContext?.kind) {
      PlaybackContextKind.playlist => 'Playlist',
      PlaybackContextKind.album => 'Album',
      PlaybackContextKind.artist => 'Artist',
      PlaybackContextKind.library => 'Library',
      PlaybackContextKind.queue => 'Queue',
      PlaybackContextKind.search => 'Search',
      null => 'Queue',
    };
    if (count <= 0) return kind;
    final countLabel = count == 1 ? '1 track' : '$count tracks';
    return '$kind · $countLabel';
  }

  Widget _buildTrackInfo(
    BuildContext context,
    String title,
    String? artist,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          title,
          key: const ValueKey('player_track_title'),
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: colors.onSurface,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        Text(
          artist ?? 'Unknown Artist',
          key: const ValueKey('player_track_artist'),
          style: TextStyle(
            fontSize: 16,
            color: colors.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildProgressBar(
    BuildContext context,
    PlaybackState playback,
    _PlayerTimeMode mode, {
    required bool queueModeAvailable,
  }) {
    final snapshot = playback.snapshot;
    final colors = Theme.of(context).colorScheme;
    final playerTheme = SoundQPlayerTheme.of(context);
    final position = mode == _PlayerTimeMode.queue
        ? snapshot.globalPosition
        : playback.position;
    final duration = mode == _PlayerTimeMode.queue
        ? snapshot.globalDuration
        : playback.duration;
    final canSeek = duration.inMilliseconds > 0;

    Duration positionForValue(double value) {
      return Duration(
        milliseconds: (value * duration.inMilliseconds).round(),
      );
    }

    return Column(
      children: [
        if (queueModeAvailable) ...[
          SegmentedButton<_PlayerTimeMode>(
            key: const ValueKey('player_time_mode_switch'),
            segments: const [
              ButtonSegment(
                value: _PlayerTimeMode.song,
                icon: Icon(Icons.music_note),
                label: Text('Song'),
              ),
              ButtonSegment(
                value: _PlayerTimeMode.queue,
                icon: Icon(Icons.queue_music),
                label: Text('Queue'),
              ),
            ],
            selected: {mode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              setState(() => _timeMode = selection.single);
            },
          ),
          const SizedBox(height: 12),
        ],
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: playerTheme.playhead,
            inactiveTrackColor: playerTheme.waveformBase,
            thumbColor: colors.onSurface,
            overlayColor: playerTheme.selection,
          ),
          child: Slider(
            value: canSeek
                ? (position.inMilliseconds / duration.inMilliseconds)
                    .clamp(0.0, 1.0)
                : 0.0,
            onChangeStart: canSeek
                ? (_) {
                    if (mode == _PlayerTimeMode.queue) {
                      playback.beginTimelineScrub();
                    } else {
                      playback.beginLocalScrub();
                    }
                  }
                : null,
            onChanged: canSeek
                ? (value) {
                    final target = positionForValue(value);
                    if (mode == _PlayerTimeMode.queue) {
                      playback.updateTimelineScrub(target.inMilliseconds);
                    } else {
                      playback.updateLocalScrub(target);
                    }
                  }
                : null,
            onChangeEnd: canSeek
                ? (value) {
                    final target = positionForValue(value);
                    if (mode == _PlayerTimeMode.queue) {
                      unawaited(
                        playback.endTimelineScrub(target.inMilliseconds),
                      );
                    } else {
                      unawaited(playback.endLocalScrub(target));
                    }
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(position),
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                ),
              ),
              Text(
                _formatDuration(duration),
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
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
      onPrevious: playback.previous,
      onPlayPause: playback.togglePlayPause,
      onNext: playback.skipToNext,
      onLoop: playback.cycleLoopMode,
    );
  }

  Widget _buildSecondaryControls(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          icon: Icon(Icons.devices, color: color),
          onPressed: () {},
        ),
        IconButton(
          icon: Icon(Icons.favorite_border, color: color),
          onPressed: () {},
        ),
        IconButton(
          icon: Icon(Icons.share, color: color),
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
    final colors = Theme.of(context).colorScheme;
    final playerTheme = SoundQPlayerTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final playButtonSize = constraints.maxWidth < 296 ? 64.0 : 72.0;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _ControlIconButton(
              icon: Icons.shuffle,
              color: shuffleEnabled
                  ? playerTheme.playhead
                  : colors.onSurfaceVariant,
              iconSize: 28,
              onPressed: onShuffle,
            ),
            _ControlIconButton(
              icon: Icons.skip_previous,
              color: colors.onSurface,
              iconSize: 40,
              onPressed: onPrevious,
            ),
            SizedBox.square(
              dimension: playButtonSize,
              child: DecoratedBox(
                key: const ValueKey('player_play_pause_surface'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.onSurface,
                ),
                child: IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: colors.surface,
                  ),
                  iconSize: playButtonSize < 72 ? 36 : 40,
                  onPressed: onPlayPause,
                ),
              ),
            ),
            _ControlIconButton(
              icon: Icons.skip_next,
              color: colors.onSurface,
              iconSize: 40,
              onPressed: onNext,
            ),
            _ControlIconButton(
              icon: _loopIcon(loopMode),
              color: loopMode != LoopMode.off
                  ? playerTheme.playhead
                  : colors.onSurfaceVariant,
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
