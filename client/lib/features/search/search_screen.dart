import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/audio/playback_state.dart';
import '../../core/audio/signed_audio_url_service.dart';
import '../../core/discovery/discovery_models.dart';
import '../../core/discovery/discovery_service.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  Timer? _debounceTimer;
  Timer? _pollTimer;

  late DiscoveryService _discoveryService;
  DiscoverySearchResponse? _response;
  final List<DiscoveryQueueItem> _queue = [];

  bool _isSearching = false;
  bool _isPolling = false;
  String _query = '';
  int _searchGeneration = 0;
  String? _searchError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _discoveryService = DiscoveryService(context.read<ApiClient>());
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounceTimer?.cancel();
    final next = value.trim();
    if (next == _query) return;

    _searchGeneration++;
    setState(() {
      _query = next;
      _response = null;
      _searchError = null;
      _isSearching = next.isNotEmpty;
    });

    if (next.isEmpty) return;

    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      _runSearch(next);
    });
  }

  Future<void> _runSearch(String query) async {
    if (query.isEmpty) return;
    final generation = ++_searchGeneration;

    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    try {
      final response = await _discoveryService.search(query);
      if (!mounted || generation != _searchGeneration || query != _query) {
        return;
      }
      setState(() {
        _response = response;
      });
    } catch (error) {
      if (!mounted || generation != _searchGeneration || query != _query) {
        return;
      }
      setState(() {
        _searchError = _friendlyApiError(error);
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  Future<void> _queueCandidate(DiscoveryCandidate candidate) async {
    if (!candidate.downloadable || _isCandidateQueued(candidate)) return;

    final localId = candidate.candidateId.isNotEmpty
        ? candidate.candidateId
        : candidate.sourceUrl;
    final item = DiscoveryQueueItem(localId: localId, candidate: candidate);

    setState(() {
      _queue.insert(0, item);
    });
    _ensurePolling();

    try {
      final snapshot = await _discoveryService.createDownload(candidate);
      _replaceQueueItem(localId, (current) => current.withSnapshot(snapshot));
    } catch (error) {
      _replaceQueueItem(
        localId,
        (current) =>
            current.copyWith(status: 'failed', error: _friendlyApiError(error)),
      );
    } finally {
      _ensurePolling();
    }
  }

  void _ensurePolling() {
    final hasActive = _queue.any((item) => item.jobId != null && item.isActive);
    if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _pollActiveJobs();
    });
  }

  Future<void> _pollActiveJobs() async {
    if (_isPolling || !mounted) return;
    _isPolling = true;

    final pending = _queue
        .where((item) => item.jobId != null && item.isActive)
        .map((item) => item.jobId!)
        .toList();

    try {
      for (final jobId in pending) {
        if (!mounted) return;
        try {
          final snapshot = await _discoveryService.getJob(jobId);
          if (!mounted) return;
          _replaceJobItem(jobId, (current) => current.withSnapshot(snapshot));
        } catch (error) {
          if (!mounted) return;
          _replaceJobItem(
            jobId,
            (current) => current.copyWith(
              status: 'failed',
              error: _friendlyApiError(error),
            ),
          );
        }
      }
    } finally {
      _isPolling = false;
      if (mounted) _ensurePolling();
    }
  }

  Future<void> _retryItem(DiscoveryQueueItem item) async {
    _removeItem(item.localId);
    await _queueCandidate(item.candidate);
  }

  Future<void> _playItem(DiscoveryQueueItem item) async {
    final trackId = item.trackId;
    if (trackId == null) return;

    try {
      await context.read<PlaybackState>().playTrack({
        'id': trackId,
        'title': item.candidate.title,
        'artist': item.candidate.artist ?? item.candidate.uploader,
        'album': item.candidate.provider,
        'duration': item.candidate.durationSeconds,
        'artwork_url': item.candidate.thumbnailUrl,
      });
    } on SignedAudioUrlException {
      // PlaybackState exposes the user-facing error. Pressing play again asks
      // the backend for a fresh signed URL, so expired MinIO links recover here.
    } catch (_) {
      // Keep the queue usable even if just_audio rejects the object URL.
    }
  }

  void _replaceQueueItem(
    String localId,
    DiscoveryQueueItem Function(DiscoveryQueueItem current) update,
  ) {
    if (!mounted) return;
    final index = _queue.indexWhere((item) => item.localId == localId);
    if (index == -1) return;
    setState(() {
      _queue[index] = update(_queue[index]);
    });
  }

  void _replaceJobItem(
    String jobId,
    DiscoveryQueueItem Function(DiscoveryQueueItem current) update,
  ) {
    if (!mounted) return;
    final index = _queue.indexWhere((item) => item.jobId == jobId);
    if (index == -1) return;
    setState(() {
      _queue[index] = update(_queue[index]);
    });
  }

  void _removeItem(String localId) {
    setState(() {
      _queue.removeWhere((item) => item.localId == localId);
    });
    _ensurePolling();
  }

  bool _isCandidateQueued(DiscoveryCandidate candidate) {
    final key = candidate.candidateId.isNotEmpty
        ? candidate.candidateId
        : candidate.sourceUrl;
    return _queue.any((item) => item.localId == key);
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _queue.removeAt(oldIndex);
      _queue.insert(newIndex, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile Discovery'),
        actions: [
          IconButton(
            tooltip: 'Refresh jobs',
            onPressed: _queue.any((item) => item.jobId != null)
                ? _pollActiveJobs
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            if (_query.isNotEmpty) _runSearch(_query),
            _pollActiveJobs(),
          ]);
        },
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            _buildSearchBox(),
            if (_searchError != null)
              _buildErrorCard(_searchError!, () => _runSearch(_query)),
            if (_response != null) _buildProviderRow(_response!.providers),
            const SizedBox(height: 12),
            _buildResultsSection(),
            const SizedBox(height: 24),
            _buildQueueSection(playback),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBox() {
    return TextField(
      controller: _queryController,
      minLines: 1,
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: (value) {
        _debounceTimer?.cancel();
        final next = value.trim();
        if (next != _query) {
          setState(() {
            _query = next;
          });
        }
        if (next.isEmpty) {
          _searchGeneration++;
          setState(() {
            _response = null;
            _searchError = null;
            _isSearching = false;
          });
          return;
        }
        _runSearch(next);
      },
      decoration: InputDecoration(
        labelText: 'Search YouTube / SoundCloud',
        hintText: 'lofi study mix, live set, bootleg...',
        prefixIcon: const Icon(Icons.travel_explore),
        suffixIcon: _queryController.text.isNotEmpty
            ? IconButton(
                tooltip: 'Clear search',
                onPressed: () {
                  _queryController.clear();
                  _onQueryChanged('');
                },
                icon: const Icon(Icons.clear),
              )
            : null,
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildResultsSection() {
    if (_query.isEmpty) {
      return _buildEmptyPanel(
        icon: Icons.search,
        title: 'Find external tracks',
        body:
            'Results queue into local download jobs before playback. yes, the control plane has to do its little dance.',
      );
    }

    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final results = _response?.results ?? const <DiscoveryCandidate>[];
    if (results.isEmpty) {
      return _buildEmptyPanel(
        icon: Icons.search_off,
        title: 'No results',
        body:
            'Try a different query or provider once yt-dlp stops being dramatic.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Results',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ...results.map(_buildResultTile),
      ],
    );
  }

  Widget _buildResultTile(DiscoveryCandidate candidate) {
    final queued = _isCandidateQueued(candidate);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        minVerticalPadding: 12,
        leading: _buildThumb(candidate.thumbnailUrl),
        title: Text(
          candidate.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          candidate.displaySubtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: SizedBox(
          width: 96,
          child: FilledButton.tonalIcon(
            onPressed: !candidate.downloadable || queued
                ? null
                : () => _queueCandidate(candidate),
            icon: Icon(queued ? Icons.check : Icons.playlist_add),
            label: Text(queued ? 'Queued' : 'Queue'),
          ),
        ),
      ),
    );
  }

  Widget _buildQueueSection(PlaybackState playback) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Download queue',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text('${_queue.length} item${_queue.length == 1 ? '' : 's'}'),
          ],
        ),
        if (playback.isResolvingSignedUrl)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (playback.playbackError != null)
          _buildErrorCard(playback.playbackError!, () async {
            final playable = _queue.where((item) => item.isPlayable);
            if (playable.isNotEmpty) await _playItem(playable.first);
          }, label: 'Try first playable'),
        const SizedBox(height: 8),
        if (_queue.isEmpty)
          _buildEmptyPanel(
            icon: Icons.queue_music,
            title: 'Nothing queued',
            body:
                'Tap Queue on a result. Pending, downloading, failed, and playable states show up here.',
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _queue.length,
            onReorderItem: _onReorder,
            itemBuilder: (context, index) {
              final item = _queue[index];
              return Dismissible(
                key: ValueKey('dismiss-${item.localId}'),
                direction: DismissDirection.endToStart,
                onDismissed: (_) => _removeItem(item.localId),
                background: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                child: _buildQueueTile(item, index),
              );
            },
          ),
      ],
    );
  }

  Widget _buildQueueTile(DiscoveryQueueItem item, int index) {
    final canPlay = item.isPlayable;
    final canRetry = item.isFailed;

    return Card(
      key: ValueKey(item.localId),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        minVerticalPadding: 12,
        leading: _buildStatusLeading(item),
        title: Text(
          item.candidate.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.error ?? item.candidate.displaySubtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            _buildStatusPill(item),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canPlay)
              IconButton.filled(
                tooltip: 'Play from signed URL',
                onPressed: () => _playItem(item),
                icon: const Icon(Icons.play_arrow),
              )
            else if (canRetry)
              IconButton.filledTonal(
                tooltip: 'Retry download',
                onPressed: () => _retryItem(item),
                icon: const Icon(Icons.refresh),
              ),
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.drag_handle),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusLeading(DiscoveryQueueItem item) {
    if (item.isPlayable) {
      return _buildThumb(item.candidate.thumbnailUrl, overlay: Icons.check);
    }
    if (item.isFailed) {
      return _buildThumb(item.candidate.thumbnailUrl, overlay: Icons.error);
    }
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildThumb(item.candidate.thumbnailUrl),
          CircularProgressIndicator(
            value: item.progress > 0 ? item.progress / 100 : null,
            strokeWidth: 3,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(DiscoveryQueueItem item) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = item.isFailed
        ? colorScheme.errorContainer
        : item.isPlayable
            ? colorScheme.primaryContainer
            : colorScheme.secondaryContainer;
    final textColor = item.isFailed
        ? colorScheme.onErrorContainer
        : item.isPlayable
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSecondaryContainer;

    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            '${item.statusLabel}${item.isActive && item.progress > 0 ? ' • ${item.progress}%' : ''}',
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProviderRow(List<DiscoveryProviderSummary> providers) {
    if (providers.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: providers.map((provider) {
          final ok = provider.status == 'ok';
          return Tooltip(
            message: provider.errorMessage ??
                '${provider.resultCount} result(s) in ${provider.elapsedMs}ms',
            child: Chip(
              avatar: Icon(
                ok ? Icons.check_circle : Icons.info_outline,
                size: 18,
              ),
              label: Text('${provider.provider}: ${provider.status}'),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildThumb(String? url, {IconData? overlay}) {
    return SizedBox(
      width: 56,
      height: 56,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _thumbPlaceholder(),
              )
            else
              _thumbPlaceholder(),
            if (overlay != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.42),
                ),
                child: Icon(overlay, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildErrorCard(
    String message,
    Future<void> Function() onRetry, {
    String label = 'Retry',
  }) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: Text(label)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPanel({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _friendlyApiError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map<String, dynamic>) {
        return data['message'] as String? ?? error.message ?? 'Request failed.';
      }
      return error.message ?? 'Request failed.';
    }
    if (error is DiscoveryException) return error.message;
    return 'Something failed. naturally.';
  }
}
