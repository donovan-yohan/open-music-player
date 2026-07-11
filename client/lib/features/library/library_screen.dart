import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../core/storage/offline_database.dart';
import '../../core/network/connectivity_service.dart';
import '../../core/audio/playback_state.dart';
import '../../core/api/api_client.dart';
import '../../core/models/models.dart' as core_models;
import '../../core/services/services.dart' as services;
import '../../shared/models/models.dart';
import '../../shared/widgets/widgets.dart';
import '../discovery/screens/album_detail_screen.dart';
import '../discovery/screens/artist_detail_screen.dart';
import 'library_filter_logic.dart';
import 'liked_songs_screen.dart';
import 'library_sort_logic.dart';
import 'library_track_actions.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _pageSize = 20;

  bool _downloadedOnly = false;
  VerificationFilter _verificationFilter = VerificationFilter.all;
  LibraryFilterState _filter = LibraryFilterState.cleared;
  LibrarySortOption _sortOption = LibrarySortOption.defaultOption;
  List<Track> _tracks = [];
  Map<VerificationFilter, int> _counts = {};
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _hasError = false;
  int _totalCount = 0;

  final LibrarySortStore _sortStore = LibrarySortStore();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool get _hasActiveFilters =>
      _downloadedOnly ||
      _verificationFilter != VerificationFilter.all ||
      _filter.hasActiveFilters;

  // Library mutations (like/unlike, remove, playlists) and MusicBrainz-backed
  // detail navigation run through the parser-based services client, mirroring
  // the search/discovery screens.
  final services.ApiClient _servicesApiClient = services.ApiClient();
  late final services.LibraryService _libraryService =
      services.LibraryService(_servicesApiClient);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _restoreSortThenLoad();
  }

  /// Restores the persisted sort selection (so it survives re-open) before the
  /// first fetch, then loads the initial page.
  Future<void> _restoreSortThenLoad() async {
    final restored = await _sortStore.load();
    if (mounted) {
      setState(() => _sortOption = restored);
    } else {
      _sortOption = restored;
    }
    await _loadTracks();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreTracks();
    }
  }

  Future<void> _loadTracks() async {
    // Reset to page 0 and clear the prior rows up-front so a sort/filter change
    // shows the loading state instead of briefly flashing the old ordering.
    setState(() {
      _isLoading = true;
      _hasError = false;
      _tracks = [];
      _hasMore = true;
    });

    try {
      if (!_downloadedOnly && context.read<ConnectivityService>().isOnline) {
        try {
          final remote = await _loadRemoteTracks(offset: 0);
          setState(() {
            _tracks = remote.tracks;
            _totalCount = remote.total;
            _hasMore = _tracks.length < _totalCount;
            _counts = remote.counts;
            _isLoading = false;
          });
          return;
        } catch (_) {
          // Connectivity can report online while the API is unavailable. Keep
          // the Library useful by falling back to cached/offline tracks.
        }
      }

      final local = await _loadLocalTracks(offset: 0, includeCounts: true);
      setState(() {
        _tracks = local.tracks;
        _totalCount = local.total;
        _hasMore = _tracks.length < _totalCount;
        _counts = local.counts ?? _counts;
        _isLoading = false;
      });
    } catch (_) {
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _loadMoreTracks() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() => _isLoadingMore = true);
    try {
      if (!_downloadedOnly && context.read<ConnectivityService>().isOnline) {
        final remote = await _loadRemoteTracks(offset: _tracks.length);
        setState(() {
          _tracks.addAll(remote.tracks);
          _hasMore = _tracks.length < remote.total;
          _isLoadingMore = false;
        });
        return;
      }

      final local = await _loadLocalTracks(
        offset: _tracks.length,
        includeCounts: false,
      );
      setState(() {
        _tracks.addAll(local.tracks);
        _hasMore = _tracks.length < local.total;
        _isLoadingMore = false;
      });
    } catch (_) {
      setState(() => _isLoadingMore = false);
    }
  }

  Future<
      ({
        List<Track> tracks,
        int total,
        Map<VerificationFilter, int>? counts,
      })> _loadLocalTracks({
    required int offset,
    required bool includeCounts,
  }) async {
    final db = context.read<OfflineDatabase>();
    final trackResult = await db.getLibraryTracksWithCount(
      downloadedOnly: _downloadedOnly,
      verificationFilter: _verificationFilter,
      limit: _pageSize,
      offset: offset,
    );
    final counts = includeCounts ? await db.getLibraryTrackCounts() : null;
    return (
      tracks: trackResult.tracks,
      total: trackResult.total,
      counts: counts,
    );
  }

  Future<
      ({
        List<Track> tracks,
        int total,
        Map<VerificationFilter, int> counts,
      })> _loadRemoteTracks({required int offset}) async {
    // Capture the counts client before any await so we don't reach through
    // BuildContext across an async gap.
    final apiClient = context.read<ApiClient>();
    final offlineDatabase = context.read<OfflineDatabase>();
    bool? mbVerified;
    switch (_verificationFilter) {
      case VerificationFilter.verifiedOnly:
        mbVerified = true;
        break;
      case VerificationFilter.unverifiedOnly:
        mbVerified = false;
        break;
      case VerificationFilter.all:
        break;
    }

    final page = await _libraryService.getLibraryPage(
      limit: _pageSize,
      offset: offset,
      sort: _sortOption.field.apiValue,
      order: _sortOption.order.apiValue,
      mbVerified: mbVerified,
      liked: _filter.liked,
      genre: _filter.genre,
      query: _filter.query,
      fields: const [
        'id',
        'title',
        'artist',
        'album',
        'duration_ms',
        'mb_verified',
        'added_at',
        'cover_art_url',
        'mb_recording_id',
        'mb_suggestions',
        'analysis_status',
        'analysis_summary',
        'analysis_updated_at',
      ],
    );
    unawaited(_cacheRemoteTrackAnalysis(offlineDatabase, page.tracks));

    final counts = offset == 0
        ? await _loadRemoteCounts(apiClient)
        : Map<VerificationFilter, int>.from(_counts);

    return (tracks: page.tracks, total: page.total, counts: counts);
  }

  Future<void> _cacheRemoteTrackAnalysis(
    OfflineDatabase offlineDatabase,
    List<Track> tracks,
  ) async {
    try {
      await offlineDatabase.updateTrackAnalyses(
        tracks.where((track) => track.analysis != null),
      );
    } catch (_) {
      // Offline analysis is a cache; a local write failure must not delay or
      // hide a successfully loaded remote Library page.
    }
  }

  Future<Map<VerificationFilter, int>> _loadRemoteCounts(
      ApiClient apiClient) async {
    Future<int> count({String? verified}) async {
      final response = await apiClient.get<Map<String, dynamic>>(
        '/library',
        queryParameters: {
          'limit': '1',
          'offset': '0',
          if (verified != null) 'mb_verified': verified,
        },
      );
      return response.data?['total'] as int? ?? 0;
    }

    final totals = await Future.wait([
      count(),
      count(verified: 'true'),
      count(verified: 'false'),
    ]);

    return {
      VerificationFilter.all: totals[0],
      VerificationFilter.verifiedOnly: totals[1],
      VerificationFilter.unverifiedOnly: totals[2],
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.video_library_outlined),
            onPressed: () => context.push('/playlists/import'),
            tooltip: 'Import YouTube playlist',
          ),
          _buildSortControl(context),
          _buildVerificationFilter(context),
          _buildFilterChip(context),
        ],
      ),
      body: Column(
        children: [
          _buildOfflineBanner(context),
          _buildLikedSongsCard(context),
          _buildSearchField(context),
          _buildFilterChips(context),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildLikedSongsCard(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Icon(
              Icons.favorite,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          title: const Text('Liked Songs'),
          subtitle: const Text('Your favorites'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openLikedSongs,
        ),
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onSubmitted: _onSearchSubmitted,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search your library',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _filter.query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    _onSearchSubmitted('');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildFilterChips(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          FilterChip(
            label: const Text('Liked'),
            selected: _filter.liked,
            avatar: Icon(
              _filter.liked ? Icons.favorite : Icons.favorite_border,
              size: 18,
            ),
            onSelected: (_) => _onLikedToggled(),
          ),
          const SizedBox(width: 8),
          const VerticalDivider(width: 1),
          const SizedBox(width: 8),
          for (final genre in LibraryFilterState.genreChips) ...[
            FilterChip(
              label: Text(genre),
              selected: _filter.genre == genre,
              onSelected: (_) => _onGenreSelected(genre),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = resolveLibraryVisualState(
      isLoading: _isLoading,
      hasError: _hasError,
      isEmpty: _tracks.isEmpty,
      hasActiveFilters: _hasActiveFilters,
    );

    switch (state) {
      case LibraryVisualState.loading:
        return const Center(child: CircularProgressIndicator());
      case LibraryVisualState.error:
        return _buildErrorState();
      case LibraryVisualState.filteredEmpty:
        return _buildEmptyState(showClearFilters: true);
      case LibraryVisualState.empty:
        return _buildEmptyState();
      case LibraryVisualState.content:
        return _buildTrackList();
    }
  }

  Widget _buildSortControl(BuildContext context) {
    return PopupMenuButton<LibrarySortField>(
      tooltip: 'Sort library',
      icon: const Icon(Icons.sort),
      onSelected: _onSortFieldSelected,
      itemBuilder: (context) => LibrarySortField.values.map((field) {
        final selected = field == _sortOption.field;
        return PopupMenuItem(
          value: field,
          child: Row(
            children: [
              Icon(
                selected
                    ? (_sortOption.order == SortOrder.asc
                        ? Icons.arrow_upward
                        : Icons.arrow_downward)
                    : Icons.sort,
                size: 20,
                color: selected ? Theme.of(context).colorScheme.primary : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  field.label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  void _onSortFieldSelected(LibrarySortField field) {
    final next = _sortOption.selecting(field);
    if (next == _sortOption) return;
    setState(() => _sortOption = next);
    _sortStore.save(next);
    _loadTracks();
  }

  void _clearFilters() {
    setState(() {
      _downloadedOnly = false;
      _verificationFilter = VerificationFilter.all;
      _filter = LibraryFilterState.cleared;
      _searchController.clear();
    });
    _loadTracks();
  }

  void _onLikedToggled() {
    setState(() => _filter = _filter.toggleLiked());
    _loadTracks();
  }

  void _onGenreSelected(String genre) {
    setState(() => _filter = _filter.selectGenre(genre));
    _loadTracks();
  }

  void _onSearchSubmitted(String value) {
    final next = _filter.withQuery(value);
    if (next == _filter) return;
    setState(() => _filter = next);
    _loadTracks();
  }

  void _openLikedSongs() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
    );
  }

  Widget _buildVerificationFilter(BuildContext context) {
    final unverifiedCount = _counts[VerificationFilter.unverifiedOnly] ?? 0;

    return PopupMenuButton<VerificationFilter>(
      tooltip: 'Filter by verification status',
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            _verificationFilter == VerificationFilter.all
                ? Icons.filter_list
                : (_verificationFilter == VerificationFilter.verifiedOnly
                    ? Icons.verified
                    : Icons.info_outline),
            color: _verificationFilter != VerificationFilter.all
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          if (unverifiedCount > 0 &&
              _verificationFilter == VerificationFilter.all)
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.orange[400],
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                child: Text(
                  unverifiedCount > 99 ? '99+' : '$unverifiedCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
      onSelected: (filter) {
        setState(() => _verificationFilter = filter);
        _loadTracks();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: VerificationFilter.all,
          child: _buildFilterMenuItem(
            'All tracks',
            Icons.library_music,
            _verificationFilter == VerificationFilter.all,
            _counts[VerificationFilter.all] ?? 0,
          ),
        ),
        PopupMenuItem(
          value: VerificationFilter.verifiedOnly,
          child: _buildFilterMenuItem(
            'Verified only',
            Icons.verified,
            _verificationFilter == VerificationFilter.verifiedOnly,
            _counts[VerificationFilter.verifiedOnly] ?? 0,
          ),
        ),
        PopupMenuItem(
          value: VerificationFilter.unverifiedOnly,
          child: _buildFilterMenuItem(
            'Unverified only',
            Icons.info_outline,
            _verificationFilter == VerificationFilter.unverifiedOnly,
            _counts[VerificationFilter.unverifiedOnly] ?? 0,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterMenuItem(
      String label, IconData icon, bool selected, int count) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: selected ? Theme.of(context).colorScheme.primary : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: const Text('Downloaded'),
        selected: _downloadedOnly,
        onSelected: (selected) {
          setState(() => _downloadedOnly = selected);
          _loadTracks();
        },
        avatar: _downloadedOnly
            ? const Icon(Icons.check, size: 18)
            : const Icon(Icons.download_done, size: 18),
      ),
    );
  }

  Widget _buildOfflineBanner(BuildContext context) {
    return Consumer<ConnectivityService>(
      builder: (context, connectivity, _) {
        if (connectivity.isOnline) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Row(
            children: [
              Icon(
                Icons.cloud_off,
                size: 16,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Offline mode - showing downloaded tracks only',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState({bool showClearFilters = false}) {
    final (icon, title, subtitle) = _getEmptyStateContent();

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 64,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.grey[500],
            ),
            textAlign: TextAlign.center,
          ),
          if (showClearFilters) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('Clear filters'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 64,
            color: Colors.grey[600],
          ),
          const SizedBox(height: 16),
          Text(
            'Something went wrong',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "We couldn't load your library.",
            style: TextStyle(
              color: Colors.grey[500],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loadTracks,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  (IconData, String, String) _getEmptyStateContent() {
    if (_filter.query.trim().isNotEmpty) {
      return (
        Icons.search_off,
        'No matches',
        'No tracks match "${_filter.query.trim()}"'
      );
    }

    if (_filter.liked || _filter.genre != null) {
      return (
        Icons.filter_alt,
        'No tracks match your filters',
        'Try clearing a filter to see more of your library'
      );
    }

    if (_downloadedOnly) {
      return (
        Icons.download_done,
        'No downloaded tracks',
        'Download tracks to listen offline'
      );
    }

    switch (_verificationFilter) {
      case VerificationFilter.verifiedOnly:
        return (
          Icons.verified,
          'No verified tracks',
          'Tracks with MusicBrainz metadata will appear here'
        );
      case VerificationFilter.unverifiedOnly:
        return (
          Icons.check_circle,
          'All tracks verified!',
          'All your tracks have verified metadata'
        );
      case VerificationFilter.all:
        return (
          Icons.library_music,
          'Your Library',
          'Your collection will appear here'
        );
    }
  }

  Widget _buildTrackList() {
    return RefreshIndicator(
      onRefresh: _loadTracks,
      child: ListView.builder(
        controller: _scrollController,
        // Add 1 for loading indicator if has more
        itemCount: _tracks.length + (_hasMore ? 1 : 0),
        // Use scrollCacheExtent for smooth scrolling
        scrollCacheExtent: const ScrollCacheExtent.pixels(200),
        itemBuilder: (context, index) {
          // Loading indicator at the bottom
          if (index >= _tracks.length) {
            return const Padding(
              padding: EdgeInsets.all(16.0),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final track = _tracks[index];
          return LibraryTrackListTile(
            key: ValueKey(track.id),
            track: track,
            libraryService: _libraryService,
            detailApiClient: _servicesApiClient,
            onTrackUpdated: _loadTracks,
          );
        },
      ),
    );
  }
}

class LibraryTrackListTile extends StatefulWidget {
  final Track track;
  final services.LibraryService libraryService;
  final services.ApiClient detailApiClient;
  final VoidCallback? onTrackUpdated;

  const LibraryTrackListTile({
    super.key,
    required this.track,
    required this.libraryService,
    required this.detailApiClient,
    this.onTrackUpdated,
  });

  @override
  State<LibraryTrackListTile> createState() => _LibraryTrackListTileState();
}

class _LibraryTrackListTileState extends State<LibraryTrackListTile> {
  static const _compactActionBreakpoint = 520.0;

  late bool _liked = widget.track.isLiked;
  bool _likeInFlight = false;

  Track get track => widget.track;
  VoidCallback? get onTrackUpdated => widget.onTrackUpdated;
  services.LibraryService get _libraryService => widget.libraryService;

  void _showMatchSuggestions(BuildContext context) {
    if (!track.needsVerification) return;

    MatchSuggestionsSheet.show(
      context,
      track: track,
      onSelectSuggestion: (suggestion) async {
        try {
          final apiClient = context.read<ApiClient>();
          await apiClient.post(
            '/tracks/${track.id}/confirm-match',
            data: {
              'recordingMbid': suggestion.mbRecordingId,
              if (suggestion.artistMbid != null)
                'artistMbid': suggestion.artistMbid,
              if (suggestion.albumMbid != null)
                'releaseMbid': suggestion.albumMbid,
            },
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    'Matched to "${suggestion.title}" by ${suggestion.artist}'),
                backgroundColor: Colors.green,
              ),
            );
          }
          onTrackUpdated?.call();
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Failed to confirm match: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
      onManualSearch: () {
        _showUnverifiedTrackSheet(context);
      },
    );
  }

  Future<void> _playTrack(BuildContext context) async {
    final playback = context.read<PlaybackState>();
    try {
      await playback.playTrack({
        'id': track.id,
        'title': track.title,
        'artist': track.displayArtist,
        'album': track.displayAlbum,
        'duration': track.durationMs != null ? track.durationMs! ~/ 1000 : 0,
        'artwork_url': track.coverArtUrl,
        if (track.analysis != null)
          'analysisStatus': track.analysis!.status.name,
        if (track.analysis?.summary != null)
          'analysisSummary': track.analysis!.summary!.toJson(),
        if (track.analysis?.overrides != null)
          'analysisOverrides': track.analysis!.overrides!.toJson(),
        if (track.analysis?.updatedAt != null)
          'analysisUpdatedAt':
              track.analysis!.updatedAt!.toUtc().toIso8601String(),
      });
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(playback.playbackError ?? 'Could not play this track.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentTrackId = context.watch<PlaybackState>().currentItem?.id;
    final isCurrent = currentTrackId == track.id.toString();
    final summary = track.analysis?.summary;
    final hasMetadata = summary?.bpm?.numericValue != null ||
        summary?.key?.textValue != null ||
        summary?.camelot?.textValue != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compactActions =
            constraints.maxWidth < _compactActionBreakpoint ||
                MediaQuery.textScalerOf(context).scale(1) > 1.3;
        final subtitle = compactActions
            ? '${track.displayArtist} • ${track.formattedDuration}'
            : track.displayArtist;

        return QueueSwipeAction(
          actionKey: ValueKey('library_queue_${track.id}'),
          onAddToQueue: () => _addToQueue(),
          child: ListTile(
            key: ValueKey('library_track_row_${track.id}'),
            selected: isCurrent,
            contentPadding: compactActions
                ? const EdgeInsets.symmetric(horizontal: 10)
                : null,
            horizontalTitleGap: compactActions ? 8 : null,
            minLeadingWidth: compactActions ? 40 : null,
            selectedTileColor: theme.colorScheme.primaryContainer.withValues(
              alpha: 0.28,
            ),
            leading: Stack(
              children: [
                Container(
                  width: compactActions ? 40 : 48,
                  height: compactActions ? 40 : 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.music_note),
                ),
                if (!track.mbVerified)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color:
                            track.hasSuggestions ? Colors.orange : Colors.grey,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        track.hasSuggestions
                            ? Icons.auto_fix_high
                            : Icons.help_outline,
                        size: 8,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    track.title,
                    key: ValueKey('library_track_title_${track.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? theme.colorScheme.primary : null,
                      fontWeight: isCurrent ? FontWeight.w700 : null,
                    ),
                  ),
                ),
                if (track.needsVerification && !compactActions) ...[
                  const SizedBox(width: 8),
                  UnverifiedTrackIndicator(
                    onTap: () => _showMatchSuggestions(context),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              key: ValueKey('library_track_trailing_${track.id}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                SongMetadataChips(
                  analysis: track.analysis,
                  singleLine: true,
                  compact: true,
                ),
                if (hasMetadata) const SizedBox(width: 6),
                if (!compactActions) ...[
                  if (isCurrent) ...[
                    Icon(
                      Icons.equalizer,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    track.formattedDuration,
                    style: theme.textTheme.bodySmall,
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      _liked ? Icons.favorite : Icons.favorite_border,
                      color: _liked ? theme.colorScheme.primary : null,
                    ),
                    tooltip: _liked ? 'Unlike' : 'Like',
                    onPressed: _likeInFlight ? null : _toggleLike,
                  ),
                  DownloadButton(track: track),
                ],
                IconButton(
                  key: ValueKey('library_track_more_${track.id}'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'More actions',
                  onPressed: () => _showActions(context),
                ),
              ],
            ),
            onTap: () => _playTrack(context),
            onLongPress: track.needsVerification
                ? () => _showMatchSuggestions(context)
                : () => _showActions(context),
          ),
        );
      },
    );
  }

  Future<void> _addToQueue() async {
    final playback = context.read<PlaybackState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await addTrackToQueue(playback.enqueue, track);
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

  Future<void> _toggleLike() async {
    if (_likeInFlight) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _likeInFlight = true);
    try {
      await runOptimisticLikeToggle(
        current: _liked,
        like: () => _libraryService.like(track.id),
        unlike: () => _libraryService.unlike(track.id),
        applyOptimistic: (liked) {
          if (mounted) setState(() => _liked = liked);
        },
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not update liked status')),
      );
    } finally {
      if (mounted) setState(() => _likeInFlight = false);
    }
  }

  void _showActions(BuildContext context) {
    final playback = context.read<PlaybackState>();

    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (track.needsVerification)
                ListTile(
                  key: ValueKey('library_review_match_${track.id}'),
                  leading: const Icon(Icons.auto_fix_high),
                  title: const Text('Review match'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _showMatchSuggestions(context);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to queue'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _addToQueue();
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: const Text('Play next'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  playTrackNext(playback.playNext, track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _addToPlaylist();
                },
              ),
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('Go to artist'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _goToArtist();
                },
              ),
              ListTile(
                leading: const Icon(Icons.album),
                title: const Text('Go to album'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _goToAlbum();
                },
              ),
              ListTile(
                leading: Icon(_liked ? Icons.favorite : Icons.favorite_border),
                title: Text(_liked ? 'Unlike' : 'Like'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _toggleLike();
                },
              ),
              ListTile(
                key: ValueKey('library_download_action_${track.id}'),
                title: const Text('Download'),
                trailing: DownloadButton(track: track),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove from library'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _removeFromLibrary();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addToPlaylist() async {
    final messenger = ScaffoldMessenger.of(context);
    List<core_models.Playlist> playlists;
    try {
      playlists = await _libraryService.getPlaylists();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to load playlists')),
      );
      return;
    }
    if (!mounted) return;

    final selected = await showModalBottomSheet<core_models.Playlist>(
      context: context,
      builder: (context) => PlaylistPickerSheet(playlists: playlists),
    );
    if (selected == null) return;

    try {
      await _libraryService.addTrackToPlaylist(
        selected.id,
        track.id.toString(),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Added to ${selected.name}')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to add to playlist')),
      );
    }
  }

  void _goToArtist() {
    final mbid = track.mbArtistId;
    if (mbid == null || mbid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No artist details for this track')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArtistDetailScreen(
          artistMbid: mbid,
          apiClient: widget.detailApiClient,
        ),
      ),
    );
  }

  void _goToAlbum() {
    final mbid = track.mbReleaseId;
    if (mbid == null || mbid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No album details for this track')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumDetailScreen(
          albumMbid: mbid,
          apiClient: widget.detailApiClient,
        ),
      ),
    );
  }

  Future<void> _removeFromLibrary() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _libraryService.removeTrackFromLibrary(track.id.toString());
      messenger.showSnackBar(
        const SnackBar(content: Text('Removed from library')),
      );
      onTrackUpdated?.call();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to remove from library')),
      );
    }
  }

  void _showUnverifiedTrackSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _UnverifiedTrackSheet(track: track),
    );
  }
}

class _UnverifiedTrackSheet extends StatelessWidget {
  final Track track;

  const _UnverifiedTrackSheet({required this.track});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sourceDisplay = _getSourceDisplay();

    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Colors.orange[400],
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Unverified Track',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'This track\'s metadata has not been verified against MusicBrainz.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          _buildInfoRow(context, 'Title', track.title),
          _buildInfoRow(context, 'Artist', track.displayArtist),
          if (track.album != null)
            _buildInfoRow(context, 'Album', track.album!),
          _buildInfoRow(context, 'Source', sourceDisplay.name),
          if (sourceDisplay.url != null)
            _buildInfoRow(context, 'URL', sourceDisplay.url!, isUrl: true),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    // TODO: Navigate to metadata editor
                  },
                  icon: const Icon(Icons.edit),
                  label: const Text('Fix metadata'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    // TODO: Navigate to MusicBrainz search
                  },
                  icon: const Icon(Icons.search),
                  label: const Text('Find match'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value,
      {bool isUrl = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isUrl ? theme.colorScheme.primary : null,
              ),
              maxLines: isUrl ? 1 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  ({String name, String? url}) _getSourceDisplay() {
    final sourceType = track.sourceType?.toLowerCase();
    final sourceUrl = track.sourceUrl;

    String name;
    switch (sourceType) {
      case 'youtube':
        name = 'YouTube';
        break;
      case 'soundcloud':
        name = 'SoundCloud';
        break;
      case 'bandcamp':
        name = 'Bandcamp';
        break;
      default:
        name = sourceType ?? 'Unknown';
    }

    return (name: name, url: sourceUrl);
  }
}
