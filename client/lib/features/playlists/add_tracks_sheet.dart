import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/models/track.dart';
import '../../shared/widgets/track_tile.dart';

/// Loads one page of the caller's own library, narrowed by [query] when the
/// user has typed something. Injected so the sheet never has to know about
/// `LibraryService` or transport, and so widget tests can drive search and
/// paging without a server.
typedef LibraryTrackPageLoader = Future<({List<Track> tracks, int total})>
    Function({
  required int limit,
  required int offset,
  String? query,
});

/// Keys for the "pick library tracks for this playlist" flow. Tests target
/// these rather than the copy, which is free to change.
const addTracksSheetKey = ValueKey('add_tracks_sheet');
const addTracksSearchFieldKey = ValueKey('add_tracks_search_field');
const addTracksConfirmKey = ValueKey('add_tracks_confirm');
const addTracksLoadingKey = ValueKey('add_tracks_loading');
const addTracksErrorKey = ValueKey('add_tracks_error');
const addTracksEmptyKey = ValueKey('add_tracks_empty');
const addTracksRetryKey = ValueKey('add_tracks_retry');

ValueKey<String> addTracksRowKey(int trackId) =>
    ValueKey('add_tracks_row_$trackId');

/// "Which of my tracks go in this playlist?" — a modal sheet over playlist
/// detail that browses and searches the library and pops the selected track
/// ids.
///
/// The sheet only *chooses*; the host screen owns the write, so the backend's
/// added/skipped report and the reload that follows it stay in one place no
/// matter which surface started the add. It is the mirror of
/// `showAddToPlaylistSheet`, which picks a playlist for a track already in
/// hand.
class AddTracksSheet extends StatefulWidget {
  const AddTracksSheet({
    super.key,
    required this.playlistName,
    required this.loadPage,
    this.alreadyInPlaylist = const <int>{},
  });

  /// Named in the header so it is obvious where the picks will land.
  final String playlistName;

  final LibraryTrackPageLoader loadPage;

  /// Tracks the playlist already holds, rendered as done rather than as
  /// choices. Advisory only: the playlist can change under an open sheet, so
  /// the backend's skipped report remains the authority on duplicates.
  final Set<int> alreadyInPlaylist;

  /// Returns the chosen track ids in tap order, or null when the user backed
  /// out.
  static Future<List<int>?> show(
    BuildContext context, {
    required String playlistName,
    required LibraryTrackPageLoader loadPage,
    Set<int> alreadyInPlaylist = const <int>{},
  }) {
    return showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => AddTracksSheet(
        key: addTracksSheetKey,
        playlistName: playlistName,
        loadPage: loadPage,
        alreadyInPlaylist: alreadyInPlaylist,
      ),
    );
  }

  @override
  State<AddTracksSheet> createState() => _AddTracksSheetState();
}

class _AddTracksSheetState extends State<AddTracksSheet> {
  static const _pageSize = 20;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// Insertion-ordered so "Add 3 tracks" adds them in the order they were
  /// tapped rather than in whatever order the library page happened to be in.
  final Set<int> _selection = <int>{};

  List<Track> _tracks = const [];
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _errorMessage;

  Timer? _debounce;

  /// Monotonic request id. A late-returning response from a superseded query
  /// must never overwrite newer state.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String? get _query {
    final trimmed = _searchController.text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool get _hasMore => _tracks.length < _total;

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      unawaited(_loadMore());
    }
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) unawaited(_load());
    });
    // Repaints the clear affordance without waiting for the debounce.
    setState(() {});
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final page = await widget.loadPage(
        limit: _pageSize,
        offset: 0,
        query: _query,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _tracks = page.tracks;
        _total = page.total;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _tracks = const [];
        _total = 0;
        _errorMessage = 'Could not load your library. Try again.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;

    // Pinned so a search started mid-page drops this response instead of
    // appending the previous query's next page to the new results.
    final requestId = _requestId;
    setState(() => _loadingMore = true);

    try {
      final page = await widget.loadPage(
        limit: _pageSize,
        offset: _tracks.length,
        query: _query,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loadingMore = false;
        _tracks = [..._tracks, ...page.tracks];
        _total = page.total;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _loadingMore = false);
    }
  }

  void _toggle(int trackId) {
    setState(() {
      if (!_selection.remove(trackId)) _selection.add(trackId);
    });
  }

  String get _confirmLabel {
    if (_selection.isEmpty) return 'Select tracks to add';
    return _selection.length == 1
        ? 'Add 1 track'
        : 'Add ${_selection.length} tracks';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    // The keyboard eats the sheet from the bottom, so the body is capped by
    // what is actually left rather than by the screen height.
    final height = math.min(
      media.size.height * 0.85,
      media.size.height - media.viewInsets.bottom,
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          height: height,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Add tracks', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      'Pick tracks from your library to add to '
                      '"${widget.playlistName}".',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: addTracksSearchFieldKey,
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      onChanged: _onQueryChanged,
                      onSubmitted: (_) {
                        _debounce?.cancel();
                        unawaited(_load());
                      },
                      decoration: InputDecoration(
                        hintText: 'Search your library',
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query == null
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchController.clear();
                                  _debounce?.cancel();
                                  unawaited(_load());
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody(theme)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  key: addTracksConfirmKey,
                  onPressed: _selection.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_selection.toList()),
                  icon: const Icon(Icons.playlist_add),
                  label: Text(_confirmLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(
        key: addTracksLoadingKey,
        child: CircularProgressIndicator(),
      );
    }

    final errorMessage = _errorMessage;
    if (errorMessage != null) {
      return Center(
        key: addTracksErrorKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorMessage, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 12),
            FilledButton(
              key: addTracksRetryKey,
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_tracks.isEmpty) {
      final query = _query;
      return Center(
        key: addTracksEmptyKey,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            query == null
                ? 'Your library is empty.'
                : 'No tracks match "$query".',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _tracks.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _tracks.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final track = _tracks[index];
        final already = widget.alreadyInPlaylist.contains(track.id);
        return KeyedSubtree(
          key: addTracksRowKey(track.id),
          child: TrackTile.fromTrack(
            track,
            onTap: already ? null : () => _toggle(track.id),
            trailing: already
                ? Tooltip(
                    message: 'Already in this playlist',
                    child: Icon(
                      Icons.check,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Checkbox(
                    value: _selection.contains(track.id),
                    onChanged: (_) => _toggle(track.id),
                  ),
          ),
        );
      },
    );
  }
}
