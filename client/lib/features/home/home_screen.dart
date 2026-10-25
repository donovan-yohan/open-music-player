import '../../shared/widgets/app_snack_bar.dart';

import '../../shared/widgets/now_playing_row.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_state.dart';
import '../../core/errors/error_widgets.dart';
import '../../core/api/api_client.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/like_button.dart';
import '../../shared/widgets/queue_swipe_action.dart';
import '../../shared/widgets/song_list_item.dart';
import '../../shared/widgets/track_artwork.dart';
import '../../core/models/settings_model.dart';
import '../../core/services/home_service.dart';
import 'home_state.dart';

/// Shown when a Home row's track is not in the caller's library.
///
/// Deliberately *not* the transport-level "This track is no longer available."
/// copy: nothing failed here. The row is a play-history entry for a track the
/// server will not issue a playback URL for, and saying so plainly is the
/// whole point of the fix — the old behavior said nothing at all.
const String homeNotInLibraryMessage = 'This track is not in your library.';

/// True when the server said this row's track is currently in the caller's
/// library, or said nothing.
///
/// Only an explicit `false` restricts anything. Library, local-browse, and
/// cached payloads carry no `inLibrary` claim, and they must keep playing
/// exactly as they did — an absent capability signal is not a denial.
bool isPlayableFromHome(Track track) => track.inLibrary != false;

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
      setState(
          () => _state = HomeState.error('Could not load your home feed.'));
    }
  }

  /// Plays a Home section from the tapped row.
  ///
  /// Two things this deliberately does *not* do:
  ///
  /// 1. It never submits a row the server says is outside the caller's library.
  ///    `/playback/urls` resolves a batch as a unit, so one unowned row made
  ///    every tap in that section fail — including taps on perfectly playable
  ///    siblings. The unowned row is filtered out of the queue instead, which is
  ///    what stops an unowned sibling from blocking a tapped owned song.
  /// 2. It resolves the queue position by *identity*, not by the tapped list
  ///    index. Filtering shifts positions, so carrying the raw index across
  ///    would start playback on the wrong track.
  ///
  /// The await/catch is retained from the earlier snackbar-only fix: a genuine
  /// transport failure must still be visible rather than silently swallowed.
  Future<void> _playTracks(List<Track> tracks, int startIndex) async {
    if (startIndex < 0 || startIndex >= tracks.length) return;
    final tapped = tracks[startIndex];
    final playback = context.read<PlaybackState>();
    final messenger = ScaffoldMessenger.of(context);

    if (!isPlayableFromHome(tapped)) {
      // Nothing failed — the server said this track is not in this user's
      // library, so no playback URL will be issued for it. Say that, rather
      // than the transport-level "no longer available" copy.
      messenger.showSnackBar(
        const AppSnackBar(content: Text(homeNotInLibraryMessage)),
      );
      return;
    }

    final eligible = tracks.where(isPlayableFromHome).toList();
    final startAt = eligible.indexWhere((track) => track.id == tapped.id);
    if (startAt < 0) return;

    try {
      await playback.playQueue(
        eligible.map((t) => t.toPlaybackJson()).toList(),
        startIndex: startAt,
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        AppSnackBar(
          content: Text(playback.playbackError ?? 'Could not play this track.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _enqueueTrack(Track track) async {
    final playback = context.read<PlaybackState>();
    final messenger = ScaffoldMessenger.of(context);
    final mode = playback.swipeQueueMode;
    try {
      await playback.queueTrack(track.toPlaybackJson(), mode: mode);
      if (!mounted) return;
      messenger.showSnackBar(
        AppSnackBar(content: Text(mode.confirmationFor(track.title))),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const AppSnackBar(content: Text('Could not add to queue')),
      );
    }
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
          onEnqueueTrack: _enqueueTrack,
          onOpenPlaylist: (playlist) =>
              context.push('/playlists/${playlist.id}'),
        );
    }
  }
}

/// The single, terminal empty state with a path to source discovery.
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
                    'Find music to add to your library',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => context.go('/search'),
                    child: const Text('Discover music'),
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
    required this.onEnqueueTrack,
    required this.onOpenPlaylist,
  });

  final HomeSections sections;
  final void Function(List<Track> tracks, int startIndex) onPlayTrack;
  final Future<void> Function(Track track) onEnqueueTrack;
  final void Function(Playlist playlist) onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final viewportWidth = MediaQuery.sizeOf(context).width;
      if (viewportWidth >= 960) {
        return _DesktopHomeContent(
          sections: sections,
          onPlayTrack: onPlayTrack,
          onEnqueueTrack: onEnqueueTrack,
          onOpenPlaylist: onOpenPlaylist,
          availableWidth: constraints.maxWidth,
        );
      }
      return _MobileHomeContent(
        sections: sections,
        onPlayTrack: onPlayTrack,
        onEnqueueTrack: onEnqueueTrack,
        onOpenPlaylist: onOpenPlaylist,
      );
    });
  }
}

class _MobileHomeContent extends StatelessWidget {
  const _MobileHomeContent({
    required this.sections,
    required this.onPlayTrack,
    required this.onEnqueueTrack,
    required this.onOpenPlaylist,
  });

  final HomeSections sections;
  final void Function(List<Track> tracks, int startIndex) onPlayTrack;
  final Future<void> Function(Track track) onEnqueueTrack;
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
            onEnqueue: onEnqueueTrack,
          ),
        if (sections.topTracks.isNotEmpty)
          _TrackSection(
            title: 'Your top tracks',
            tracks: sections.topTracks,
            onPlay: onPlayTrack,
            onEnqueue: onEnqueueTrack,
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

class _DesktopHomeContent extends StatelessWidget {
  const _DesktopHomeContent({
    required this.sections,
    required this.onPlayTrack,
    required this.onEnqueueTrack,
    required this.onOpenPlaylist,
    required this.availableWidth,
  });

  final HomeSections sections;
  final void Function(List<Track> tracks, int startIndex) onPlayTrack;
  final Future<void> Function(Track track) onEnqueueTrack;
  final void Function(Playlist playlist) onOpenPlaylist;
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    final trackRegions = <Widget>[
      if (sections.recentlyPlayed.isNotEmpty)
        _trackRegion('Recently played', sections.recentlyPlayed),
      if (sections.topTracks.isNotEmpty)
        _trackRegion('Your top tracks', sections.topTracks),
    ];
    final playlists = sections.playlists.isEmpty
        ? null
        : _DesktopHomeRegion(
            title: 'Playlists',
            itemCount: sections.playlists.length,
            itemBuilder: (context, index) {
              final playlist = sections.playlists[index];
              return _DesktopHomeTile(
                item: _DesktopHomeEntry.playlist(playlist: playlist),
                onTap: () => onOpenPlaylist(playlist),
                onEnqueue: null,
              );
            },
          );
    // One viewport owns both tracks. Each region stays lazy and can grow
    // intrinsically with text; the collection column is not a nested scroller.
    final split =
        availableWidth >= 1100 && trackRegions.isNotEmpty && playlists != null;
    return CustomScrollView(
      key: const ValueKey('soundq_desktop_home'),
      slivers: [
        if (split)
          SliverCrossAxisGroup(
            key: const ValueKey('home_main_secondary'),
            slivers: [
              SliverConstrainedCrossAxis(
                // Snap the shared rule to a physical pixel, including at 2x.
                maxExtent: (availableWidth *
                            2 /
                            3 *
                            MediaQuery.devicePixelRatioOf(context))
                        .floorToDouble() /
                    MediaQuery.devicePixelRatioOf(context),
                sliver: DecoratedSliver(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                  sliver: SliverMainAxisGroup(slivers: trackRegions),
                ),
              ),
              SliverCrossAxisExpanded(flex: 1, sliver: playlists),
            ],
          )
        else ...[
          ...trackRegions,
          if (playlists != null) playlists,
        ],
      ],
    );
  }

  Widget _trackRegion(String title, List<Track> tracks) {
    return _DesktopHomeRegion(
      title: title,
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return _DesktopHomeTile(
          item: _DesktopHomeEntry.track(track: track),
          onTap: () => onPlayTrack(tracks, index),
          onEnqueue:
              isPlayableFromHome(track) ? () => onEnqueueTrack(track) : null,
        );
      },
    );
  }
}

/// Headers and rows share one continuous rule; there is no per-item card moat.
class _DesktopHomeRegion extends StatelessWidget {
  const _DesktopHomeRegion({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
  });

  final String title;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = BorderSide(color: theme.colorScheme.outline);
    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(
        child: Container(
          key: ValueKey('home_header_$title'),
          decoration: BoxDecoration(border: Border(bottom: rule)),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.titleLarge),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(border: Border(bottom: rule)),
            child: itemBuilder(context, index),
          ),
          childCount: itemCount,
        ),
      ),
    ]);
  }
}

class _DesktopHomeEntry {
  const _DesktopHomeEntry.track({required this.track}) : playlist = null;
  const _DesktopHomeEntry.playlist({required this.playlist}) : track = null;

  final Track? track;
  final Playlist? playlist;

  String get title => track?.title ?? playlist!.name;
  String get subtitle => track?.displayArtist ?? playlist!.trackCountLabel;
  String? get imageUrl => playlist?.coverUrl;
}

class _DesktopHomeTile extends StatefulWidget {
  const _DesktopHomeTile({
    required this.item,
    required this.onTap,
    required this.onEnqueue,
  });

  final _DesktopHomeEntry item;
  final VoidCallback onTap;
  final VoidCallback? onEnqueue;

  @override
  State<_DesktopHomeTile> createState() => _DesktopHomeTileState();
}

class _DesktopHomeTileState extends State<_DesktopHomeTile> {
  final _states = WidgetStatesController();

  @override
  void initState() {
    super.initState();
    _states.addListener(_updateInteraction);
  }

  void _updateInteraction() => setState(() {});

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final focused = _states.value.contains(WidgetState.focused);
    final hovered = _states.value.contains(WidgetState.hovered);
    final pressed = _states.value.contains(WidgetState.pressed);
    final active = focused || hovered || pressed;
    final playable = item.track == null || isPlayableFromHome(item.track!);
    final queueMode = context.select<PlaybackState?, QueueInsertMode>(
      (playback) => playback?.swipeQueueMode ?? QueueInsertMode.addToQueue,
    );
    final tooltip = item.track == null
        ? 'Open ${item.title}'
        : playable
            ? 'Play ${item.title}'
            : '${item.title}\n$homeNotInLibraryMessage';
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.zero,
      side: BorderSide(
        color: focused ? colors.secondary : Colors.transparent,
        width: focused ? 2 : 1,
      ),
    );
    const overlay = WidgetStatePropertyAll(Colors.transparent);
    return Material(
      color: active
          ? theme.brightness == Brightness.dark
              ? colors.outline
              : Color.lerp(colors.surface, colors.outline, .12)!
          : colors.surface,
      shape: shape,
      animationDuration: Duration.zero,
      clipBehavior: Clip.antiAlias,
      child: NowPlayingRow(
        trackId: item.track?.id.toString(),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            statesController: _states,
            customBorder: shape,
            overlayColor: overlay,
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  ClipRect(
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: item.track != null
                          ? TrackArtwork.fromTrack(
                              item.track!,
                              width: 40,
                              height: 40,
                              borderRadius: BorderRadius.zero,
                            )
                          : item.imageUrl == null || item.imageUrl!.isEmpty
                              ? const _CoverPlaceholder()
                              : CachedNetworkImage(
                                  imageUrl: item.imageUrl!,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) =>
                                      const _CoverPlaceholder(),
                                ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SongRowTitle(item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                                fontSize: 18, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(playable ? item.subtitle : 'Not in your library',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  if (item.track != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: playable
                          ? queueMode == QueueInsertMode.playNext
                              ? 'Play next: ${item.title}'
                              : 'Add ${item.title} to queue'
                          : homeNotInLibraryMessage,
                      onPressed: widget.onEnqueue,
                      icon: const Icon(Icons.add_to_queue, size: 20),
                      // Let the native theme resolve both the whole surface and
                      // foreground together, including disabled/combined states.
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackSection extends StatelessWidget {
  const _TrackSection({
    required this.title,
    required this.tracks,
    required this.onPlay,
    required this.onEnqueue,
  });

  final String title;
  final List<Track> tracks;
  final void Function(List<Track> tracks, int startIndex) onPlay;
  final Future<void> Function(Track track) onEnqueue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title),
        for (var i = 0; i < tracks.length; i++)
          _TrackTile(
            actionKey: ValueKey('home_queue_${title}_${tracks[i].id}_$i'),
            track: tracks[i],
            playable: isPlayableFromHome(tracks[i]),
            onTap: () => onPlay(tracks, i),
            onAddToQueue: () => onEnqueue(tracks[i]),
          ),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.actionKey,
    required this.track,
    required this.playable,
    required this.onTap,
    required this.onAddToQueue,
  });

  final Key actionKey;
  final Track track;

  /// False when the server says this row's track is not in the caller's
  /// library, so no playback URL can be issued for it. The row stays visible
  /// (it is real listening history) but must not look identical to a playable
  /// row, and must not offer to queue itself into a queue that cannot resolve.
  final bool playable;
  final VoidCallback onTap;
  final Future<void> Function() onAddToQueue;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = colors.onSurfaceVariant;
    return QueueSwipeAction(
      actionKey: actionKey,
      onAddToQueue: onAddToQueue,
      enabled: playable,
      child: NowPlayingRow(
          trackId: track.id.toString(),
          child: SongListItem(
            analysis: track.analysis,
            onTap: onTap,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 48,
                height: 48,
                child: TrackArtwork.fromTrack(
                  track,
                  width: 48,
                  height: 48,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: playable ? null : TextStyle(color: muted),
            ),
            subtitle: playable
                ? Text(
                    track.displayArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Row(
                    children: [
                      Icon(Icons.library_music_outlined,
                          size: 13, color: muted),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Not in your library',
                          key: ValueKey('home_not_in_library_${track.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: muted),
                        ),
                      ),
                    ],
                  ),
            trailing: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [
                LikeToggleButton(
                    track: track, buttonKey: ValueKey('home_like_${track.id}')),
                Text(track.formattedDuration,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          )),
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
            subtitle: Text(playlist.trackCountLabel),
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
        Icons.library_music_outlined,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
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
