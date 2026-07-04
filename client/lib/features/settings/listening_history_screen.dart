import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_context.dart';
import '../../core/audio/playback_state.dart';
import '../../core/services/api_client.dart';
import '../../core/services/home_service.dart';
import '../../shared/widgets/track_tile.dart';

class ListeningHistoryScreen extends StatefulWidget {
  const ListeningHistoryScreen({
    super.key,
    this.service,
  });

  final HomeService? service;

  @override
  State<ListeningHistoryScreen> createState() => _ListeningHistoryScreenState();
}

class _ListeningHistoryScreenState extends State<ListeningHistoryScreen> {
  static const _pageSize = 50;

  late final HomeService _service = widget.service ?? HomeService(ApiClient());

  final List<ListeningHistoryEntry> _entries = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final entries = await _service.listeningHistory(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _entries
          ..clear()
          ..addAll(entries);
        _hasMore = entries.length == _pageSize;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load listening history.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final entries = await _service.listeningHistory(
        limit: _pageSize,
        offset: _entries.length,
      );
      if (!mounted) return;
      setState(() {
        _entries.addAll(entries);
        _hasMore = entries.length == _pageSize;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load more history')),
      );
    }
  }

  Future<void> _playEntry(ListeningHistoryEntry entry) async {
    final playback = context.read<PlaybackState>();
    try {
      await playback.playQueue(
        [entry.track.toPlaybackJson()],
        context: const PlaybackContext(
          kind: PlaybackContextKind.library,
          label: 'Listening History',
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(playback.playbackError ?? 'Could not play this track.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Listening History')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history_toggle_off, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_entries.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 48),
            SizedBox(height: 12),
            Text('No listening history yet'),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadInitial,
      child: ListView.builder(
        itemCount: _entries.length + 1,
        itemBuilder: (context, index) {
          if (index == _entries.length) {
            return _buildFooter();
          }
          final entry = _entries[index];
          return TrackTile.fromTrack(
            entry.track,
            onTap: () => _playEntry(entry),
            trailing: Text(
              _relativePlayedAt(entry.playedAt),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    if (!_hasMore) {
      return const SizedBox(height: 24);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: OutlinedButton.icon(
        onPressed: _isLoadingMore ? null : _loadMore,
        icon: _isLoadingMore
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.expand_more),
        label: Text(_isLoadingMore ? 'Loading...' : 'Load more'),
      ),
    );
  }
}

String _relativePlayedAt(DateTime playedAt) {
  final now = DateTime.now();
  final local = playedAt.toLocal();
  final diff = now.difference(local);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${local.month}/${local.day}/${local.year}';
}
