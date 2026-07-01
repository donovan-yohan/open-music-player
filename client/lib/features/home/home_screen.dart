import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_state.dart';
import '../../core/errors/error_widgets.dart';
import '../../core/services/api_client.dart';
import '../../shared/models/models.dart';
import '../../core/services/home_service.dart';
import 'home_state.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.homeService});

  /// Injectable for tests; defaults to a real, auth-aware [HomeService].
  final HomeService? homeService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeService _service =
      widget.homeService ?? HomeService(ApiClient());

  HomeState _state = const HomeState.loading();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() => _state = const HomeState.loading());
    }
    try {
      final results = await Future.wait([
        _service.recentlyPlayed(),
        _service.topTracks(),
        _service.playlists(),
      ]);
      if (!mounted) return;
      setState(() {
        _state = HomeState.loaded(
          HomeSections(
            recentlyPlayed: results[0] as List<Track>,
            topTracks: results[1] as List<Track>,
            playlists: results[2] as List<Playlist>,
          ),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = HomeState.error('Could not load your home feed.'));
    }
  }

  void _playTracks(List<Track> tracks, int startIndex) {
    context.read<PlaybackState>().playQueue(
          tracks.map((t) => t.toPlaybackJson()).toList(),
          startIndex: startIndex,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state.view) {
      case HomeView.loading:
        return const _HomeSkeleton();
      case HomeView.error:
        return ErrorView.generic(
          message: _state.errorMessage,
          onRetry: _load,
        );
      case HomeView.empty:
        return const _HomeEmptyState();
      case HomeView.content:
        return _HomeContent(
          sections: _state.sections,
          onPlayTrack: _playTracks,
          onOpenPlaylist: (playlist) => context.push('/playlists/${playlist.id}'),
        );
    }
  }
}

/// The single, terminal empty state. No spinner, no error, no retry — just an
/// invitation to start listening.
class _HomeEmptyState extends StatelessWidget {
  const _HomeEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Wrapped in a scroll view so pull-to-refresh still works with no content.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.music_note,
                    size: 64,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Play something to get started',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({
    required this.sections,
    required this.onPlayTrack,
    required this.onOpenPlaylist,
  });

  final HomeSections sections;
  final void Function(List<Track> tracks, int startIndex) onPlayTrack;
  final void Function(Playlist playlist) onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (sections.recentlyPlayed.isNotEmpty)
          _TrackSection(
            title: 'Recently played',
            tracks: sections.recentlyPlayed,
            onPlay: onPlayTrack,
          ),
        if (sections.topTracks.isNotEmpty)
          _TrackSection(
            title: 'Your top tracks',
            tracks: sections.topTracks,
            onPlay: onPlayTrack,
          ),
        if (sections.playlists.isNotEmpty)
          _PlaylistSection(
            playlists: sections.playlists,
            onOpen: onOpenPlaylist,
          ),
      ],
    );
  }
}

class _TrackSection extends StatelessWidget {
  const _TrackSection({
    required this.title,
    required this.tracks,
    required this.onPlay,
  });

  final String title;
  final List<Track> tracks;
  final void Function(List<Track> tracks, int startIndex) onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title),
        for (var i = 0; i < tracks.length; i++)
          _TrackTile(
            track: tracks[i],
            onTap: () => onPlay(tracks, i),
          ),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track, required this.onTap});

  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cover = track.metadata?['cover_art_url'] as String? ??
        track.coverArtThumbnailUrl;
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 48,
          height: 48,
          child: cover != null && cover.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: cover,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const _CoverPlaceholder(),
                  errorWidget: (_, __, ___) => const _CoverPlaceholder(),
                )
              : const _CoverPlaceholder(),
        ),
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
    );
  }
}

class _PlaylistSection extends StatelessWidget {
  const _PlaylistSection({required this.playlists, required this.onOpen});

  final List<Playlist> playlists;
  final void Function(Playlist playlist) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Your playlists'),
        for (final playlist in playlists)
          ListTile(
            onTap: () => onOpen(playlist),
            leading: const CircleAvatar(child: Icon(Icons.queue_music)),
            title: Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${playlist.trackCount} tracks'),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// Lightweight loading placeholder: section headers + greyed rows, no spinner.
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var section = 0; section < 2; section++) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              width: 160,
              height: 22,
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          for (var row = 0; row < 3; row++)
            ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              title: Container(height: 14, color: base),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Container(height: 12, width: 120, color: base),
              ),
            ),
        ],
      ],
    );
  }
}
