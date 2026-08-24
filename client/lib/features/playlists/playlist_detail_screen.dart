import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/audio/playback_context.dart';
import '../../core/audio/playback_state.dart';
import '../../core/audio/queue_ordering.dart';
import '../../core/services/playlist_service.dart';
import '../../core/api/api_client.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/playlist.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/download_button.dart';
import '../../shared/widgets/like_button.dart';
import '../../shared/widgets/queue_swipe_action.dart';
import '../../shared/widgets/track_tile.dart';
import 'mix/mix_models.dart';
import 'mix/mix_preferences.dart';
import 'mix/mix_reorder.dart';
import 'mixed_playlist_view.dart';
import 'playlist_edit_dialog.dart';
import 'playlist_selection.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final int playlistId;
  final PlaylistService? playlistService;

  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    this.playlistService,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late final PlaylistService _playlistService = widget.playlistService ??
      PlaylistService(api: ApiClient(storage: SecureStorage()));

  Playlist? _playlist;
  bool _isLoading = true;
  String? _error;
  bool _isEditMode = false;
  bool _isSelectMode = false;
  PlaylistSelection _selection = const PlaylistSelection();
  bool _mixEnabled = false;
  bool _isMixLoading = false;
  AutoMixResult? _mixPlan;
  List<int> _displayOrder = const [];

  /// True while the blended list is scrolling fast; seam connectors collapse
  /// to hairlines so long playlists stay scannable.
  final ValueNotifier<bool> _fastScrolling = ValueNotifier(false);
  Timer? _seamExpandTimer;
  ScrollController? _scrollController;
  DateTime? _lastScrollTimestamp;

  static const double _fastScrollVelocityDpPerMs = 1.2;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
    _restoreMixPreference();
  }

  void _handleScrollMetrics(ScrollUpdateNotification notification) {
    if (!_mixEnabled) return;

    final now = DateTime.now();
    final previous = _lastScrollTimestamp;
    _lastScrollTimestamp = now;
    final delta = notification.scrollDelta;
    if (delta == null || previous == null) return;

    final deltaMs = now.difference(previous).inMicroseconds / 1000;
    if (deltaMs <= 0) return;
    final pixelsPerMs = delta.abs() / deltaMs;

    if (pixelsPerMs >= _fastScrollVelocityDpPerMs) {
      _seamExpandTimer?.cancel();
      if (!_fastScrolling.value) _fastScrolling.value = true;
    } else {
      _seamExpandTimer?.cancel();
      _seamExpandTimer = Timer(const Duration(milliseconds: 180), () {
        if (_fastScrolling.value) _fastScrolling.value = false;
      });
    }
  }

  @override
  void dispose() {
    _seamExpandTimer?.cancel();
    _scrollController?.dispose();
    _fastScrolling.dispose();
    super.dispose();
  }

  Future<void> _restoreMixPreference() async {
    final enabled = await loadMixEnabled(widget.playlistId);
    if (!mounted || !enabled) return;
    setState(() => _mixEnabled = true);
    // Re-arm the blended view; the saved plan lives server-side, so refresh
    // the transitions without blocking the list render.
    try {
      final result = await _playlistService.autoMix(widget.playlistId);
      if (!mounted) return;
      setState(() {
        _mixPlan = result;
        _displayOrder = const [];
      });
    } catch (_) {
      // Plan fetch failed; keep plain view until the user re-toggles.
      if (mounted) setState(() => _mixEnabled = false);
    }
  }

  /// Toggles the blended view. Turning it on calls POST /auto-mix and keeps
  /// the returned plan in memory; turning it off only changes the local view
  /// — the server-side plan is preserved for later slices.
  Future<void> _toggleMix() async {
    if (_isMixLoading) return;
    final messenger = ScaffoldMessenger.of(context);

    if (_mixEnabled) {
      setState(() => _mixEnabled = false);
      await saveMixEnabled(widget.playlistId, false);
      return;
    }

    setState(() => _isMixLoading = true);
    try {
      final result = await _playlistService.autoMix(widget.playlistId);
      await saveMixEnabled(widget.playlistId, true);
      if (!mounted) return;
      setState(() {
        _mixEnabled = true;
        _mixPlan = result;
        _displayOrder = const [];
        _isMixLoading = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Blended ${result.transitions.length} transitions. Tap any seam to adjust.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isMixLoading = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not blend this playlist. Try again.'),
        ),
      );
    }
  }

  /// Greedy nearest-neighbor reorder over BPM + Camelot key, client-side
  /// only: the displayed order changes but no server call is made.
  void _reorderByMusicalDistance() {
    final tracks = _playlist?.tracks;
    if (tracks == null || tracks.length < 2) return;

    final analyses =
        tracks.map((track) => track.analysis).toList(growable: false);
    final order = MixReorder.orderIndices(analyses);
    final isIdentity = order.indexed.every((entry) => entry.$1 == entry.$2);
    if (isIdentity) return;

    setState(() => _displayOrder = order);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reordered by key and tempo')),
    );
  }

  List<Track> get _orderedTracks {
    final tracks = _playlist?.tracks ?? const <Track>[];
    if (!_mixEnabled ||
        _displayOrder.isEmpty ||
        _displayOrder.length != tracks.length) {
      return List.of(tracks);
    }
    return [for (final index in _displayOrder) tracks[index]];
  }

  void _openSeam(MixTransition? transition) {
    // The transition editor is the next slice; surface a placeholder now.
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Transition editor coming in slice 2'),
      ),
    );
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final playlist = await _playlistService.getPlaylist(widget.playlistId);
      setState(() {
        _playlist = playlist;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _removeTrack(Track track) async {
    if (_playlist == null) return;

    final playlist = _playlist!;
    final messenger = ScaffoldMessenger.of(context);

    try {
      final updated = await _playlistService.batchRemoveTracks(
        playlist.id,
        [track.id],
      );
      if (mounted) {
        setState(() => _playlist = updated);
        messenger.showSnackBar(
          SnackBar(
            content: Text('Removed "${track.title}"'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final result =
                    await _playlistService.addTracks(_playlist!.id, [track.id]);
                if (mounted && result.hasSkipped && !result.hasAdded) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(result.feedbackMessage(playlist.name)),
                    ),
                  );
                }
                _loadPlaylist();
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to remove "${track.title}"')),
        );
      }
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

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      _selection = const PlaylistSelection();
      if (_isSelectMode) _isEditMode = false;
    });
  }

  void _toggleTrackSelection(int trackId) {
    setState(() => _selection = _selection.toggle(trackId));
  }

  /// Removes every selected track in a single batch-remove request.
  Future<void> _removeSelectedTracks() async {
    if (_playlist == null || _selection.isEmpty) return;

    final ids = _selection.selectedIds.toList();
    final messenger = ScaffoldMessenger.of(context);
    final label = _selection.removeLabel.toLowerCase();

    try {
      final updated =
          await _playlistService.batchRemoveTracks(_playlist!.id, ids);
      if (!mounted) return;
      setState(() {
        _playlist = updated;
        _isSelectMode = false;
        _selection = const PlaylistSelection();
      });
      messenger.showSnackBar(
        SnackBar(content: Text('Removed ${ids.length} tracks')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to $label: $e')),
      );
    }
  }

  Future<void> _reorderTrack(int oldIndex, int newIndex) async {
    if (_playlist == null || _playlist!.tracks == null) return;

    final tracks = List<Track>.from(_playlist!.tracks!);
    final track = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, track);

    setState(() {
      _playlist = _playlist!.copyWith(tracks: tracks);
    });

    try {
      await _playlistService.reorderTrack(
        _playlist!.id,
        trackId: track.id,
        newPosition: newIndex,
      );
    } catch (e) {
      _loadPlaylist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reorder: $e')),
        );
      }
    }
  }

  void _showEditDialog() {
    if (_playlist == null) return;

    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        initialName: _playlist!.name,
        initialDescription: _playlist!.description,
        initialCoverUrl: _playlist!.coverUrl,
        initialIsPublic: _playlist!.isPublic,
        onSave: (result) async {
          try {
            final updated = await _playlistService.updatePlaylist(
              _playlist!.id,
              name: result.name,
              description: result.description,
              coverUrl: result.coverUrl ?? '',
              isPublic: result.isPublic,
            );
            if (!mounted) return;
            setState(
                () => _playlist = updated.copyWith(tracks: _playlist!.tracks));
            ScaffoldMessenger.of(this.context).showSnackBar(
              const SnackBar(content: Text('Playlist updated')),
            );
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(this.context).showSnackBar(
              SnackBar(content: Text('Failed to update: $e')),
            );
          }
        },
      ),
    );
  }

  void _showDeleteConfirmation() {
    final playlist = _playlist;
    if (playlist == null) return;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Are you sure you want to delete "${playlist.name}"? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _playlistService.deletePlaylist(playlist.id);
                if (!mounted) return;
                router.pop();
                messenger.showSnackBar(
                  SnackBar(content: Text('Deleted "${playlist.name}"')),
                );
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text('Failed to delete: $e')),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  bool get _hasPlayableTracks => _playlist?.tracks?.isNotEmpty ?? false;

  /// Plays the whole playlist into the listening queue, optionally shuffled.
  Future<void> _playAll({bool shuffle = false}) async {
    final tracks = playCollectionOrder(
      _playlist?.tracks ?? const <Track>[],
      shuffled: shuffle,
    );
    if (tracks.isEmpty) return;
    final playback = context.read<PlaybackState>();
    await playback.playQueue(
      tracks.map((t) => t.toPlaybackJson()).toList(),
      context: _playlistContext(),
    );
  }

  PlaybackContext? _playlistContext() {
    final playlist = _playlist;
    if (playlist == null) return null;
    return PlaybackContext(
      kind: PlaybackContextKind.playlist,
      label: playlist.name,
      id: playlist.id.toString(),
    );
  }

  /// Plays the playlist starting from the tapped track (context = the playlist).
  Future<void> _playFromIndex(int index) async {
    final tracks = _playlist?.tracks ?? const [];
    if (index < 0 || index >= tracks.length) return;
    final playback = context.read<PlaybackState>();
    await playback.playQueue(
      tracks.map((t) => t.toPlaybackJson()).toList(),
      startIndex: index,
      context: _playlistContext(),
    );
  }

  bool _isCurrentPlaylistQueue(PlaybackContext? playbackContext) {
    final playlist = _playlist;
    if (playlist == null) return false;
    return playbackContext?.kind == PlaybackContextKind.playlist &&
        playbackContext?.id == playlist.id.toString();
  }

  bool _isCurrentTrackInThisPlaylist(
    PlaybackContext? playbackContext,
    String? currentItemId,
    Track track,
  ) {
    if (!_isCurrentPlaylistQueue(playbackContext)) return false;
    return int.tryParse(currentItemId ?? '') == track.id;
  }

  String _activeTrackLabel(bool isPlaying) {
    return isPlaying ? 'Now playing' : 'Paused here';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _withScrollObserver(_buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text('Error: $_error'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadPlaylist,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_playlist == null) {
      return const Center(child: Text('Playlist not found'));
    }

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        _buildAppBar(),
        _buildHeader(),
        _mixEnabled ? _buildMixedTracksList() : _buildTracksList(),
      ],
    );
  }

  /// Notification wrapper keeps scroll-velocity handling local to the blended
  /// view without owning a second scroll position.
  Widget _withScrollObserver(Widget child) {
    if (!_mixEnabled) return child;
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        _handleScrollMetrics(notification);
        return false;
      },
      child: child,
    );
  }

  Widget _buildAppBar() {
    if (_isSelectMode) return _buildSelectionAppBar();
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          _playlist!.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 4)],
          ),
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                Theme.of(context).scaffoldBackgroundColor,
              ],
            ),
          ),
          child: Center(
            child: Icon(
              Icons.queue_music,
              size: 80,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
      actions: [
        if (_isMixLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          IconButton(
            key: const ValueKey('mix_toggle'),
            icon: Icon(
              Icons.auto_awesome,
              color: _mixEnabled ? AppTheme.orange : null,
            ),
            onPressed: _toggleMix,
            tooltip: _mixEnabled
                ? 'Blended — transitions between every track'
                : 'Blend this playlist',
          ),
        if (_mixEnabled && !_isMixLoading)
          IconButton(
            key: const ValueKey('mix_reorder_button'),
            icon: const Icon(Icons.sort),
            onPressed: _reorderByMusicalDistance,
            tooltip: 'Reorder by key and tempo',
          ),
        IconButton(
          icon: Icon(_isEditMode ? Icons.check : Icons.edit),
          onPressed: () => setState(() => _isEditMode = !_isEditMode),
          tooltip: _isEditMode ? 'Done editing' : 'Edit mode',
        ),
        PopupMenuButton(
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'select',
              child: ListTile(
                leading: Icon(Icons.checklist),
                title: Text('Select tracks'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: Icon(Icons.edit),
                title: Text('Edit details'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('Delete', style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
          onSelected: (value) {
            if (value == 'select') _toggleSelectMode();
            if (value == 'edit') _showEditDialog();
            if (value == 'delete') _showDeleteConfirmation();
          },
        ),
      ],
    );
  }

  Widget _buildSelectionAppBar() {
    return SliverAppBar(
      pinned: true,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _toggleSelectMode,
        tooltip: 'Cancel selection',
      ),
      title: Text(
        _selection.isEmpty ? 'Select tracks' : '${_selection.count} selected',
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: _selection.removeLabel,
          onPressed: _selection.isEmpty ? null : _confirmRemoveSelected,
        ),
      ],
    );
  }

  void _confirmRemoveSelected() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove tracks?'),
        content: Text('Remove ${_selection.count} tracks from this playlist?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _removeSelectedTracks();
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_playlist!.description != null &&
                _playlist!.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _playlist!.description!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            Text(
              '${_playlist!.trackCount} tracks • ${_playlist!.formattedDuration}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _hasPlayableTracks ? () => _playAll() : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _hasPlayableTracks
                        ? () => _playAll(shuffle: true)
                        : null,
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle'),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DownloadAllButton.forPlaylist(
                _playlist!,
                buttonKey: const ValueKey('playlist_download_all'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTracksList() {
    final tracks = _playlist!.tracks ?? [];
    final playbackContext = context.select<PlaybackState, PlaybackContext?>(
      (playback) => playback.playbackContext,
    );
    final currentItemId = context.select<PlaybackState, String?>(
      (playback) => playback.currentItem?.id,
    );
    final isPlaying = context.select<PlaybackState, bool>(
      (playback) => playback.isPlaying,
    );

    if (tracks.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.music_note, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text('No tracks yet'),
              SizedBox(height: 8),
              Text(
                'Add tracks from your library',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (_isSelectMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final track = tracks[index];
            final selected = _selection.contains(track.id);
            final isCurrent = _isCurrentTrackInThisPlaylist(
              playbackContext,
              currentItemId,
              track,
            );
            return TrackTile.fromTrack(
              track,
              isCurrent: isCurrent,
              onTap: () => _toggleTrackSelection(track.id),
              trailing: Checkbox(
                value: selected,
                onChanged: (_) => _toggleTrackSelection(track.id),
              ),
            );
          },
          childCount: tracks.length,
        ),
      );
    }

    if (_isEditMode) {
      return SliverReorderableList(
        itemCount: tracks.length,
        onReorderItem: _reorderTrack,
        itemBuilder: (context, index) {
          final track = tracks[index];
          final isCurrent = _isCurrentTrackInThisPlaylist(
            playbackContext,
            currentItemId,
            track,
          );
          return ReorderableDragStartListener(
            key: Key('track_${track.id}'),
            index: index,
            child: TrackTile.fromTrack(
              track,
              isCurrent: isCurrent,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => _removeTrack(track),
                    color: Colors.red,
                  ),
                  const Icon(Icons.drag_handle),
                ],
              ),
            ),
          );
        },
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = tracks[index];
          final isCurrent = _isCurrentTrackInThisPlaylist(
            playbackContext,
            currentItemId,
            track,
          );
          return QueueSwipeAction(
            actionKey:
                Key('playlist_queue_${widget.playlistId}_${track.id}_$index'),
            onAddToQueue: () => _enqueueTrack(track),
            child: TrackTile.fromTrack(
              track,
              isCurrent: isCurrent,
              onTap: () => _playFromIndex(index),
              activeLabel: isCurrent ? _activeTrackLabel(isPlaying) : null,
              action: LikeToggleButton(
                track: track,
                buttonKey: ValueKey('playlist_like_${track.id}'),
              ),
            ),
          );
        },
        childCount: tracks.length,
      ),
    );
  }

  /// Blended list: track rows gain BPM/key badges, and every pair of adjacent
  /// rows is separated by a tappable seam connector. Seams collapse to
  /// hairlines while the user scrolls fast and expand back on settle.
  Widget _buildMixedTracksList() {
    final tracks = _orderedTracks;
    if (tracks.isEmpty) return _buildTracksList();

    final playbackContext = context.select<PlaybackState, PlaybackContext?>(
      (playback) => playback.playbackContext,
    );
    final currentItemId = context.select<PlaybackState, String?>(
      (playback) => playback.currentItem?.id,
    );
    final isPlaying = context.select<PlaybackState, bool>(
      (playback) => playback.isPlaying,
    );

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          // Interleave: even indices are track rows, odd ones are seams.
          if (index.isOdd) {
            final seamIndex = index ~/ 2;
            final transition =
                _mixPlan?.between(tracks[seamIndex], tracks[seamIndex + 1]);
            return ValueListenableBuilder<bool>(
              key: Key('mix_seam_${tracks[seamIndex].id}_${tracks[seamIndex + 1].id}'),
              valueListenable: _fastScrolling,
              builder: (context, collapsed, _) {
                return MixSeamConnector(
                  transition: transition,
                  collapsed: collapsed,
                  onTap: () => _openSeam(transition),
                );
              },
            );
          }

          final rowIndex = index ~/ 2;
          final track = tracks[rowIndex];
          final isCurrent = _isCurrentTrackInThisPlaylist(
            playbackContext,
            currentItemId,
            track,
          );
          return Column(
            key: Key('mixed_track_${track.id}'),
            children: [
              // Built directly (not via fromTrack) so the plain tile does not
              // render its own metadata chips; the blended badges below are
              // the single metadata surface in this view.
              TrackTile(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.formattedDuration,
                coverArtUrl: track.displayArtworkUrl,
                artworkKind: track.artworkKind,
                isCurrent: isCurrent,
                activeLabel: isCurrent ? _activeTrackLabel(isPlaying) : null,
                onTap: () => _playFromIndex(rowIndex),
                action: LikeToggleButton(
                  track: track,
                  buttonKey: ValueKey('playlist_like_${track.id}'),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: MixTrackBadges(analysis: track.analysis),
                ),
              ),
            ],
          );
        },
        childCount: tracks.length * 2 - 1,
      ),
    );
  }
}
