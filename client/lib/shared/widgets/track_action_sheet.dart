import 'package:flutter/material.dart';
import '../../core/services/services.dart';

class TrackActionSheet extends StatefulWidget {
  final String trackTitle;
  final String? trackArtist;
  final String trackMbid;
  final String? artistMbid;
  final String? albumMbid;
  final ApiClient apiClient;
  final VoidCallback? onViewArtist;
  final VoidCallback? onViewAlbum;

  const TrackActionSheet({
    super.key,
    required this.trackTitle,
    this.trackArtist,
    required this.trackMbid,
    this.artistMbid,
    this.albumMbid,
    required this.apiClient,
    this.onViewArtist,
    this.onViewAlbum,
  });

  @override
  State<TrackActionSheet> createState() => _TrackActionSheetState();
}

class _TrackActionSheetState extends State<TrackActionSheet> {
  late final LibraryService _libraryService;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _libraryService = LibraryService(widget.apiClient);
  }

  Future<void> _addToLibrary() async {
    setState(() => _isLoading = true);
    try {
      await _libraryService.addTrackToLibrary(widget.trackMbid);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added to library')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to add to library: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  widget.trackTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.trackArtist != null)
                  Text(
                    widget.trackArtist!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            )
          else ...[
            ListTile(
              leading: const Icon(Icons.library_add),
              title: const Text('Add to library'),
              onTap: _addToLibrary,
            ),
            if (widget.onViewArtist != null)
              ListTile(
                leading: const Icon(Icons.person),
                title: const Text('View artist'),
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onViewArtist!();
                },
              ),
            if (widget.onViewAlbum != null)
              ListTile(
                leading: const Icon(Icons.album),
                title: const Text('View album'),
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onViewAlbum!();
                },
              ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
