import 'package:flutter/material.dart';
import '../../../core/models/models.dart';
import '../../../core/services/services.dart';
import 'album_detail_screen.dart';

class ArtistDetailScreen extends StatefulWidget {
  final String artistMbid;
  final ApiClient apiClient;

  const ArtistDetailScreen({
    super.key,
    required this.artistMbid,
    required this.apiClient,
  });

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  late final BrowseService _browseService;

  ArtistDetail? _artist;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _browseService = BrowseService(widget.apiClient);
    _loadArtist();
  }

  Future<void> _loadArtist() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final artist = await _browseService.getArtist(widget.artistMbid);
      setState(() {
        _artist = artist;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load artist details';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
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
      body: _buildBody(),
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
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadArtist,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_artist == null) {
      return const Center(child: Text('Artist not found'));
    }

    return CustomScrollView(
      slivers: [
        _buildAppBar(),
        _buildArtistInfo(),
        _buildDiscographyHeader(),
        _buildDiscography(),
      ],
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          _artist!.name,
          style: const TextStyle(shadows: [
            Shadow(color: Colors.black54, blurRadius: 8),
          ]),
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primaryContainer,
                Theme.of(context).colorScheme.surface,
              ],
            ),
          ),
          child: Center(
            child: CircleAvatar(
              radius: 50,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Icon(
                Icons.person,
                size: 50,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtistInfo() {
    final info = <String>[];
    if (_artist!.typeDisplay.isNotEmpty) info.add(_artist!.typeDisplay);
    if (_artist!.country != null) info.add(_artist!.country!);
    if (_artist!.activeYears != null) info.add(_artist!.activeYears!);

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.isNotEmpty)
              Text(
                info.join(' | '),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            if (_artist!.disambiguation != null) ...[
              const SizedBox(height: 8),
              Text(
                _artist!.disambiguation!,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDiscographyHeader() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          'Discography',
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
    );
  }

  Widget _buildDiscography() {
    if (_artist!.releases.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No releases found'),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.all(16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.8,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final release = _artist!.releases[index];
            return _ReleaseCard(
              release: release,
              onTap: () => _navigateToAlbum(release.id),
            );
          },
          childCount: _artist!.releases.length,
        ),
      ),
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  final ReleaseInfo release;
  final VoidCallback onTap;

  const _ReleaseCard({
    required this.release,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: release.coverArtUrl != null
                  ? Image.network(
                      release.coverArtUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(context),
                    )
                  : _buildPlaceholder(context),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    release.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  if (release.releaseYear.isNotEmpty)
                    Text(
                      release.releaseYear,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.album,
        size: 48,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
