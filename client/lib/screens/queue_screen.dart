import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:provider/provider.dart';
import '../core/audio/playback_state.dart';
import '../core/audio/playback_context.dart';
import '../core/audio/playback_session.dart';
import '../core/engine/tempo_automation.dart';
import '../core/engine/timeline_model.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../models/trim_range.dart';
import '../providers/queue_provider.dart';
import '../shared/widgets/track_tile.dart';
import '../widgets/queue_item.dart';
import '../shared/widgets/soundq_status_chip.dart';
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

class _PlaybackViewState {
  const _PlaybackViewState({
    required this.playback,
    required this.queue,
    required this.cues,
    required this.currentIndex,
    required this.playbackContext,
    required this.timelineModel,
    required this.transitionSnapMode,
    required this.pitchFallbackClipIds,
    required this.timelinePositionMs,
  });

  factory _PlaybackViewState.read(PlaybackState playback) {
    final snapshot = playback.snapshot;
    return _PlaybackViewState(
      playback: playback,
      queue: playback.queue,
      cues: snapshot.cues,
      currentIndex: playback.currentIndex,
      playbackContext: playback.playbackContext,
      timelineModel: playback.timelineModel,
      transitionSnapMode: playback.transitionSnapMode,
      pitchFallbackClipIds: Set<String>.unmodifiable(
        snapshot.pitchFallbackClipIds,
      ),
      timelinePositionMs: playback.timelinePositionMs,
    );
  }

  final PlaybackState playback;
  final List<audio_service.MediaItem> queue;
  final List<PlaybackCue> cues;
  final int? currentIndex;
  final PlaybackContext? playbackContext;
  final TimelineModel timelineModel;
  final BeatSnapMode transitionSnapMode;
  final Set<String> pitchFallbackClipIds;

  // The timeline stream owns subsequent clock updates. This value seeds a
  // newly built timeline and intentionally does not participate in equality.
  final int timelinePositionMs;

  bool hasSameStructure(_PlaybackViewState other) {
    return identical(playback, other.playback) &&
        identical(queue, other.queue) &&
        identical(cues, other.cues) &&
        currentIndex == other.currentIndex &&
        playbackContext == other.playbackContext &&
        identical(timelineModel, other.timelineModel) &&
        transitionSnapMode == other.transitionSnapMode &&
        setEquals(pitchFallbackClipIds, other.pitchFallbackClipIds);
  }
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  _QueueViewMode _viewMode = _QueueViewMode.list;
  final Set<String> _analysisRefreshesInFlight = <String>{};
  _PlaybackTimelineTracks? _playbackTimelineTracksCache;
  QueueProvider? _hydrationProvider;
  Object? _hydrationQueueIdentity;
  int? _hydrationCurrentIndex;
  bool? _hydrationUsesPlaybackQueue;
  Set<String> _visibleHydrationTrackKeys = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<QueueProvider>().loadQueue();
    });
  }

  @override
  void dispose() {
    _hydrationProvider?.clearAnalysisHydrationInterest();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Consumer<QueueProvider>(
          builder: (context, provider, _) =>
              Selector<PlaybackState, _PlaybackViewState>(
            selector: (_, playback) => _PlaybackViewState.read(playback),
            shouldRebuild: (previous, next) => !previous.hasSameStructure(next),
            builder: (context, playbackView, _) {
              _adoptHydrationProvider(provider);
              if (_viewMode == _QueueViewMode.list) {
                _clearAnalysisHydration(provider);
              }
              if (playbackView.queue.isNotEmpty) {
                return _buildPlaybackQueueView(
                  context,
                  provider,
                  playbackView,
                );
              }

              if (provider.isLoading) {
                _clearAnalysisHydration(provider);
                return const SoundQSurfaceState(
                  type: SoundQSurfaceStateType.loading,
                  title: 'Loading queue',
                );
              }

              if (provider.error != null) {
                _clearAnalysisHydration(provider);
                return SoundQSurfaceState(
                  type: SoundQSurfaceStateType.error,
                  title: 'Error loading queue',
                  message: provider.error!,
                  action: ElevatedButton(
                    onPressed: () => provider.loadQueue(),
                    child: const Text('Retry'),
                  ),
                );
              }

              if (provider.isEmpty) {
                _clearAnalysisHydration(provider);
                return const SoundQSurfaceState(
                  type: SoundQSurfaceStateType.empty,
                  title: 'Your queue is empty',
                  message: 'Add songs to start playing',
                );
              }

              return Column(
                children: [
                  _buildQueueHeader(context, provider),
                  Expanded(
                    child: _viewMode == _QueueViewMode.list
                        ? _buildListView(context, provider)
                        : _buildTimelineView(
                            context,
                            provider,
                            playbackView,
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPlaybackQueueView(
    BuildContext context,
    QueueProvider provider,
    _PlaybackViewState playbackView,
  ) {
    final playback = playbackView.playback;
    final entries = listeningQueueEntries(
      queue: playbackView.queue,
      currentIndex: playbackView.currentIndex,
    );

    return Column(
      children: [
        _buildPlaybackQueueHeader(context, playbackView),
        Expanded(
          child: _viewMode == _QueueViewMode.list
              ? _buildPlaybackQueueList(playback, entries)
              : _buildPlaybackTimelineView(
                  context,
                  provider,
                  playbackView,
                ),
        ),
      ],
    );
  }

  Widget _buildPlaybackQueueHeader(
    BuildContext context,
    _PlaybackViewState playbackView,
  ) {
    final queue = playbackView.queue;
    final contextLabel = _playbackContextLabel(playbackView.playbackContext);
    final currentNumber = playbackView.currentIndex == null
        ? null
        : playbackView.currentIndex!.clamp(0, queue.length - 1).toInt() + 1;
    final stackedHeader = _usesStackedQueueHeader(context);
    final title = Text(
      'Playback Queue',
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stackedHeader) ...[
            title,
            const SizedBox(height: 8),
            _buildViewSwitch(context, expanded: true),
          ] else
            Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 8),
                _buildViewSwitch(context),
              ],
            ),
          SizedBox(height: stackedHeader ? 8 : 4),
          Selector<PlaybackState, Duration>(
            selector: (_, playback) => playback.position,
            builder: (context, position, _) {
              final remainingMs = listeningQueueRemainingMs(
                queue: queue,
                currentIndex: playbackView.currentIndex,
                currentPosition: position,
              );
              return Text(
                [
                  if (contextLabel != null) contextLabel,
                  if (currentNumber != null)
                    '$currentNumber of ${queue.length}',
                  '${_formatQueueRuntime(remainingMs)} remaining',
                ].join(' • '),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              );
            },
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
                analysis: trackAnalysisFromTrackJson(
                  Map<String, dynamic>.from(item.extras ?? const {}),
                ),
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
    _PlaybackViewState playbackView,
  ) {
    final playback = playbackView.playback;
    final queue = playbackView.queue;
    if (queue.isEmpty) {
      _clearAnalysisHydration(provider);
      return const SizedBox.shrink();
    }
    final currentIndex =
        playbackView.currentIndex?.clamp(0, queue.length - 1).toInt();
    if (currentIndex == null) {
      _clearAnalysisHydration(provider);
      return const Center(child: Text('Start playback to edit the timeline'));
    }

    final timelineTracks = _playbackTimelineTracks(
      provider: provider,
      playback: playback,
      timelineModel: playbackView.timelineModel,
      queue: queue,
      cues: playbackView.cues,
      currentIndex: currentIndex,
    );
    if (timelineTracks == null) {
      return const SoundQSurfaceState(
        type: SoundQSurfaceStateType.loading,
        title: 'Loading playback queue',
      );
    }
    final current = timelineTracks.current;
    final previous = timelineTracks.previous;
    final upcoming = timelineTracks.upcoming;

    return StackedWaveformTimeline(
      key: const ValueKey('queue_surface'),
      previousTrack: previous,
      currentTrack: current,
      upcomingTracks: upcoming,
      peaksFor: provider.waveformPeaksFor,
      waveformFor: provider.waveformFor,
      trimRangeFor: (track) {
        final queueIndex = _playbackQueueIndexForQueueItemId(
          playback,
          track.queueItemId,
        );
        return queueIndex == null
            ? TrimRange.full(track.durationMs)
            : playback.trimRangeForQueueIndex(queueIndex);
      },
      clipFor: (track, fallback) {
        final queueIndex = _playbackQueueIndexForQueueItemId(
          playback,
          track.queueItemId,
        );
        return queueIndex == null
            ? fallback
            : playback.timelineClipForQueueIndex(queueIndex) ?? fallback;
      },
      timelineModel: playbackView.timelineModel,
      pitchFallbackClipIds: playbackView.pitchFallbackClipIds,
      transitionSnapMode: playbackView.transitionSnapMode,
      playheadPositionMs: playbackView.timelinePositionMs,
      positionMsStream: playback.timelinePositionMsStream,
      onScrubStart: playback.beginTimelineScrub,
      onScrubUpdate: playback.updateTimelineScrub,
      onScrubEnd: playback.endTimelineScrub,
      onTimelineStartChanged: (track, ms) {
        return _pauseThenEditPlaybackQueueItem(
          playback,
          track.queueItemId,
          (queueItemId) => playback.setQueueTimelineStartMsByQueueItemId(
            queueItemId,
            ms,
            snapToDownbeat: true,
          ),
        );
      },
      onTrimStartChanged: (track, ms) {
        return _pauseThenEditPlaybackQueueItem(
          playback,
          track.queueItemId,
          (queueItemId) => playback.setQueueTrimStartMsByQueueItemId(
            queueItemId,
            ms,
          ),
        );
      },
      onTrimEndChanged: (track, ms) {
        return _pauseThenEditPlaybackQueueItem(
          playback,
          track.queueItemId,
          (queueItemId) => playback.setQueueTrimEndMsByQueueItemId(
            queueItemId,
            ms,
          ),
        );
      },
      onMoveEarlier: (track) => _movePlaybackTimelineTrack(playback, track, -1),
      onMoveLater: (track) => _movePlaybackTimelineTrack(playback, track, 1),
      onPitchModeChanged: (track, pitchMode) {
        return _pauseThenEditPlaybackQueueItem(
          playback,
          track.queueItemId,
          (queueItemId) => playback.setQueuePitchModeByQueueItemId(
            queueItemId,
            pitchMode,
          ),
        );
      },
      onTransitionSnapModeChanged: (mode) {
        _pauseThenEditTimeline(
          playback,
          () => playback.setTransitionSnapMode(mode),
        );
      },
      onEditAnalysis: (track, {initialFirstDownbeatMs}) =>
          _showAnalysisCorrectionSheet(
        context,
        provider,
        track,
        initialFirstDownbeatMs: initialFirstDownbeatMs,
      ),
      onVisibleTracksChanged: (tracks) =>
          _updateVisibleAnalysisHydration(provider, tracks),
    );
  }

  _PlaybackTimelineTracks? _playbackTimelineTracks({
    required QueueProvider provider,
    required PlaybackState playback,
    required TimelineModel timelineModel,
    required List<audio_service.MediaItem> queue,
    required List<PlaybackCue> cues,
    required int currentIndex,
  }) {
    final cached = _playbackTimelineTracksCache;
    if (cached != null &&
        identical(cached.queue, queue) &&
        identical(cached.cues, cues) &&
        cached.currentIndex == currentIndex &&
        cached.analysisRevision == provider.analysisRevision &&
        identical(cached.timelineModel, timelineModel)) {
      return cached;
    }

    final cuesByQueueIndex = _playbackCuesByQueueIndex(queue, cues);
    final currentCue = cuesByQueueIndex[currentIndex];
    if (currentCue == null) return null;
    final currentSource = _playbackTrackFor(queue[currentIndex], currentCue);
    final previousCue =
        currentIndex > 0 ? cuesByQueueIndex[currentIndex - 1] : null;
    final previousSource = previousCue == null
        ? null
        : _playbackTrackFor(queue[currentIndex - 1], previousCue);
    final upcomingSources = [
      for (var index = currentIndex + 1; index < queue.length; index++)
        if (cuesByQueueIndex[index] case final cue?)
          _playbackTrackFor(queue[index], cue),
    ];
    final hydrationSources = [
      if (previousSource != null) previousSource,
      currentSource,
      ...upcomingSources,
    ];
    _prepareAnalysisHydration(
      provider: provider,
      queueIdentity: queue,
      currentIndex: currentIndex,
      usesPlaybackQueue: true,
      sources: hydrationSources,
      initialSources: [
        if (previousSource != null) previousSource,
        currentSource,
        ...upcomingSources.take(2),
      ],
    );
    final current = provider.trackWithAnalysis(
      currentSource,
      requestHydration: false,
    );
    final previous = previousSource == null
        ? null
        : provider.trackWithAnalysis(
            previousSource,
            requestHydration: false,
          );
    final upcoming = [
      for (final track in upcomingSources)
        provider.trackWithAnalysis(track, requestHydration: false),
    ];
    final tracks = [if (previous != null) previous, current, ...upcoming];
    _syncPlaybackAnalyses(playback: playback, queue: queue, tracks: tracks);

    final result = _PlaybackTimelineTracks(
      queue: queue,
      cues: cues,
      currentIndex: currentIndex,
      analysisRevision: provider.analysisRevision,
      timelineModel: timelineModel,
      tracks: tracks,
      previous: previous,
      current: current,
      upcoming: upcoming,
    );
    _playbackTimelineTracksCache = result;
    return result;
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

  Map<int, PlaybackCue> _playbackCuesByQueueIndex(
    List<audio_service.MediaItem> queue,
    List<PlaybackCue> cues,
  ) {
    final result = <int, PlaybackCue>{};
    for (final cue in cues) {
      final index = cue.queueIndex;
      if (index < 0 || index >= queue.length || result.containsKey(index)) {
        continue;
      }
      final item = queue[index];
      if (cue.trackId != item.id && cue.mediaItem.id != item.id) continue;
      result[index] = cue;
    }
    return result;
  }

  Track _playbackTrackFor(
    audio_service.MediaItem item,
    PlaybackCue cue,
  ) {
    final duration = item.duration ?? Duration.zero;
    final track = Track(
      id: cue.queueItemId,
      queueItemId: cue.queueItemId,
      playbackTrackId: item.id,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: duration.inSeconds,
      coverUrl: item.artUri?.toString(),
      addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      analysis: trackAnalysisFromTrackJson(
        Map<String, dynamic>.from(item.extras ?? const {}),
      ),
    );
    return track;
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

      final queueIndex = _playbackQueueIndexForQueueItemId(
        playback,
        track.queueItemId,
      );
      if (queueIndex == null) continue;
      if (queueIndex < 0 || queueIndex >= queue.length) continue;
      final nextTempo = _tempoForAnalysis(analysis);
      if (!_mediaItemNeedsAnalysisRefresh(queue[queueIndex], nextTempo) &&
          !_timelineModelNeedsAnalysisRefresh(
            playback.timelineModel,
            track,
            nextTempo,
          )) {
        continue;
      }

      final refreshKey = '${track.queueItemId}:$trackId:${nextTempo.hashCode}';
      if (!_analysisRefreshesInFlight.add(refreshKey)) continue;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _analysisRefreshesInFlight.remove(refreshKey);
          return;
        }
        final latestQueueIndex = _playbackQueueIndexForQueueItemId(
          playback,
          track.queueItemId,
        );
        if (latestQueueIndex == null) {
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

  bool _timelineModelNeedsAnalysisRefresh(
    TimelineModel model,
    Track track,
    ClipTempoMetadata nextTempo,
  ) {
    if (nextTempo.isEmpty || model.clips.isEmpty) return false;

    for (final clip in model.clips) {
      if (_timelineClipMatchesTrack(clip, track)) {
        return clip.tempo != nextTempo;
      }
    }
    return false;
  }

  bool _timelineClipMatchesTrack(MixClip clip, Track track) {
    final clipQueueItemId = clip.queueItemId;
    if (track.queueItemId.isNotEmpty &&
        clipQueueItemId != null &&
        clipQueueItemId.isNotEmpty) {
      return clipQueueItemId == track.queueItemId;
    }

    final playbackTrackId = track.playbackTrackId;
    if (playbackTrackId != null && playbackTrackId.isNotEmpty) {
      return clip.trackId == playbackTrackId;
    }

    final ids = <String>{
      track.id,
      track.queueItemId,
      if (track.sourceCandidateId != null) track.sourceCandidateId!,
      if (track.sourceUrl != null) track.sourceUrl!,
    };
    return ids.contains(clip.trackId) || ids.contains(clip.queueItemId);
  }

  ClipTempoMetadata _tempoForAnalysis(TrackAnalysis analysis) =>
      ClipTempoMetadata.fromAnalysisSummary(
        analysis.summary?.toJson(),
        overrides: analysis.overrides?.toJson(),
      );

  int? _playbackQueueIndexForQueueItemId(
    PlaybackState playback,
    String queueItemId,
  ) {
    if (queueItemId.isEmpty) return null;
    PlaybackCue? match;
    for (final cue in playback.snapshot.cues) {
      if (cue.queueItemId != queueItemId) continue;
      if (match != null) return null;
      match = cue;
    }
    if (match == null) return null;

    final index = match.queueIndex;
    final queue = playback.queue;
    if (index < 0 || index >= queue.length) return null;
    final item = queue[index];
    if (match.trackId != item.id && match.mediaItem.id != item.id) return null;
    return index;
  }

  Future<void> _pauseThenEditPlaybackQueueItem(
    PlaybackState playback,
    String queueItemId,
    Future<void> Function(String queueItemId) edit,
  ) async {
    await playback.pause();
    await edit(queueItemId);
  }

  Future<void> _pauseThenEditTimeline(
    PlaybackState playback,
    Future<void> Function() edit,
  ) async {
    await playback.pause();
    await edit();
  }

  void _movePlaybackTimelineTrack(
    PlaybackState playback,
    Track track,
    int delta,
  ) {
    unawaited(
      _pauseThenEditPlaybackQueueItem(
        playback,
        track.queueItemId,
        (queueItemId) => playback.movePlaybackQueueItemByQueueItemId(
          queueItemId,
          delta,
        ),
      ),
    );
  }

  Widget _buildQueueHeader(BuildContext context, QueueProvider provider) {
    final stackedHeader = _usesStackedQueueHeader(context);
    final status = Selector<PlaybackState, Duration>(
      selector: (_, playback) => playback.position,
      builder: (context, position, _) =>
          _buildQueueStatusPill(context, provider, position),
    );
    final menu = PopupMenuButton<String>(
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
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
      child: stackedHeader
          ? Column(
              children: [
                Row(children: [Expanded(child: status), menu]),
                const SizedBox(height: 8),
                _buildViewSwitch(context, expanded: true),
              ],
            )
          : Row(
              children: [
                Expanded(child: status),
                const SizedBox(width: 8),
                _buildViewSwitch(context),
                menu,
              ],
            ),
    );
  }

  Widget _buildQueueStatusPill(
    BuildContext context,
    QueueProvider provider,
    Duration playbackPosition,
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
            trim.endOffsetMs - playbackPosition.inMilliseconds;
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

  bool _usesStackedQueueHeader(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1) >= 1.3;

  Widget _buildViewSwitch(
    BuildContext context, {
    bool expanded = false,
  }) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final showLabels = textScale < 2.5;
    final showIcons = textScale < 1.3 || !showLabels;
    return SizedBox(
      width: expanded ? double.infinity : 176,
      child: SegmentedButton<_QueueViewMode>(
        key: const ValueKey('queue_view_switch'),
        segments: [
          ButtonSegment(
            value: _QueueViewMode.list,
            icon: showIcons ? const Icon(Icons.format_list_bulleted) : null,
            label: showLabels
                ? const Text('List', maxLines: 1, softWrap: false)
                : null,
            tooltip: 'List view',
          ),
          ButtonSegment(
            value: _QueueViewMode.timeline,
            icon: showIcons ? const Icon(Icons.timeline) : null,
            label: showLabels
                ? const Text('Timeline', maxLines: 1, softWrap: false)
                : null,
            tooltip: 'Timeline view',
          ),
        ],
        selected: {_viewMode},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          final next = selection.single;
          if (next == _QueueViewMode.list) {
            _clearAnalysisHydration(context.read<QueueProvider>());
          }
          setState(() => _viewMode = next);
        },
      ),
    );
  }

  Widget _buildTimelineView(
    BuildContext context,
    QueueProvider provider,
    _PlaybackViewState playbackView,
  ) {
    final currentIndex = provider.queue.currentIndex;
    final sourceTracks = provider.queue.tracks;
    if (currentIndex < 0 || currentIndex >= sourceTracks.length) {
      _clearAnalysisHydration(provider);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.timeline,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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

    final firstRenderedIndex = currentIndex > 0 ? currentIndex - 1 : 0;
    final hydrationSources = sourceTracks.sublist(firstRenderedIndex);
    _prepareAnalysisHydration(
      provider: provider,
      queueIdentity: sourceTracks,
      currentIndex: currentIndex,
      usesPlaybackQueue: false,
      sources: hydrationSources,
      initialSources: hydrationSources.take(4),
    );
    final tracks = hydrationSources
        .map(
          (track) => provider.trackWithAnalysis(
            track,
            requestHydration: false,
          ),
        )
        .toList(growable: false);
    final renderedCurrentIndex = currentIndex - firstRenderedIndex;
    final currentTrack = tracks[renderedCurrentIndex];
    final upNext =
        tracks.skip(renderedCurrentIndex + 1).toList(growable: false);
    final previousTrack =
        renderedCurrentIndex > 0 ? tracks[renderedCurrentIndex - 1] : null;

    final playback = playbackView.playback;
    return StackedWaveformTimeline(
      key: const ValueKey('queue_surface'),
      previousTrack: previousTrack,
      currentTrack: currentTrack,
      upcomingTracks: upNext,
      peaksFor: provider.waveformPeaksFor,
      waveformFor: provider.waveformFor,
      trimRangeFor: provider.trimRangeFor,
      clipFor: provider.timelineClipFor,
      pitchModeFor: provider.pitchModeFor,
      timelineModel: playbackView.timelineModel,
      pitchFallbackClipIds: playbackView.pitchFallbackClipIds,
      playheadPositionMs: playbackView.timelinePositionMs,
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
      onPitchModeChanged: provider.setPitchMode,
      onEditAnalysis: (track, {initialFirstDownbeatMs}) =>
          _showAnalysisCorrectionSheet(
        context,
        provider,
        track,
        initialFirstDownbeatMs: initialFirstDownbeatMs,
      ),
      onVisibleTracksChanged: (tracks) =>
          _updateVisibleAnalysisHydration(provider, tracks),
    );
  }

  void _prepareAnalysisHydration({
    required QueueProvider provider,
    required Object queueIdentity,
    required int currentIndex,
    required bool usesPlaybackQueue,
    required List<Track> sources,
    required Iterable<Track> initialSources,
  }) {
    final contextChanged = !identical(_hydrationQueueIdentity, queueIdentity) ||
        _hydrationCurrentIndex != currentIndex ||
        _hydrationUsesPlaybackQueue != usesPlaybackQueue;
    if (contextChanged) {
      _hydrationQueueIdentity = queueIdentity;
      _hydrationCurrentIndex = currentIndex;
      _hydrationUsesPlaybackQueue = usesPlaybackQueue;
      _visibleHydrationTrackKeys = {
        for (final track in initialSources) _timelineHydrationTrackKey(track),
      };
    }

    var retained = [
      for (final track in sources)
        if (_visibleHydrationTrackKeys.contains(
          _timelineHydrationTrackKey(track),
        ))
          track,
    ];
    if (retained.isEmpty && sources.isNotEmpty) {
      retained = initialSources.toList(growable: false);
      _visibleHydrationTrackKeys = {
        for (final track in retained) _timelineHydrationTrackKey(track),
      };
    }
    provider.setAnalysisHydrationInterest(retained);
  }

  void _updateVisibleAnalysisHydration(
    QueueProvider provider,
    List<Track> tracks,
  ) {
    final next = {
      for (final track in tracks) _timelineHydrationTrackKey(track),
    };
    if (_sameHydrationKeys(next, _visibleHydrationTrackKeys)) return;
    _visibleHydrationTrackKeys = next;
    provider.setAnalysisHydrationInterest(tracks);
  }

  bool _sameHydrationKeys(Set<String> first, Set<String> second) =>
      first.length == second.length && first.every(second.contains);

  String _timelineHydrationTrackKey(Track track) =>
      '${track.queueItemId}|${track.id}|${track.playbackTrackId ?? ''}';

  void _clearAnalysisHydration(QueueProvider provider) {
    _hydrationQueueIdentity = null;
    _hydrationCurrentIndex = null;
    _hydrationUsesPlaybackQueue = null;
    _visibleHydrationTrackKeys = <String>{};
    _playbackTimelineTracksCache = null;
    provider.clearAnalysisHydrationInterest();
  }

  void _adoptHydrationProvider(QueueProvider provider) {
    if (identical(_hydrationProvider, provider)) return;
    _hydrationProvider?.clearAnalysisHydrationInterest();
    _hydrationProvider = provider;
    _hydrationQueueIdentity = null;
    _hydrationCurrentIndex = null;
    _hydrationUsesPlaybackQueue = null;
    _visibleHydrationTrackKeys = <String>{};
    _playbackTimelineTracksCache = null;
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
      track: provider.trackWithAnalysis(track, requestHydration: false),
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

class _PlaybackTimelineTracks {
  final List<audio_service.MediaItem> queue;
  final List<PlaybackCue> cues;
  final int currentIndex;
  final int analysisRevision;
  final TimelineModel timelineModel;
  final List<Track> tracks;
  final Track? previous;
  final Track current;
  final List<Track> upcoming;

  const _PlaybackTimelineTracks({
    required this.queue,
    required this.cues,
    required this.currentIndex,
    required this.analysisRevision,
    required this.timelineModel,
    required this.tracks,
    required this.previous,
    required this.current,
    required this.upcoming,
  });
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
