import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:provider/provider.dart';
import '../core/audio/playback_state.dart';
import '../core/audio/playback_context.dart';
import '../core/engine/tempo_automation.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../providers/queue_provider.dart';
import '../shared/widgets/track_tile.dart';
import '../widgets/queue_item.dart';
import '../widgets/analysis_correction_sheet.dart';
import '../widgets/stacked_waveform_timeline.dart';

enum _QueueViewMode { list, timeline }

@visibleForTesting
class ListeningQueueEntry {
  const ListeningQueueEntry({
    required this.index,
    required this.item,
    required this.isCurrent,
  });

  final int index;
  final audio_service.MediaItem item;
  final bool isCurrent;
}

const double _queueReorderItemExtentPx = 64.0;

(int, int) queueListReorderIndices({
  required int relativeOldIndex,
  required int relativeNewIndex,
  required int currentIndex,
  required bool hasActiveTrack,
}) {
  final firstMovableIndex = hasActiveTrack ? currentIndex + 1 : 0;
  return (
    firstMovableIndex + relativeOldIndex,
    firstMovableIndex + relativeNewIndex,
  );
}

int queueListDragTargetIndex({
  required int relativeIndex,
  required int itemCount,
  required double dragDeltaY,
}) {
  const dragThresholdPx = 24.0;
  if (dragDeltaY.abs() < dragThresholdPx || itemCount <= 1) {
    return relativeIndex;
  }

  final delta = (dragDeltaY / _queueReorderItemExtentPx).round();
  return (relativeIndex + delta).clamp(0, itemCount - 1);
}

@visibleForTesting
List<ListeningQueueEntry> listeningQueueEntries({
  required List<audio_service.MediaItem> queue,
  required int? currentIndex,
}) {
  if (queue.isEmpty) return const [];
  final normalizedCurrent = currentIndex?.clamp(0, queue.length - 1).toInt();
  return [
    for (var i = 0; i < queue.length; i++)
      ListeningQueueEntry(
        index: i,
        item: queue[i],
        isCurrent: normalizedCurrent != null && i == normalizedCurrent,
      ),
  ];
}

@visibleForTesting
int listeningQueueRemainingMs({
  required List<audio_service.MediaItem> queue,
  required int? currentIndex,
  required Duration currentPosition,
}) {
  if (queue.isEmpty) return 0;
  final start =
      currentIndex == null ? 0 : currentIndex.clamp(0, queue.length).toInt();
  var total = 0;
  for (var i = start; i < queue.length; i++) {
    final durationMs = queue[i].duration?.inMilliseconds ?? 0;
    if (i == start) {
      total += (durationMs - currentPosition.inMilliseconds)
          .clamp(0, durationMs)
          .toInt();
    } else {
      total += durationMs;
    }
  }
  return total;
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  _QueueViewMode _viewMode = _QueueViewMode.list;
  final Set<String> _analysisRefreshesInFlight = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<QueueProvider>().loadQueue();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Consumer2<QueueProvider, PlaybackState>(
          builder: (context, provider, playback, _) {
            if (playback.queue.isNotEmpty) {
              return _buildPlaybackQueueView(context, provider, playback);
            }

            if (provider.isLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            if (provider.error != null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Error loading queue',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(provider.error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => provider.loadQueue(),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (provider.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.queue_music, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text(
                      'Your queue is empty',
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Add songs to start playing',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: [
                _buildQueueHeader(context, provider),
                Expanded(
                  child: _viewMode == _QueueViewMode.list
                      ? _buildListView(context, provider)
                      : _buildTimelineView(context, provider),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPlaybackQueueView(
    BuildContext context,
    QueueProvider provider,
    PlaybackState playback,
  ) {
    final entries = listeningQueueEntries(
      queue: playback.queue,
      currentIndex: playback.currentIndex,
    );

    return Column(
      children: [
        _buildPlaybackQueueHeader(context, playback),
        Expanded(
          child: _viewMode == _QueueViewMode.list
              ? _buildPlaybackQueueList(playback, entries)
              : _buildPlaybackTimelineView(context, provider, playback),
        ),
      ],
    );
  }

  Widget _buildPlaybackQueueHeader(
    BuildContext context,
    PlaybackState playback,
  ) {
    final queue = playback.queue;
    final remainingMs = listeningQueueRemainingMs(
      queue: queue,
      currentIndex: playback.currentIndex,
      currentPosition: playback.position,
    );
    final contextLabel = _playbackContextLabel(playback.playbackContext);
    final currentNumber = playback.currentIndex == null
        ? null
        : playback.currentIndex!.clamp(0, queue.length - 1).toInt() + 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Playback Queue',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              _buildViewSwitch(context),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (contextLabel != null) contextLabel,
              if (currentNumber != null) '$currentNumber of ${queue.length}',
              '${_formatQueueRuntime(remainingMs)} remaining',
            ].join(' • '),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  String? _playbackContextLabel(PlaybackContext? context) {
    if (context == null) return null;
    final kind = switch (context.kind) {
      PlaybackContextKind.playlist => 'Playlist',
      PlaybackContextKind.album => 'Album',
      PlaybackContextKind.artist => 'Artist',
      PlaybackContextKind.library => 'Library',
      PlaybackContextKind.queue => 'Queue',
      PlaybackContextKind.search => 'Search',
    };
    return '$kind • ${context.label}';
  }

  Widget _buildPlaybackQueueList(
    PlaybackState playback,
    List<ListeningQueueEntry> entries,
  ) {
    return CustomScrollView(
      key: const PageStorageKey('playback_queue_list_view'),
      slivers: [
        SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final item = entry.item;
            return _buildSwipeToRemoveQueueItem(
              context: context,
              key: ValueKey('remove_playback_queue_${entry.index}_${item.id}'),
              enabled: !entry.isCurrent,
              label: item.title,
              onRemove: () => _removePlaybackQueueEntry(playback, entry),
              child: TrackTile(
                key: ValueKey('playback_queue_${entry.index}_${item.id}'),
                title: item.title,
                artist: item.artist,
                album: item.album,
                duration: _formatQueueRuntime(
                  item.duration?.inMilliseconds ?? 0,
                ),
                coverArtUrl: item.artUri?.toString(),
                isCurrent: entry.isCurrent,
                onTap: entry.isCurrent
                    ? null
                    : () => _skipToPlaybackIndex(playback, entry),
              ),
            );
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  Widget _buildPlaybackTimelineView(
    BuildContext context,
    QueueProvider provider,
    PlaybackState playback,
  ) {
    final queue = playback.queue;
    if (queue.isEmpty) return const SizedBox.shrink();
    final currentIndex =
        playback.currentIndex?.clamp(0, queue.length - 1).toInt();
    if (currentIndex == null) {
      return const Center(child: Text('Start playback to edit the timeline'));
    }

    final current = _playbackTrackFor(
      queue[currentIndex],
      currentIndex,
      provider,
    );
    final previous = currentIndex > 0
        ? _playbackTrackFor(queue[currentIndex - 1], currentIndex - 1, provider)
        : null;
    final upcoming = [
      for (var i = currentIndex + 1; i < queue.length; i++)
        _playbackTrackFor(queue[i], i, provider),
    ];
    final timelineTracks = [
      if (previous != null) previous,
      current,
      ...upcoming,
    ];
    _syncPlaybackAnalyses(
      playback: playback,
      queue: queue,
      tracks: timelineTracks,
    );

    return StackedWaveformTimeline(
      key: const ValueKey('queue_surface'),
      previousTrack: previous,
      currentTrack: current,
      upcomingTracks: upcoming,
      peaksFor: provider.waveformPeaksFor,
      waveformFor: provider.waveformFor,
      trimRangeFor: (track) =>
          playback.trimRangeForQueueIndex(_playbackQueueIndex(track)),
      clipFor: (track, fallback) =>
          playback.timelineClipForQueueIndex(_playbackQueueIndex(track)) ??
          fallback,
      timelineModel: playback.timelineModel,
      pitchFallbackClipIds: playback.snapshot.pitchFallbackClipIds,
      clipTempoStates: playback.snapshot.clipTempoStates,
      playheadPositionMs: playback.timelinePositionMs,
      positionMsStream: playback.timelinePositionMsStream,
      onScrubStart: playback.beginTimelineScrub,
      onScrubUpdate: playback.updateTimelineScrub,
      onScrubEnd: playback.endTimelineScrub,
      onTimelineStartChanged: (track, ms) {
        _pauseThenEditTimeline(
          playback,
          () => playback.setQueueTimelineStartMs(
            _playbackQueueIndex(track),
            ms,
            snapToDownbeat: false,
          ),
        );
      },
      onTrimStartChanged: (track, ms) {
        _pauseThenEditTimeline(
          playback,
          () => playback.setQueueTrimStartMs(_playbackQueueIndex(track), ms),
        );
      },
      onTrimEndChanged: (track, ms) {
        _pauseThenEditTimeline(
          playback,
          () => playback.setQueueTrimEndMs(_playbackQueueIndex(track), ms),
        );
      },
      onMoveEarlier: (track) => _movePlaybackTimelineTrack(playback, track, -1),
      onMoveLater: (track) => _movePlaybackTimelineTrack(playback, track, 1),
      onEditAnalysis: (track, {initialFirstDownbeatMs}) =>
          _showAnalysisCorrectionSheet(
        context,
        provider,
        track,
        initialFirstDownbeatMs: initialFirstDownbeatMs,
      ),
    );
  }

  Future<void> _skipToPlaybackIndex(
    PlaybackState playback,
    ListeningQueueEntry entry,
  ) async {
    try {
      await playback.skipToIndex(entry.index);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not play "${entry.item.title}"')),
      );
    }
  }

  Future<void> _removePlaybackQueueEntry(
    PlaybackState playback,
    ListeningQueueEntry entry,
  ) async {
    try {
      await playback.removeFromQueue(entry.index);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove "${entry.item.title}"')),
      );
    }
  }

  Track _playbackTrackFor(
    audio_service.MediaItem item,
    int index,
    QueueProvider provider,
  ) {
    final duration = item.duration ?? Duration.zero;
    final track = Track(
      id: 'playback_queue_$index',
      queueItemId: index.toString(),
      playbackTrackId: item.id,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: duration.inSeconds,
      coverUrl: item.artUri?.toString(),
      addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    return provider.trackWithAnalysis(track);
  }

  void _syncPlaybackAnalyses({
    required PlaybackState playback,
    required List<audio_service.MediaItem> queue,
    required Iterable<Track> tracks,
  }) {
    for (final track in tracks) {
      final analysis = track.analysis;
      final trackId = _analysisTrackId(track);
      if (analysis == null || trackId == null) continue;

      final queueIndex = _playbackQueueIndex(track);
      if (queueIndex < 0 || queueIndex >= queue.length) continue;
      final nextTempo = _tempoForAnalysis(analysis);
      if (!_mediaItemNeedsAnalysisRefresh(queue[queueIndex], nextTempo)) {
        continue;
      }

      final refreshKey = '$queueIndex:$trackId:${nextTempo.hashCode}';
      if (!_analysisRefreshesInFlight.add(refreshKey)) continue;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _analysisRefreshesInFlight.remove(refreshKey);
          return;
        }
        unawaited(
          playback.refreshTrackAnalysis(trackId, analysis).whenComplete(
                () => _analysisRefreshesInFlight.remove(refreshKey),
              ),
        );
      });
    }
  }

  bool _mediaItemNeedsAnalysisRefresh(
    audio_service.MediaItem item,
    ClipTempoMetadata nextTempo,
  ) {
    if (nextTempo.isEmpty) return false;

    final extras = item.extras ?? const <String, dynamic>{};
    final currentTempo = ClipTempoMetadata.fromAnalysisSummary(
      extras['analysisSummary'] ?? extras['analysis_summary'],
      overrides: extras['analysisOverrides'] ?? extras['analysis_overrides'],
    );
    return currentTempo != nextTempo;
  }

  ClipTempoMetadata _tempoForAnalysis(TrackAnalysis analysis) =>
      ClipTempoMetadata.fromAnalysisSummary(
        analysis.summary?.toJson(),
        overrides: analysis.overrides?.toJson(),
      );

  int _playbackQueueIndex(Track track) =>
      int.tryParse(track.queueItemId) ?? int.tryParse(track.id) ?? 0;

  void _pauseThenEditTimeline(
    PlaybackState playback,
    Future<void> Function() edit,
  ) {
    unawaited(() async {
      await playback.pause();
      await edit();
    }());
  }

  void _movePlaybackTimelineTrack(
    PlaybackState playback,
    Track track,
    int delta,
  ) {
    final oldIndex = _playbackQueueIndex(track);
    final newIndex = (oldIndex + delta).clamp(0, playback.queue.length - 1);
    if (newIndex == oldIndex) return;
    _pauseThenEditTimeline(
      playback,
      () => playback.reorderPlaybackQueue(oldIndex, newIndex),
    );
  }

  Widget _buildQueueHeader(BuildContext context, QueueProvider provider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Consumer<PlaybackState>(
              builder: (context, playback, _) {
                return _buildQueueStatusPill(context, provider, playback);
              },
            ),
          ),
          const SizedBox(width: 8),
          _buildViewSwitch(context),
          PopupMenuButton<String>(
            key: const ValueKey('queue_header_menu'),
            tooltip: 'Queue actions',
            onSelected: (value) => _handleMenuAction(context, value),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.clear_all),
                  title: Text('Clear queue'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQueueStatusPill(
    BuildContext context,
    QueueProvider provider,
    PlaybackState playback,
  ) {
    final tracks = provider.queue.tracks;
    final currentIndex = provider.queue.currentIndex;
    final firstRemainingIndex = currentIndex >= 0 ? currentIndex : 0;
    var totalMs = 0;
    for (var i = firstRemainingIndex; i < tracks.length; i++) {
      final track = tracks[i];
      final trim = provider.trimRangeFor(track);
      if (i == firstRemainingIndex && currentIndex >= 0) {
        final currentRemainingMs =
            trim.endOffsetMs - playback.position.inMilliseconds;
        totalMs += currentRemainingMs.clamp(0, trim.selectedDurationMs).toInt();
      } else {
        totalMs += trim.selectedDurationMs;
      }
    }
    final count = tracks.length - firstRemainingIndex;
    final countLabel = count == 1 ? '1 track' : '$count tracks';
    final runtimeLabel = _formatQueueRuntime(totalMs);
    final suffix = currentIndex >= 0 ? 'remaining' : 'until silence';

    return Semantics(
      label: '$countLabel, $runtimeLabel $suffix',
      child: Container(
        key: const ValueKey('queue_summary_pill'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '$countLabel · $runtimeLabel $suffix',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewSwitch(BuildContext context) {
    return SizedBox(
      width: 176,
      child: SegmentedButton<_QueueViewMode>(
        key: const ValueKey('queue_view_switch'),
        segments: const [
          ButtonSegment(
            value: _QueueViewMode.list,
            icon: Icon(Icons.format_list_bulleted),
            label: Text('List'),
          ),
          ButtonSegment(
            value: _QueueViewMode.timeline,
            icon: Icon(Icons.timeline),
            label: Text('Timeline'),
          ),
        ],
        selected: {_viewMode},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          setState(() => _viewMode = selection.single);
        },
      ),
    );
  }

  Widget _buildTimelineView(BuildContext context, QueueProvider provider) {
    final currentTrack = provider.currentTrack;
    final currentIndex = provider.queue.currentIndex;
    final tracks = provider.queue.tracks;
    final upNext = currentTrack != null ? provider.upNext : tracks;
    final previousTrack = currentIndex > 0 ? tracks[currentIndex - 1] : null;

    if (currentTrack == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timeline, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(
                'Start playback to use Timeline view',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'List view is still available for reorder and remove actions.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Consumer<PlaybackState>(
      builder: (context, playback, _) => StackedWaveformTimeline(
        key: const ValueKey('queue_surface'),
        previousTrack: previousTrack,
        currentTrack: currentTrack,
        upcomingTracks: upNext,
        peaksFor: provider.waveformPeaksFor,
        waveformFor: provider.waveformFor,
        trimRangeFor: provider.trimRangeFor,
        clipFor: provider.timelineClipFor,
        timelineModel: playback.timelineModel,
        pitchFallbackClipIds: playback.snapshot.pitchFallbackClipIds,
        clipTempoStates: playback.snapshot.clipTempoStates,
        playheadPositionMs: playback.timelinePositionMs,
        positionMsStream: playback.timelinePositionMsStream,
        onScrubStart: playback.beginTimelineScrub,
        onScrubUpdate: playback.updateTimelineScrub,
        onScrubEnd: playback.endTimelineScrub,
        onTimelineStartChanged: provider.setTimelineStartMs,
        onTrimStartChanged: provider.setStartOffsetMs,
        onTrimEndChanged: provider.setEndOffsetMs,
        onMoveEarlier: (track) =>
            _moveTimelineTrack(provider, upNext, currentIndex, track, -1),
        onMoveLater: (track) =>
            _moveTimelineTrack(provider, upNext, currentIndex, track, 1),
        onEditAnalysis: (track, {initialFirstDownbeatMs}) =>
            _showAnalysisCorrectionSheet(
          context,
          provider,
          track,
          initialFirstDownbeatMs: initialFirstDownbeatMs,
        ),
      ),
    );
  }

  Widget _buildListView(BuildContext context, QueueProvider provider) {
    final currentIndex = provider.queue.currentIndex;
    final tracks = provider.queue.tracks;
    final hasActiveTrack =
        currentIndex >= 0 && currentIndex < provider.queue.tracks.length;

    return CustomScrollView(
      key: const PageStorageKey('queue_list_view'),
      slivers: [
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, absoluteIndex) {
            final track = tracks[absoluteIndex];
            final isCurrent = hasActiveTrack && absoluteIndex == currentIndex;
            final canEdit = !hasActiveTrack || absoluteIndex > currentIndex;
            final relativeIndex = hasActiveTrack
                ? absoluteIndex - currentIndex - 1
                : absoluteIndex;
            final movableCount = hasActiveTrack
                ? tracks.length - currentIndex - 1
                : tracks.length;

            return _buildSwipeToRemoveQueueItem(
              context: context,
              key: ValueKey('remove_queue_${track.id}'),
              enabled: canEdit,
              label: track.title,
              onRemove: () => provider.removeFromQueue(absoluteIndex),
              child: QueueItem(
                key: ValueKey(
                  isCurrent ? 'queue_current_${track.id}' : track.id,
                ),
                track: track,
                isPlaying: isCurrent,
                reorderHandle: canEdit
                    ? _buildReorderHandle(
                        track,
                        relativeIndex,
                        onDragReorder: (dragDeltaY) {
                          final relativeNewIndex = queueListDragTargetIndex(
                            relativeIndex: relativeIndex,
                            itemCount: movableCount,
                            dragDeltaY: dragDeltaY,
                          );
                          if (relativeNewIndex == relativeIndex) return;
                          final (
                            absoluteOldIndex,
                            absoluteNewIndex,
                          ) = queueListReorderIndices(
                            relativeOldIndex: relativeIndex,
                            relativeNewIndex: relativeNewIndex,
                            currentIndex: currentIndex,
                            hasActiveTrack: hasActiveTrack,
                          );
                          provider.reorderQueue(
                            absoluteOldIndex,
                            absoluteNewIndex,
                          );
                        },
                      )
                    : null,
                showTrimControls: canEdit,
                trimRange: canEdit ? provider.trimRangeFor(track) : null,
                waveformPeaks:
                    canEdit ? provider.waveformPeaksFor(track) : const [],
                onTrimStartChanged: canEdit
                    ? (ms) => provider.setStartOffsetMs(track, ms)
                    : null,
                onTrimEndChanged:
                    canEdit ? (ms) => provider.setEndOffsetMs(track, ms) : null,
                onPlay: track.queueStatus == TrackQueueStatus.playable &&
                        track.canPlay
                    ? () => _playFromQueue(context, provider, track)
                    : null,
                onRetry:
                    track.canRetry ? () => provider.retryTrack(track) : null,
                onRemove: canEdit
                    ? () => provider.removeFromQueue(absoluteIndex)
                    : null,
                onEditAnalysis: _canEditAnalysis(track)
                    ? () => _showAnalysisCorrectionSheet(
                          context,
                          provider,
                          track,
                        )
                    : null,
              ),
            );
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  void _moveTimelineTrack(
    QueueProvider provider,
    List<Track> upNext,
    int currentIndex,
    Track track,
    int delta,
  ) {
    final relativeIndex = upNext.indexWhere(
      (candidate) => candidate.id == track.id,
    );
    if (relativeIndex < 0) return;

    final relativeNewIndex = (relativeIndex + delta).clamp(
      0,
      upNext.length - 1,
    );
    if (relativeNewIndex == relativeIndex) return;

    final (oldIndex, newIndex) = queueListReorderIndices(
      relativeOldIndex: relativeIndex,
      relativeNewIndex: relativeNewIndex,
      currentIndex: currentIndex,
      hasActiveTrack: true,
    );
    provider.reorderQueue(oldIndex, newIndex);
  }

  Future<void> _playFromQueue(
    BuildContext context,
    QueueProvider provider,
    Track selectedTrack,
  ) async {
    final playback = context.read<PlaybackState>();
    final playableTracks = provider.queue.tracks
        .where(
          (track) =>
              track.queueStatus == TrackQueueStatus.playable && track.canPlay,
        )
        .toList(growable: false);
    final startIndex = playableTracks.indexWhere(
      (track) => track.id == selectedTrack.id,
    );
    if (startIndex < 0) return;

    try {
      await playback.playQueue(
        playableTracks.map((track) => track.toPlaybackJson()).toList(),
        startIndex: startIndex,
      );
    } catch (_) {
      if (!mounted) return;
      final message = playback.playbackError ?? 'Playback failed to start.';
      ScaffoldMessenger.of(
        this.context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// Left-edge vertical grip. Only this widget starts a reorder drag, keeping
  /// reorder distinct from the waveform trim surface.
  Widget _buildReorderHandle(
    Track track,
    int _, {
    required ValueChanged<double> onDragReorder,
  }) {
    return Semantics(
      key: ValueKey('reorder_handle_${track.id}'),
      container: true,
      explicitChildNodes: true,
      label: 'Reorder ${track.title}',
      hint: 'Drag vertically to move this queued track',
      child: _QueueReorderHandle(onDragReorder: onDragReorder),
    );
  }

  Widget _buildSwipeToRemoveQueueItem({
    required BuildContext context,
    required Key key,
    required Widget child,
    required String label,
    required Future<void> Function() onRemove,
    required bool enabled,
  }) {
    if (!enabled) return child;

    return Dismissible(
      key: key,
      direction: DismissDirection.endToStart,
      background: const SizedBox.shrink(),
      secondaryBackground: _buildSwipeDeleteBackground(context, label),
      confirmDismiss: (_) async {
        await onRemove();
        return false;
      },
      child: child,
    );
  }

  Widget _buildSwipeDeleteBackground(BuildContext context, String label) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Remove $label from queue',
      child: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        color: colorScheme.errorContainer,
        child: Icon(Icons.delete_outline, color: colorScheme.onErrorContainer),
      ),
    );
  }

  void _handleMenuAction(BuildContext context, String action) {
    switch (action) {
      case 'clear':
        _showClearQueueDialog(context);
        break;
    }
  }

  bool _canEditAnalysis(Track track) {
    return _analysisTrackId(track) != null;
  }

  String? _analysisTrackId(Track track) {
    for (final candidate in [track.playbackTrackId, track.id]) {
      final parsed = int.tryParse(candidate ?? '');
      if (parsed != null && parsed > 0) return parsed.toString();
    }
    return null;
  }

  Future<void> _showAnalysisCorrectionSheet(
    BuildContext context,
    QueueProvider provider,
    Track track, {
    int? initialFirstDownbeatMs,
  }) async {
    if (!_canEditAnalysis(track)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No analysis target for "${track.title}"')),
      );
      return;
    }

    final corrected = await showAnalysisCorrectionSheet(
      context: context,
      track: provider.trackWithAnalysis(track),
      initialFirstDownbeatMs: initialFirstDownbeatMs,
    );
    if (corrected == null || !context.mounted) return;

    try {
      final analysis = await provider.updateAnalysisOverrides(track, corrected);
      final trackId = _analysisTrackId(track);
      if (trackId != null && context.mounted) {
        await context.read<PlaybackState>().refreshTrackAnalysis(
              trackId,
              analysis,
            );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save analysis for "${track.title}"')),
      );
    }
  }

  void _showClearQueueDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear queue?'),
        content: const Text('This will remove all songs from your queue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<QueueProvider>().clearQueue();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

String _formatQueueRuntime(int ms) {
  final totalSeconds = (ms / 1000).round();
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _QueueReorderHandle extends StatefulWidget {
  final ValueChanged<double> onDragReorder;

  const _QueueReorderHandle({required this.onDragReorder});

  @override
  State<_QueueReorderHandle> createState() => _QueueReorderHandleState();
}

class _QueueReorderHandleState extends State<_QueueReorderHandle> {
  double _dragDeltaY = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dragDeltaY = 0,
      onVerticalDragUpdate: (details) {
        _dragDeltaY += details.delta.dy;
      },
      onVerticalDragEnd: (_) {
        widget.onDragReorder(_dragDeltaY);
        _dragDeltaY = 0;
      },
      onVerticalDragCancel: () => _dragDeltaY = 0,
      child: SizedBox(
        width: 44,
        height: _queueReorderItemExtentPx,
        child: Center(
          child: Icon(Icons.drag_indicator, color: Colors.grey[500]),
        ),
      ),
    );
  }
}
