import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/models/models.dart';
import '../../../core/services/services.dart';
import '../widgets/track_tile.dart';
import '../widgets/artist_tile.dart';
import '../widgets/album_tile.dart';
import '../../discovery/screens/artist_detail_screen.dart';
import '../../discovery/screens/album_detail_screen.dart';
import '../../../shared/widgets/track_action_sheet.dart';

enum SearchTab { tracks, artists, albums }

class SearchScreen extends StatefulWidget {
  final ApiClient apiClient;

  const SearchScreen({super.key, required this.apiClient});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final SearchService _searchService;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Timer? _debounceTimer;
  String _query = '';
  SearchTab _currentTab = SearchTab.tracks;

  List<TrackResult> _tracks = [];
  List<ArtistResult> _artists = [];
  List<AlbumResult> _albums = [];

  int _trackTotal = 0;
  int _artistTotal = 0;
  int _albumTotal = 0;

  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _searchService = SearchService(widget.apiClient);

    _tabController.addListener(_onTabChanged);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _tabController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {
      _currentTab = SearchTab.values[_tabController.index];
    });
    if (_query.isNotEmpty) {
      _search();
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value != _query) {
        setState(() {
          _query = value;
        });
        _search();
      }
    });
  }

  Future<void> _search() async {
    if (_query.isEmpty) {
      setState(() {
        _tracks = [];
        _artists = [];
        _albums = [];
        _trackTotal = 0;
        _artistTotal = 0;
        _albumTotal = 0;
        _error = null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      switch (_currentTab) {
        case SearchTab.tracks:
          final response = await _searchService.searchTracks(_query);
          setState(() {
            _tracks = response.results;
            _trackTotal = response.total;
          });
          break;
        case SearchTab.artists:
          final response = await _searchService.searchArtists(_query);
          setState(() {
            _artists = response.results;
            _artistTotal = response.total;
          });
          break;
        case SearchTab.albums:
          final response = await _searchService.searchAlbums(_query);
          setState(() {
            _albums = response.results;
            _albumTotal = response.total;
          });
          break;
      }
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _error = 'An error occurred. Please try again.';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || _isLoading) return;

    final hasMore = switch (_currentTab) {
      SearchTab.tracks => _tracks.length < _trackTotal,
      SearchTab.artists => _artists.length < _artistTotal,
      SearchTab.albums => _albums.length < _albumTotal,
    };

    if (!hasMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      switch (_currentTab) {
        case SearchTab.tracks:
          final response = await _searchService.searchTracks(
            _query,
            offset: _tracks.length,
          );
          setState(() {
            _tracks = [..._tracks, ...response.results];
          });
          break;
        case SearchTab.artists:
          final response = await _searchService.searchArtists(
            _query,
            offset: _artists.length,
          );
          setState(() {
            _artists = [..._artists, ...response.results];
          });
          break;
        case SearchTab.albums:
          final response = await _searchService.searchAlbums(
            _query,
            offset: _albums.length,
          );
          setState(() {
            _albums = [..._albums, ...response.results];
          });
          break;
      }
    } catch (e) {
      // Silent fail for load more
    } finally {
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  void _showTrackActions(TrackResult track) {
    showModalBottomSheet(
      context: context,
      builder: (context) => TrackActionSheet(
        trackTitle: track.title,
        trackArtist: track.artist,
        trackMbid: track.mbid,
        artistMbid: track.artistMbid,
        albumMbid: track.albumMbid,
        apiClient: widget.apiClient,
        onViewArtist: track.artistMbid != null
            ? () => _navigateToArtist(track.artistMbid!)
            : null,
        onViewAlbum: track.albumMbid != null
            ? () => _navigateToAlbum(track.albumMbid!)
            : null,
      ),
    );
  }

  void _navigateToArtist(String mbid) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ArtistDetailScreen(
          artistMbid: mbid,
          apiClient: widget.apiClient,
        ),
      ),
    );
  }

  void _navigateToAlbum(String mbid) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AlbumDetailScreen(
          albumMbid: mbid,
          apiClient: widget.apiClient,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search tracks, artists, albums...',
            border: InputBorder.none,
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  )
                : null,
          ),
          onChanged: _onSearchChanged,
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Tracks'),
            Tab(text: 'Artists'),
            Tab(text: 'Albums'),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_query.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Search for music',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _search,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return TabBarView(
      controller: _tabController,
      children: [
        _buildTracksList(),
        _buildArtistsList(),
        _buildAlbumsList(),
      ],
    );
  }

  Widget _buildTracksList() {
    if (_tracks.isEmpty) {
      return _buildEmptyState('No tracks found');
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _tracks.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _tracks.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return TrackTile(
          track: _tracks[index],
          onTap: () => _showTrackActions(_tracks[index]),
        );
      },
    );
  }

  Widget _buildArtistsList() {
    if (_artists.isEmpty) {
      return _buildEmptyState('No artists found');
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _artists.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _artists.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return ArtistTile(
          artist: _artists[index],
          onTap: () => _navigateToArtist(_artists[index].mbid),
        );
      },
    );
  }

  Widget _buildAlbumsList() {
    if (_albums.isEmpty) {
      return _buildEmptyState('No albums found');
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _albums.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _albums.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return AlbumTile(
          album: _albums[index],
          onTap: () => _navigateToAlbum(_albums[index].mbid),
        );
      },
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
