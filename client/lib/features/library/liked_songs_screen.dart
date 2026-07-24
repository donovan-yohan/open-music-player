import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_context.dart';
import '../../core/audio/playback_state.dart';
import '../../core/services/services.dart' as services;
import '../../core/services/liked_tracks_state.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/queue_swipe_action.dart';
import '../../shared/widgets/track_tile.dart';

/// The Liked Songs collection: every favorite track (`GET /library?liked=true`)
/// with a count header and Play / Shuffle actions that stream the whole
/// collection into the listening queue. Reached from a card at the top of the
/// Library screen.
class LikedSongsScreen extends StatefulWidget {
  const LikedSongsScreen({super.key, this.libraryService});

  /// Injectable for tests; defaults to a real service over the parser-based
  /// [services.ApiClient], mirroring how the Library screen builds its client.
  final services.LibraryService? libraryService;

  @override
  State<LikedSongsScreen> createState() => _LikedSongsScreenState();
}

class _LikedSongsScreenState extends State<LikedSongsScreen> {
  late final services.LibraryService _libraryService =
      widget.libraryService ?? services.LibraryService(services.ApiClient());

  List<Track> _tracks = const [];
  int _total = 0;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    try {
      final page = await _libraryService.getLikedSongs();
      if (!mounted) return;
      context.read<LikedTracksState>().seed(page.tracks);
      setState(() {
        _tracks = page.tracks;
        _total = page.total;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  PlaybackContext get _likedContext => const PlaybackContext(
        kind: PlaybackContextKind.library,
        label: 'Liked Songs',
      );

  Future<void> _play({bool shuffle = false}) async {
    if (_tracks.isEmpty) return;
    final ordered = List<Track>.from(_tracks);
    if (shuffle) ordered.shuffle(Random());
    final playback = context.read<PlaybackState>();
    try {
      await playback.playQueue(
        ordered.map((t) => t.toPlaybackJson()).toList(),
        context: _likedContext,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(playback.playbackError ?? 'Could not play Liked Songs.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Liked Songs')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hasError) {
      return _ErrorState(onRetry: _load);
    }
    if (_tracks.isEmpty) {
      return const _EmptyState();
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _tracks.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _buildHeader(context);
          final track = _tracks[index - 1];
          final currentTrackId = context.watch<PlaybackState>().currentItem?.id;
          final liked =
              context.watch<LikedTracksState>().isLiked(track.id) ?? false;
          return QueueSwipeAction(
            actionKey: ValueKey('liked_queue_${track.id}_${index - 1}'),
            onAddToQueue: () => _enqueueTrack(track),
            child: TrackTile.fromTrack(
              track,
              isCurrent: currentTrackId == track.id.toString(),
              onTap: () => _playFrom(index - 1),
              trailing: IconButton(
                key: ValueKey('liked_song_heart_${track.id}'),
                icon: Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                ),
                tooltip: liked ? 'Unlike' : 'Like',
                onPressed: () => _toggleLike(track.id),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _toggleLike(int trackId) async {
    try {
      await context.read<LikedTracksState>().toggle(trackId);
      // Deliberately retain this fetched collection's membership until the
      // next refresh so unliking does not remove a row mid-scroll.
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update liked status')),
      );
    }
  }

  Future<void> _enqueueTrack(Track track) async {
    final playback = context.read<PlaybackState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await playback.enqueue(track.toPlaybackJson());
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Added "${track.title}" to queue')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add to queue')),
      );
    }
  }

  Future<void> _playFrom(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final playback = context.read<PlaybackState>();
    try {
      await playback.playQueue(
        _tracks.map((t) => t.toPlaybackJson()).toList(),
        startIndex: index,
        context: _likedContext,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(playback.playbackError ?? 'Could not play this track.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final count = _total > 0 ? _total : _tracks.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.favorite, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                count == 1 ? '1 liked song' : '$count liked songs',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _play(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _play(shuffle: true),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Shuffle'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.favorite_border, size: 64, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            'No liked songs yet',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap the heart on a track to add it here',
            style: TextStyle(color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            'Could not load Liked Songs',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
