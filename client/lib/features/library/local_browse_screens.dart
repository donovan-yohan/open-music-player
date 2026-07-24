import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_state.dart';
import '../../core/audio/queue_ordering.dart';
import '../../core/services/api_client.dart';
import '../../core/services/library_service.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/song_metadata_chips.dart';

/// Loads the tracks a local artist/album page should render. Returns the full
/// (already-filtered) track list for the header + list.
typedef LocalTrackLoader = Future<List<Track>> Function();

/// Local artist page: every library track by [artist], backed by
/// `GET /library?artist=`. Play / Shuffle / tap-to-play run the whole list
/// through [PlaybackState.playQueue].
class LocalArtistScreen extends StatelessWidget {
  const LocalArtistScreen({
    super.key,
    required this.artist,
    this.libraryService,
  });

  final String artist;

  /// Injectable for tests; defaults to a real [LibraryService].
  final LibraryService? libraryService;

  @override
  Widget build(BuildContext context) {
    final service = libraryService ?? LibraryService(ApiClient());
    return LocalBrowseView(
      title: artist,
      subtitle: 'Artist',
      loader: () => service.getLibraryByArtist(artist),
    );
  }
}

/// Local album page: every library track on [album], backed by
/// `GET /library?album=`.
class LocalAlbumScreen extends StatelessWidget {
  const LocalAlbumScreen({
    super.key,
    required this.album,
    this.libraryService,
  });

  final String album;

  /// Injectable for tests; defaults to a real [LibraryService].
  final LibraryService? libraryService;

  @override
  Widget build(BuildContext context) {
    final service = libraryService ?? LibraryService(ApiClient());
    return LocalBrowseView(
      title: album,
      subtitle: 'Album',
      loader: () => service.getLibraryByAlbum(album),
    );
  }
}

/// Shared list scaffold for the local artist/album pages: header with Play +
/// Shuffle actions, a track list, and explicit loading / empty / error+retry
/// states.
class LocalBrowseView extends StatefulWidget {
  const LocalBrowseView({
    super.key,
    required this.title,
    required this.subtitle,
    required this.loader,
  });

  final String title;
  final String subtitle;
  final LocalTrackLoader loader;

  @override
  State<LocalBrowseView> createState() => _LocalBrowseViewState();
}

class _LocalBrowseViewState extends State<LocalBrowseView> {
  bool _isLoading = true;
  Object? _error;
  List<Track> _tracks = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final tracks = await widget.loader();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _isLoading = false;
      });
    }
  }

  Future<void> _play({int startIndex = 0, bool shuffle = false}) async {
    if (_tracks.isEmpty) return;
    final ordered = playCollectionOrder(_tracks, shuffled: shuffle);
    final playback = context.read<PlaybackState>();
    try {
      await playback.playQueue(
        ordered.map((t) => t.toPlaybackJson()).toList(),
        startIndex: startIndex,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(playback.playbackError ?? 'Could not start playback.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(
        key: ValueKey('local_browse_loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_error != null) {
      return _buildError(context);
    }
    if (_tracks.isEmpty) {
      return _buildEmpty(context);
    }
    return _buildList(context);
  }

  Widget _buildError(BuildContext context) {
    return Center(
      key: const ValueKey('local_browse_error'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            'Could not load ${widget.subtitle.toLowerCase()}',
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      key: const ValueKey('local_browse_empty'),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_off, size: 64, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            'No tracks found',
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        key: const ValueKey('local_browse_list'),
        itemCount: _tracks.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) return _buildHeader(context);
          final track = _tracks[index - 1];
          return ListTile(
            key: ValueKey('local_track_${track.id}'),
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.music_note),
            ),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              track.displayArtist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SongMetadataChips(
                  analysis: track.analysis,
                  singleLine: true,
                  compact: true,
                ),
                const SizedBox(width: 6),
                Text(
                  track.formattedDuration,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            onTap: () => _play(startIndex: index - 1),
          );
        },
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final count = _tracks.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${widget.subtitle} · $count '
            '${count == 1 ? 'track' : 'tracks'}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('local_browse_play'),
                  onPressed: () => _play(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('local_browse_shuffle'),
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
