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
  const SearchScreen({
    super.key,
    @visibleForTesting this.initialQueue = const [],
  });

  @visibleForTesting
  final List<DiscoveryQueueItem> initialQueue;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  Timer? _debounceTimer;
  Timer? _pollTimer;

  late DiscoveryService _discoveryService;
  DiscoverySearchResponse? _response;
  late final List<DiscoveryQueueItem> _queue = List.of(widget.initialQueue);

  int _searchRequestSerial = 0;
  bool _isPollingQueue = false;

  bool _isSearching = false;
  String _query = '';
  String? _searchError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _discoveryService = DiscoveryService(context.read<ApiClient>());
    _ensurePolling();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final next = value.trim();
    _debounceTimer?.cancel();
    if (next.isEmpty) {
      _searchRequestSerial++;
      setState(() {
        _query = '';
        _response = null;
        _searchError = null;
        _isSearching = false;
      });
      return;
    }

    setState(() {});
    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (next == _query) return;
      _runSearch(query: next);
    });
  }

  Future<void> _runSearch({String? query}) async {
    final searchText = (query ?? _queryController.text).trim();
    _debounceTimer?.cancel();
    final requestId = ++_searchRequestSerial;

    if (searchText.isEmpty) {
      setState(() {
        _query = '';
        _response = null;
        _searchError = null;
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _query = searchText;
      _isSearching = true;
      _searchError = null;
    });

    try {
      final response = await _discoveryService.search(searchText);
      if (!mounted ||
          requestId != _searchRequestSerial ||
          _query != searchText) {
        return;
      }
      setState(() {
        _response = response;
      });
    } catch (error) {
      if (!mounted ||
          requestId != _searchRequestSerial ||
          _query != searchText) {
        return;
      }
      setState(() {
        _searchError = _friendlyApiError(error);
      });
    } finally {
      if (mounted && requestId == _searchRequestSerial) {
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
    final pending = DiscoveryQueueItem(
      localId: localId,
      candidate: candidate,
      playbackState: 'queued',
      canPlay: false,
      canRetry: false,
      canRemove: false,
    );

    setState(() {
      _queue.insert(0, pending);
    });

    try {
      final queue = await _discoveryService.addQueueItem(candidate);
      _replaceQueue(queue.items);
    } catch (error) {
      _replaceQueueItem(
        localId,
        (current) => current.copyWith(
          playbackState: 'failed',
          error: _friendlyApiError(error),
          canRetry: true,
          canRemove: true,
        ),
      );
    } finally {
      _ensurePolling();
    }
  }

  void _replaceQueue(List<DiscoveryQueueItem> items) {
    if (!mounted) return;
    setState(() {
      _queue
        ..clear()
        ..addAll(items);
    });
  }

  void _ensurePolling() {
    if (!mounted) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    final hasActive = _queue.any((item) => item.isActive);
    if (!hasActive) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      _pollActiveJobs();
    });
  }

  Future<void> _pollActiveJobs({bool force = false}) async {
    if (!mounted || _isPollingQueue) return;
    if (!force && !_queue.any((item) => item.isActive)) {
      _ensurePolling();
      return;
    }

    _isPollingQueue = true;
    try {
      final queue = await _discoveryService.getQueue();
      if (!mounted) return;
      _replaceQueue(queue.items);
    } catch (error) {
      if (mounted) {
        setState(() {
          _searchError = _friendlyApiError(error);
        });
      }
    } finally {
      _isPollingQueue = false;
      if (mounted) {
        _ensurePolling();
      } else {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    }
  }

  Future<void> _retryItem(DiscoveryQueueItem item) async {
    final queueItemId = item.queueItemId;
    if (queueItemId == null || !item.canRetry) return;

    _replaceQueueItem(
      item.localId,
      (current) => current.copyWith(
        playbackState: 'queued',
        progress: 0,
        clearError: true,
        canRetry: false,
      ),
    );

    try {
      final queue = await _discoveryService.retryQueueItem(queueItemId);
      _replaceQueue(queue.items);
    } catch (error) {
      _replaceQueueItem(
        item.localId,
        (current) => current.copyWith(
          playbackState: 'failed',
          error: _friendlyApiError(error),
          canRetry: true,
        ),
      );
    } finally {
      _ensurePolling();
    }
  }

  Future<void> _playItem(DiscoveryQueueItem item) async {
    final trackId = item.trackId;
    if (trackId == null) return;

    try {
      await context.read<PlaybackState>().playTrack({
        'id': trackId,
        'title': item.title,
        'artist': item.artist,
        'album': item.candidate.album ?? item.candidate.provider,
        'duration': item.candidate.durationSeconds,
        'artwork_url': item.thumbnailUrl,
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

  Future<void> _removeItem(DiscoveryQueueItem item) async {
    final previousQueue = List<DiscoveryQueueItem>.from(_queue);
    setState(() {
      _queue.removeWhere((queued) => queued.localId == item.localId);
    });

    final queueItemId = item.queueItemId;
    if (queueItemId == null) {
      _ensurePolling();
      return;
    }

    try {
      final queue = await _discoveryService.removeQueueItem(queueItemId);
      _replaceQueue(queue.items);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _queue
          ..clear()
          ..addAll(previousQueue);
        _searchError = _friendlyApiError(error);
      });
    } finally {
      _ensurePolling();
    }
  }

  bool _isCandidateQueued(DiscoveryCandidate candidate) {
    final key = candidate.candidateId.isNotEmpty
        ? candidate.candidateId
        : candidate.sourceUrl;
    return _queue.any((item) => item.localId == key);
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final previousQueue = List<DiscoveryQueueItem>.from(_queue);
    final item = _queue[oldIndex];
    final queueItemId = item.queueItemId;

    setState(() {
      final moved = _queue.removeAt(oldIndex);
      _queue.insert(newIndex, moved);
    });

    if (queueItemId == null) return;

    try {
      final queue = await _discoveryService.reorderQueueItem(
        queueItemId: queueItemId,
        toPosition: newIndex,
      );
      _replaceQueue(queue.items);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _queue
          ..clear()
          ..addAll(previousQueue);
        _searchError = _friendlyApiError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Mobile Discovery',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh queue',
            onPressed:
                _queue.isNotEmpty ? () => _pollActiveJobs(force: true) : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            if (_query.isNotEmpty) _runSearch(),
            _pollActiveJobs(force: true),
          ]);
        },
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            _buildSearchBox(),
            if (_searchError != null)
              _buildErrorCard(_searchError!, _runSearch),
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
      onSubmitted: (value) => _runSearch(query: value),
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
      margin: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < 520;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildThumb(candidate.thumbnailUrl, size: mobile ? 42 : 48),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        candidate.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        candidate.displaySubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildQueueAction(candidate, queued, mobile: mobile),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildQueueAction(
    DiscoveryCandidate candidate,
    bool queued, {
    required bool mobile,
  }) {
    final onPressed = !candidate.downloadable || queued
        ? null
        : () => _queueCandidate(candidate);
    final icon = queued ? Icons.check : Icons.playlist_add;
    final label = queued ? 'Queued' : 'Queue';

    if (mobile) {
      return IconButton.filledTonal(
        tooltip: label,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: Icon(icon),
      );
    }

    return FilledButton.tonalIcon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(84, 36),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _buildCompactTile({
    required Widget leading,
    required Widget title,
    required Widget subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [title, const SizedBox(height: 3), subtitle],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
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
                direction: item.canRemove
                    ? DismissDirection.endToStart
                    : DismissDirection.none,
                onDismissed: (_) => _removeItem(item),
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
    final canPlay = item.canPlay;
    final canRetry = item.canRetry;

    return Card(
      key: ValueKey(item.localId),
      margin: const EdgeInsets.only(bottom: 8),
      child: _buildCompactTile(
        leading: _buildStatusLeading(item),
        title: Text(
          item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            height: 1.18,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.error ?? item.candidate.displaySubtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.16,
              ),
            ),
            const SizedBox(height: 5),
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
      return _buildThumb(item.thumbnailUrl, overlay: Icons.check, size: 42);
    }
    if (item.isFailed) {
      return _buildThumb(item.thumbnailUrl, overlay: Icons.error, size: 42);
    }
    return SizedBox(
      width: 42,
      height: 42,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _buildThumb(item.thumbnailUrl, size: 42),
          CircularProgressIndicator(
            value: item.progress > 0 ? item.progress / 100 : null,
            strokeWidth: 2.5,
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

  Widget _buildThumb(String? url, {IconData? overlay, double size = 48}) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _thumbPlaceholder(size: size),
              )
            else
              _thumbPlaceholder(size: size),
            if (overlay != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.42),
                ),
                child: Icon(overlay, color: Colors.white, size: size * 0.48),
              ),
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder({double size = 48}) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.46,
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
