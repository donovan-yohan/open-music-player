import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, setEquals;
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show ProviderContainer, ProviderScope;
import 'package:provider/provider.dart';
import '../core/api/api_client.dart';
import '../core/audio/audition_output_route_monitor.dart';
import '../core/audio/playback_state.dart';
import '../core/audio/playback_context.dart';
import '../core/audio/playback_session.dart';
import '../core/audio/queue_persistence.dart';
import '../core/commands/app_command.dart';
import '../core/commands/command_registry.dart';
import '../core/commands/command_widgets.dart';
import '../app/theme.dart';
import '../core/engine/click_audition_projection.dart';
import '../core/engine/click_auditioner.dart';
import '../core/engine/tempo_automation.dart';
import '../core/engine/timeline_model.dart';
import '../core/models/settings_model.dart';
import '../core/providers/settings_provider.dart';
import '../core/services/playlist_service.dart';
import '../features/playlists/playlist_edit_dialog.dart';
import '../models/track.dart';
import '../models/track_analysis.dart';
import '../models/trim_range.dart';
import '../providers/queue_provider.dart';
import '../shared/models/playlist.dart';
import '../shared/models/track.dart' show trackArtworkKindFromPayload;
import '../shared/widgets/like_button.dart';
import '../shared/widgets/playlist_picker_sheet.dart';
import '../shared/widgets/track_tile.dart';
import '../widgets/queue_item.dart';
import '../shared/widgets/soundq_status_chip.dart';
import '../widgets/analysis_correction_sheet.dart';
import '../widgets/stacked_waveform_timeline.dart';

enum _QueueViewMode { list, timeline }

typedef AuditionOutputRouteMonitorFactory = Future<AuditionOutputRouteMonitor>
    Function();

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
QueueTrack playbackTrackForMediaItem(
  audio_service.MediaItem item, {
  required String queueItemId,
}) {
  final duration = item.duration ?? Duration.zero;
  final extras = item.extras;
  final artworkKind = trackArtworkKindFromPayload(extras);
  return QueueTrack(
    id: queueItemId,
    queueItemId: queueItemId,
    playbackTrackId: item.id,
    title: item.title,
    artist: item.artist,
    album: item.album,
    duration: duration.inSeconds,
    artworkUrl: item.artUri?.toString(),
    artworkKind: artworkKind,
    addedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    analysis: trackAnalysisFromTrackJson(
      Map<String, dynamic>.from(item.extras ?? const {}),
    ),
  );
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

class _CanonicalPlaybackQueueOccurrence {
  const _CanonicalPlaybackQueueOccurrence({
    required this.queueItemId,
  });

  final String queueItemId;
}

/// Backend track ids for [queue], in the order the user sees (and hears) them.
///
/// Local-only entries have no numeric backend id and cannot join a server
/// playlist, so they are dropped rather than failing the whole save. Repeats
/// are kept: the backend's add-tracks report decides what is added vs skipped.
List<int> saveableQueueTrackIds(List<audio_service.MediaItem> queue) {
  final trackIds = <int>[];
  for (final item in queue) {
    final trackId = int.tryParse(item.id);
    if (trackId != null && trackId > 0) trackIds.add(trackId);
  }
  return trackIds;
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({
    super.key,
    this.showImportJobs = false,
    this.auditionOutputRouteMonitorFactory,
    this.playlistService,
  });

  /// The playback queue and backend import jobs are independent domains.
  /// `/queue` stays focused on listening, while `/queue/imports` explicitly
  /// opts into the backend job surface.
  final bool showImportJobs;
  final AuditionOutputRouteMonitorFactory? auditionOutputRouteMonitorFactory;

  /// Injected in tests; otherwise built from the provided [ApiClient].
  final PlaylistService? playlistService;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  static const int _maxPlaybackBeatPositions = 128;
  static const int _maxPlaybackDownbeatPositions = 64;

  _QueueViewMode _viewMode = _QueueViewMode.list;
  final Set<String> _analysisRefreshesInFlight = <String>{};
  final Map<
      String,
      ({
        String queueItemId,
        String trackId,
        TrackAnalysis analysis,
      })> _pendingAnalysisRefreshes = {};
  bool _analysisRefreshScheduled = false;
  _PlaybackTimelineTracks? _playbackTimelineTracksCache;
  QueueProvider? _hydrationProvider;
  Object? _hydrationQueueIdentity;
  int? _hydrationCurrentIndex;
  bool? _hydrationUsesPlaybackQueue;
  Map<String, QueueTrack> _hydrationSourcesByKey = <String, QueueTrack>{};
  List<String> _pinnedHydrationTrackKeys = <String>[];
  List<String> _visibleHydrationTrackKeys = <String>[];
  final ScrollController _playbackQueueScrollController = ScrollController();
  final Map<String, GlobalKey> _playbackQueueOccurrenceKeys = {};
  bool _hasObservedPlaybackQueueCurrent = false;
  bool _isPlaybackQueueUserInteracting = false;
  bool _isReorderingPlaybackQueue = false;
  int _playbackQueueFollowGeneration = 0;
  String? _lastObservedPlaybackQueueItemId;
  String? _pendingPlaybackQueueFollowId;
  String? _suppressedPlaybackQueueFollowId;

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
    _playbackQueueScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queue = Scaffold(
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
              if (!widget.showImportJobs) {
                if (playbackView.queue.isEmpty) {
                  _clearAnalysisHydration(provider);
                  return const SoundQSurfaceState(
                    type: SoundQSurfaceStateType.empty,
                    title: 'Your playback queue is empty',
                    message: 'Play a song to start listening',
                  );
                }
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
    if (MediaQuery.sizeOf(context).width >= 960) return queue;
    return Theme(data: AppTheme.darkTheme, child: queue);
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
    _observePlaybackQueueCurrent(
      playback,
      _canonicalPlaybackQueueOccurrence(
        queue: playbackView.queue,
        cues: playbackView.cues,
        currentIndex: playbackView.currentIndex,
      ),
      isListVisible: _viewMode == _QueueViewMode.list,
    );

    return Column(
      children: [
        _buildPlaybackQueueHeader(context, playbackView),
        Expanded(
          child: _viewMode == _QueueViewMode.list
              ? _buildPlaybackQueueList(playback, entries, playbackView.cues)
              : _buildPlaybackTimelineView(context, provider, playbackView),
        ),
      ],
    );
  }

  Widget _buildPlaybackQueueHeader(
    BuildContext context,
    _PlaybackViewState playbackView,
  ) {
    final colors = Theme.of(context).colorScheme;
    final queue = playbackView.queue;
    final contextLabel = _playbackContextLabel(playbackView.playbackContext);
    final currentNumber = playbackView.currentIndex == null
        ? null
        : playbackView.currentIndex!.clamp(0, queue.length - 1).toInt() + 1;
    final stackedHeader = _usesStackedQueueHeader(context);
    final usesMobileHeader = MediaQuery.sizeOf(context).width < 960;
    final headerForeground = usesMobileHeader ? colors.onPrimary : null;
    final title = Text(
      'Playback Queue',
      style: Theme.of(
        context,
      ).textTheme.headlineSmall?.copyWith(
            color: headerForeground,
            fontWeight: FontWeight.w700,
          ),
    );
    // Sized to the view switch it sits beside so adding this action does not
    // grow the header and push the queue list down.
    final menu = PopupMenuButton<String>(
      key: const ValueKey('playback_queue_menu'),
      tooltip: 'Queue actions',
      iconColor: headerForeground,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelected: (value) => _handleMenuAction(context, value),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'save_playlist',
          child: ListTile(
            key: ValueKey('queue_save_as_playlist_action'),
            leading: Icon(Icons.playlist_add),
            title: Text('Save queue as playlist'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );

    return Container(
      key: const ValueKey('playback_queue_header'),
      color: usesMobileHeader ? AppTheme.orange : Colors.transparent,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stackedHeader) ...[
            title,
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _buildViewSwitch(context, expanded: true)),
                menu,
              ],
            ),
          ] else
            Row(
              children: [
                Expanded(child: title),
                const SizedBox(width: 8),
                _buildViewSwitch(context),
                menu,
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
                      color: headerForeground ?? colors.onSurfaceVariant,
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
    List<PlaybackCue> cues,
  ) {
    final stableQueueItemIds = <String>{};
    for (final entry in entries) {
      final queueItemId = _queueItemIdForPlaybackEntry(cues, entry).trim();
      if (_isStablePlaybackQueueItemId(queueItemId)) {
        stableQueueItemIds.add(queueItemId);
      }
    }
    _playbackQueueOccurrenceKeys.removeWhere(
      (queueItemId, _) => !stableQueueItemIds.contains(queueItemId),
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _handlePlaybackQueueScrollNotification,
      child: ReorderableListView.builder(
        key: const PageStorageKey('playback_queue_list_view'),
        scrollController: _playbackQueueScrollController,
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: entries.length,
        onReorderStart: (_) => _beginPlaybackQueueReorder(),
        onReorderEnd: (_) => _endPlaybackQueueReorder(),
        onReorderItem: (oldIndex, newIndex) {
          if (oldIndex == newIndex) return;
          unawaited(_reorderPlaybackQueue(playback, oldIndex, newIndex));
        },
        itemBuilder: (context, index) {
          final entry = entries[index];
          final item = entry.item;
          final queueItemId = _queueItemIdForPlaybackEntry(cues, entry);
          final stableQueueItemId = queueItemId.trim();
          final track = playbackTrackForMediaItem(
            item,
            queueItemId: queueItemId,
          );
          final registry = context.read<CommandRegistry>();
          final commandContext = CommandContext(
            playbackState: playback,
            track: mediaItemToPlaybackJson(item),
            trackId: int.tryParse(item.id),
            queueItemId:
                queueItemId.startsWith('unresolved_') ? null : queueItemId,
            playNow: () => _skipToPlaybackIndex(
              playback,
              entry,
              queueItemId: stableQueueItemId,
            ),
          );
          final row = _buildSwipeToRemoveQueueItem(
            context: context,
            key: ValueKey('remove_playback_queue_$queueItemId'),
            enabled: registry[CommandId.removeFromQueue]
                .availabilityFor(commandContext)
                .enabled,
            label: item.title,
            onRemove: () => _removePlaybackQueueEntry(playback, entry),
            onSecondaryTapUp: (details) => showRegistryCommandMenu(
              context: context,
              registry: registry,
              commandContext: commandContext,
              position: details.globalPosition,
            ),
            child: TrackTile(
              key: ValueKey('playback_queue_$queueItemId'),
              title: item.title,
              artist: item.artist,
              album: item.album,
              duration: _formatQueueRuntime(item.duration?.inMilliseconds ?? 0),
              coverArtUrl: track.artworkUrl,
              artworkKind: track.artworkKind,
              analysis: track.analysis,
              action: switch (int.tryParse(track.playbackTrackId ?? '')) {
                // Source-backed queue items have no backend track row yet, so
                // there is nothing to like until the download lands.
                null => null,
                final playbackId => LikeToggleButton.forId(
                    trackId: playbackId,
                    buttonKey: ValueKey('queue_like_$queueItemId'),
                  ),
              },
              leading: _buildReorderHandle(
                queueItemId: queueItemId,
                title: item.title,
                index: index,
              ),
              isCurrent: entry.isCurrent,
              onTap: entry.isCurrent
                  ? null
                  : () => _skipToPlaybackIndex(
                        playback,
                        entry,
                        queueItemId: stableQueueItemId,
                      ),
            ),
          );
          if (!_isStablePlaybackQueueItemId(stableQueueItemId)) return row;
          return KeyedSubtree(
            key: _playbackQueueOccurrenceKeys.putIfAbsent(
              stableQueueItemId,
              () => GlobalKey(debugLabel: 'playback_queue_$stableQueueItemId'),
            ),
            child: row,
          );
        },
      ),
    );
  }

  String _queueItemIdForPlaybackEntry(
    List<PlaybackCue> cues,
    ListeningQueueEntry entry,
  ) {
    for (final cue in cues) {
      if (cue.queueIndex == entry.index && cue.mediaItem.id == entry.item.id) {
        return cue.queueItemId;
      }
    }
    // A queue snapshot normally carries a cue for every item. Keep the list
    // renderable during a transient snapshot update while avoiding track-ID
    // keys, which are not unique for duplicate queued occurrences.
    return 'unresolved_${entry.index}_${entry.item.id}';
  }

  bool _isStablePlaybackQueueItemId(String queueItemId) =>
      queueItemId.isNotEmpty && !queueItemId.startsWith('unresolved_');

  _CanonicalPlaybackQueueOccurrence? _canonicalPlaybackQueueOccurrence({
    required List<audio_service.MediaItem> queue,
    required List<PlaybackCue> cues,
    required int? currentIndex,
  }) {
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= queue.length) {
      return null;
    }
    final item = queue[currentIndex];
    PlaybackCue? currentCue;
    for (final cue in cues) {
      if (cue.queueIndex != currentIndex ||
          !_isStablePlaybackQueueItemId(cue.queueItemId.trim()) ||
          (cue.trackId != item.id && cue.mediaItem.id != item.id)) {
        continue;
      }
      if (currentCue != null) return null;
      currentCue = cue;
    }
    if (currentCue == null) return null;
    final queueItemId = currentCue.queueItemId.trim();
    if (cues.where((cue) => cue.queueItemId.trim() == queueItemId).length !=
        1) {
      return null;
    }
    return _CanonicalPlaybackQueueOccurrence(queueItemId: queueItemId);
  }

  void _observePlaybackQueueCurrent(
    PlaybackState playback,
    _CanonicalPlaybackQueueOccurrence? occurrence, {
    required bool isListVisible,
  }) {
    if (occurrence == null) return;
    final queueItemId = occurrence.queueItemId;
    if (!_hasObservedPlaybackQueueCurrent) {
      _hasObservedPlaybackQueueCurrent = true;
      _lastObservedPlaybackQueueItemId = queueItemId;
      return;
    }
    if (_lastObservedPlaybackQueueItemId == queueItemId) return;
    _lastObservedPlaybackQueueItemId = queueItemId;
    if (_suppressedPlaybackQueueFollowId != null) {
      final isLocalPlayNow = _suppressedPlaybackQueueFollowId == queueItemId;
      _suppressedPlaybackQueueFollowId = null;
      if (isLocalPlayNow) return;
    }
    if (!isListVisible ||
        _isPlaybackQueueUserInteracting ||
        _isReorderingPlaybackQueue) {
      return;
    }
    _schedulePlaybackQueueFollow(playback, queueItemId);
  }

  void _schedulePlaybackQueueFollow(
    PlaybackState playback,
    String queueItemId,
  ) {
    if (_pendingPlaybackQueueFollowId == queueItemId) return;
    final generation = ++_playbackQueueFollowGeneration;
    _pendingPlaybackQueueFollowId = queueItemId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _playbackQueueFollowGeneration ||
          _pendingPlaybackQueueFollowId != queueItemId) {
        return;
      }
      _pendingPlaybackQueueFollowId = null;
      if (_isPlaybackQueueUserInteracting ||
          _isReorderingPlaybackQueue ||
          !_playbackQueueScrollController.hasClients) {
        return;
      }
      final current = _canonicalPlaybackQueueOccurrence(
        queue: playback.queue,
        cues: playback.snapshot.cues,
        currentIndex: playback.currentIndex,
      );
      if (current?.queueItemId != queueItemId) return;
      final targetRenderObject = _playbackQueueOccurrenceKeys[queueItemId]
          ?.currentContext
          ?.findRenderObject();
      if (targetRenderObject == null || !targetRenderObject.attached) return;
      final viewport = RenderAbstractViewport.maybeOf(targetRenderObject);
      if (viewport == null) return;
      final position = _playbackQueueScrollController.position;
      if (!position.hasPixels) return;
      final targetOffset = viewport
          .getOffsetToReveal(targetRenderObject, 0.5)
          .offset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (MediaQuery.disableAnimationsOf(context)) {
        _playbackQueueScrollController.jumpTo(targetOffset);
      } else {
        unawaited(_playbackQueueScrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        ));
      }
    });
  }

  bool _handlePlaybackQueueScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null)) {
      _isPlaybackQueueUserInteracting = true;
      _cancelPendingPlaybackQueueFollow();
    } else if (notification is ScrollEndNotification) {
      _isPlaybackQueueUserInteracting = false;
    }
    return false;
  }

  void _beginPlaybackQueueReorder() {
    _isReorderingPlaybackQueue = true;
    _cancelPendingPlaybackQueueFollow();
  }

  Future<void> _reorderPlaybackQueue(
    PlaybackState playback,
    int oldIndex,
    int newIndex,
  ) async {
    _beginPlaybackQueueReorder();
    try {
      await playback.reorderPlaybackQueue(oldIndex, newIndex);
    } finally {
      _endPlaybackQueueReorder();
    }
  }

  void _endPlaybackQueueReorder() {
    _cancelPendingPlaybackQueueFollow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _isReorderingPlaybackQueue = false;
    });
  }

  void _cancelPendingPlaybackQueueFollow() {
    _playbackQueueFollowGeneration++;
    _pendingPlaybackQueueFollowId = null;
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
      _clearAnalysisHydration(provider);
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
          (queueItemId) =>
              playback.setQueueTrimStartMsByQueueItemId(queueItemId, ms),
        );
      },
      onTrimEndChanged: (track, ms) {
        return _pauseThenEditPlaybackQueueItem(
          playback,
          track.queueItemId,
          (queueItemId) =>
              playback.setQueueTrimEndMsByQueueItemId(queueItemId, ms),
        );
      },
      onMoveEarlier: (track) => _movePlaybackTimelineTrack(playback, track, -1),
      onMoveLater: (track) => _movePlaybackTimelineTrack(playback, track, 1),
      onPitchModeChanged: (track, pitchMode) {
        return _pauseThenEditPlaybackQueueItem(
          playback,
          track.queueItemId,
          (queueItemId) =>
              playback.setQueuePitchModeByQueueItemId(queueItemId, pitchMode),
        );
      },
      onTransitionSnapModeChanged: (mode) {
        _pauseThenEditTimeline(
          playback,
          () => playback.setTransitionSnapMode(mode),
        );
      },
      onEditAnalysis: (track, {currentSourcePositionMs}) =>
          _showAnalysisCorrectionSheet(
        context,
        provider,
        track,
        currentSourcePositionMs: currentSourcePositionMs,
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
      pinnedSources: [
        currentSource,
        ...upcomingSources.take(1),
      ],
    );
    final current = provider.trackWithAnalysis(
      currentSource,
      requestHydration: false,
    );
    final previous = previousSource == null
        ? null
        : provider.trackWithAnalysis(previousSource, requestHydration: false);
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
    ListeningQueueEntry entry, {
    required String queueItemId,
  }) async {
    if (_isStablePlaybackQueueItemId(queueItemId)) {
      _suppressedPlaybackQueueFollowId = queueItemId;
    }
    try {
      await playback.skipToIndex(entry.index);
    } catch (_) {
      if (_suppressedPlaybackQueueFollowId == queueItemId) {
        _suppressedPlaybackQueueFollowId = null;
      }
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

  QueueTrack _playbackTrackFor(audio_service.MediaItem item, PlaybackCue cue) {
    return playbackTrackForMediaItem(
      item,
      queueItemId: cue.queueItemId,
    );
  }

  void _syncPlaybackAnalyses({
    required PlaybackState playback,
    required List<audio_service.MediaItem> queue,
    required Iterable<QueueTrack> tracks,
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
      _pendingAnalysisRefreshes[refreshKey] = (
        queueItemId: track.queueItemId,
        trackId: trackId,
        analysis: analysis,
      );
    }

    if (_pendingAnalysisRefreshes.isEmpty || _analysisRefreshScheduled) {
      return;
    }
    _analysisRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _analysisRefreshScheduled = false;
      final pending = Map.of(_pendingAnalysisRefreshes);
      _pendingAnalysisRefreshes.clear();
      if (!mounted) {
        _analysisRefreshesInFlight.removeAll(pending.keys);
        return;
      }

      final refreshes = <String, TrackAnalysis>{};
      for (final entry in pending.values) {
        final latestQueueIndex = _playbackQueueIndexForQueueItemId(
          playback,
          entry.queueItemId,
        );
        if (latestQueueIndex == null) continue;
        refreshes[entry.trackId] = entry.analysis;
      }
      if (refreshes.isEmpty) {
        _analysisRefreshesInFlight.removeAll(pending.keys);
        return;
      }
      unawaited(
        playback.refreshTrackAnalyses(refreshes).whenComplete(
              () => _analysisRefreshesInFlight.removeAll(pending.keys),
            ),
      );
    });
  }

  bool _mediaItemNeedsAnalysisRefresh(
    audio_service.MediaItem item,
    ClipTempoMetadata nextTempo,
  ) {
    if (nextTempo.isEmpty) return false;

    final extras = item.extras ?? const <String, dynamic>{};
    final currentAnalysis = trackAnalysisFromTrackJson(
      Map<String, dynamic>.from(extras),
    );
    final currentTempo = currentAnalysis == null
        ? ClipTempoMetadata.empty
        : ClipTempoMetadata.fromTrackAnalysis(currentAnalysis);
    return _compactPlaybackTempo(currentTempo) != nextTempo;
  }

  bool _timelineModelNeedsAnalysisRefresh(
    TimelineModel model,
    QueueTrack track,
    ClipTempoMetadata nextTempo,
  ) {
    if (nextTempo.isEmpty || model.clips.isEmpty) return false;

    for (final clip in model.clips) {
      if (_timelineClipMatchesTrack(clip, track)) {
        return _compactPlaybackTempo(clip.tempo) != nextTempo;
      }
    }
    return false;
  }

  bool _timelineClipMatchesTrack(MixClip clip, QueueTrack track) {
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
      _compactPlaybackTempo(
        ClipTempoMetadata.fromTrackAnalysis(analysis),
      );

  ClipTempoMetadata _compactPlaybackTempo(ClipTempoMetadata tempo) =>
      ClipTempoMetadata(
        nativeBpm: tempo.nativeBpm,
        bpmConfidence: tempo.bpmConfidence,
        beatGridOffsetMs: tempo.beatGridOffsetMs,
        beatAnchorMs: tempo.beatAnchorMs,
        beatsPerBar: tempo.beatsPerBar,
        downbeatPhaseIndex: tempo.downbeatPhaseIndex,
        meterConfidence: tempo.meterConfidence,
        meterProvenance: tempo.meterProvenance,
        downbeatPhaseConfidence: tempo.downbeatPhaseConfidence,
        downbeatPhaseProvenance: tempo.downbeatPhaseProvenance,
        phraseLengthBars: tempo.phraseLengthBars,
        overrideRevision: tempo.overrideRevision,
        beatsMs: _boundedTempoPositions(
          tempo.beatsMs,
          _maxPlaybackBeatPositions,
        ),
        downbeatsMs: _boundedTempoPositions(
          tempo.downbeatsMs,
          _maxPlaybackDownbeatPositions,
        ),
        downbeatConfidence: tempo.downbeatConfidence,
        bpmProvenance: tempo.bpmProvenance,
        beatGridProvenance: tempo.beatGridProvenance,
        downbeatProvenance: tempo.downbeatProvenance,
        musicalKey: tempo.musicalKey,
        camelot: tempo.camelot,
      );

  List<int> _boundedTempoPositions(List<int> positions, int limit) {
    if (positions.length <= limit) return positions;
    final headLength = limit ~/ 2;
    return [
      ...positions.take(headLength),
      ...positions.skip(positions.length - (limit - headLength)),
    ];
  }

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
    QueueTrack track,
    int delta,
  ) {
    unawaited(
      _pauseThenEditPlaybackQueueItem(
        playback,
        track.queueItemId,
        (queueItemId) =>
            playback.movePlaybackQueueItemByQueueItemId(queueItemId, delta),
      ),
    );
  }

  Widget _buildQueueHeader(BuildContext context, QueueProvider provider) {
    final colors = Theme.of(context).colorScheme;
    final stackedHeader = _usesStackedQueueHeader(context);
    final usesMobileHeader = MediaQuery.sizeOf(context).width < 960;
    final headerForeground = usesMobileHeader ? colors.onPrimary : null;
    final status = Selector<PlaybackState, Duration>(
      selector: (_, playback) => playback.position,
      builder: (context, position, _) =>
          _buildQueueStatusPill(context, provider, position),
    );
    final menu = PopupMenuButton<String>(
      key: const ValueKey('queue_header_menu'),
      tooltip: 'Queue actions',
      iconColor: headerForeground,
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
    return Container(
      key: const ValueKey('queue_header'),
      color: usesMobileHeader ? AppTheme.orange : Colors.transparent,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: stackedHeader
          ? Column(
              children: [
                Row(
                  children: [
                    Expanded(child: status),
                    menu,
                  ],
                ),
                const SizedBox(height: 8),
                _buildViewSwitch(
                  context,
                  expanded: true,
                  foregroundColor: headerForeground,
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: status),
                const SizedBox(width: 8),
                _buildViewSwitch(
                  context,
                  foregroundColor: headerForeground,
                ),
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
      MediaQuery.sizeOf(context).width < 960 ||
      MediaQuery.textScalerOf(context).scale(1) >= 1.3;

  Widget _buildViewSwitch(
    BuildContext context, {
    bool expanded = false,
    Color? foregroundColor,
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
        style: foregroundColor == null
            ? null
            : ButtonStyle(
                foregroundColor: WidgetStatePropertyAll(foregroundColor),
              ),
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
      pinnedSources: [
        sourceTracks[currentIndex],
        ...sourceTracks.skip(currentIndex + 1).take(1),
      ],
    );
    final tracks = hydrationSources
        .map(
          (track) => provider.trackWithAnalysis(track, requestHydration: false),
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
      onEditAnalysis: (track, {currentSourcePositionMs}) =>
          _showAnalysisCorrectionSheet(
        context,
        provider,
        track,
        currentSourcePositionMs: currentSourcePositionMs,
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
    required List<QueueTrack> sources,
    required Iterable<QueueTrack> pinnedSources,
  }) {
    final contextChanged = !identical(_hydrationQueueIdentity, queueIdentity) ||
        _hydrationCurrentIndex != currentIndex ||
        _hydrationUsesPlaybackQueue != usesPlaybackQueue;
    if (contextChanged) {
      _hydrationQueueIdentity = queueIdentity;
      _hydrationCurrentIndex = currentIndex;
      _hydrationUsesPlaybackQueue = usesPlaybackQueue;
      _visibleHydrationTrackKeys = <String>[];
    }

    _hydrationSourcesByKey = {
      for (final track in sources) _timelineHydrationTrackKey(track): track,
    };
    _pinnedHydrationTrackKeys = _uniqueHydrationKeys([
      for (final track in pinnedSources) _timelineHydrationTrackKey(track),
    ]);
    provider.setAnalysisHydrationInterest(_prioritizedHydrationTracks());
  }

  List<QueueTrack> _prioritizedHydrationTracks() {
    final keys = _uniqueHydrationKeys([
      ..._pinnedHydrationTrackKeys,
      ..._visibleHydrationTrackKeys,
    ]);
    return [
      for (final key in keys)
        if (_hydrationSourcesByKey[key] case final track?) track,
    ];
  }

  List<String> _uniqueHydrationKeys(Iterable<String> keys) {
    final seen = <String>{};
    return [
      for (final key in keys)
        if (seen.add(key)) key,
    ];
  }

  bool _sameHydrationKeys(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  void _updateVisibleAnalysisHydration(
    QueueProvider provider,
    List<QueueTrack> tracks,
  ) {
    final next = _uniqueHydrationKeys([
      for (final track in tracks) _timelineHydrationTrackKey(track),
    ]);
    if (_sameHydrationKeys(next, _visibleHydrationTrackKeys)) return;
    _visibleHydrationTrackKeys = next;
    provider.setAnalysisHydrationInterest(_prioritizedHydrationTracks());
  }

  String _timelineHydrationTrackKey(QueueTrack track) =>
      '${track.queueItemId}|${track.id}|${track.playbackTrackId ?? ''}';

  void _clearAnalysisHydration(QueueProvider provider) {
    _hydrationQueueIdentity = null;
    _hydrationCurrentIndex = null;
    _hydrationUsesPlaybackQueue = null;
    _hydrationSourcesByKey = <String, QueueTrack>{};
    _pinnedHydrationTrackKeys = <String>[];
    _visibleHydrationTrackKeys = <String>[];
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
    _hydrationSourcesByKey = <String, QueueTrack>{};
    _pinnedHydrationTrackKeys = <String>[];
    _visibleHydrationTrackKeys = <String>[];
    _playbackTimelineTracksCache = null;
  }

  Widget _buildListView(BuildContext context, QueueProvider provider) {
    final currentIndex = provider.queue.currentIndex;
    final tracks = provider.queue.tracks;
    final hasActiveTrack =
        currentIndex >= 0 && currentIndex < provider.queue.tracks.length;

    return ReorderableListView.builder(
      key: const PageStorageKey('queue_list_view'),
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: tracks.length,
      onReorderItem: (oldIndex, newIndex) {
        if (oldIndex == newIndex) return;
        unawaited(provider.reorderQueue(oldIndex, newIndex));
      },
      itemBuilder: (context, absoluteIndex) {
        final track = tracks[absoluteIndex];
        final isCurrent = hasActiveTrack && absoluteIndex == currentIndex;
        final canEdit = !hasActiveTrack || absoluteIndex > currentIndex;

        return _buildSwipeToRemoveQueueItem(
          context: context,
          key: ValueKey('remove_queue_${track.queueItemId}'),
          enabled: canEdit,
          label: track.title,
          onRemove: () => provider.removeFromQueue(absoluteIndex),
          child: QueueItem(
            key: ValueKey('queue_item_${track.queueItemId}'),
            track: track,
            isPlaying: isCurrent,
            reorderHandle: _buildReorderHandle(
              queueItemId: track.queueItemId,
              title: track.title,
              index: absoluteIndex,
            ),
            showTrimControls: canEdit,
            trimRange: canEdit ? provider.trimRangeFor(track) : null,
            waveformPeaks:
                canEdit ? provider.waveformPeaksFor(track) : const [],
            onTrimStartChanged:
                canEdit ? (ms) => provider.setStartOffsetMs(track, ms) : null,
            onTrimEndChanged:
                canEdit ? (ms) => provider.setEndOffsetMs(track, ms) : null,
            onPlay:
                track.queueStatus == TrackQueueStatus.playable && track.canPlay
                    ? () => _playFromQueue(context, provider, track)
                    : null,
            onRetry: track.canRetry ? () => provider.retryTrack(track) : null,
            onRemove:
                canEdit ? () => provider.removeFromQueue(absoluteIndex) : null,
            onEditAnalysis: _canEditAnalysis(track)
                ? () => _showAnalysisCorrectionSheet(context, provider, track)
                : null,
          ),
        );
      },
    );
  }

  void _moveTimelineTrack(
    QueueProvider provider,
    List<QueueTrack> upNext,
    int currentIndex,
    QueueTrack track,
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
    QueueTrack selectedTrack,
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

  /// Left-edge vertical grip. Only this widget starts a reorder drag.
  Widget _buildReorderHandle({
    required String queueItemId,
    required String title,
    required int index,
  }) {
    return Semantics(
      key: ValueKey('reorder_handle_$queueItemId'),
      container: true,
      explicitChildNodes: true,
      button: true,
      label: 'Reorder $title',
      hint: 'Drag vertically to move this queued track',
      child: ReorderableDragStartListener(
        index: index,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Icon(Icons.drag_handle, color: Colors.grey[500]),
          ),
        ),
      ),
    );
  }

  Widget _buildSwipeToRemoveQueueItem({
    required BuildContext context,
    required Key key,
    required Widget child,
    required String label,
    required Future<void> Function() onRemove,
    required bool enabled,
    GestureTapUpCallback? onSecondaryTapUp,
  }) {
    final result = enabled
        ? Dismissible(
            key: onSecondaryTapUp == null
                ? key
                : ValueKey('dismissible_${key.toString()}'),
            direction: DismissDirection.endToStart,
            background: const SizedBox.shrink(),
            secondaryBackground: _buildSwipeDeleteBackground(context, label),
            confirmDismiss: (_) async {
              await onRemove();
              return false;
            },
            child: child,
          )
        : child;
    if (onSecondaryTapUp == null) return result;
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: onSecondaryTapUp,
      child: result,
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
      case 'save_playlist':
        unawaited(_saveQueueAsPlaylist());
        break;
    }
  }

  /// Keeps an ad-hoc queue (drag-reordered, play-next inserts) as a playlist.
  ///
  /// The saved order is the visible play order — the listening queue itself,
  /// not the collection it was launched from — so a shuffled session saves what
  /// the user can actually see.
  Future<void> _saveQueueAsPlaylist() async {
    final messenger = ScaffoldMessenger.of(context);
    final trackIds = saveableQueueTrackIds(context.read<PlaybackState>().queue);
    if (trackIds.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No saveable tracks in the queue')),
      );
      return;
    }
    final playlistService = widget.playlistService ??
        PlaylistService(api: context.read<ApiClient>());

    List<Playlist> playlists;
    try {
      playlists = (await playlistService.getPlaylists()).playlists;
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to load playlists')),
      );
      return;
    }
    if (!mounted) return;

    var createNew = false;
    final selected = await showModalBottomSheet<Playlist>(
      context: context,
      builder: (sheetContext) => PlaylistPickerSheet(
        playlists: playlists,
        title: 'Save queue as playlist',
        leading: ListTile(
          key: const ValueKey('queue_new_playlist_from_queue'),
          leading: const Icon(Icons.add),
          title: const Text('New playlist'),
          onTap: () {
            createNew = true;
            Navigator.of(sheetContext).pop();
          },
        ),
      ),
    );
    if (!mounted) return;

    if (createNew) {
      await _createPlaylistFromQueue(messenger, playlistService, trackIds);
      return;
    }
    if (selected == null) return;
    await _addQueueToPlaylist(messenger, playlistService, selected, trackIds);
  }

  Future<void> _createPlaylistFromQueue(
    ScaffoldMessengerState messenger,
    PlaylistService playlistService,
    List<int> trackIds,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => PlaylistEditDialog(
        onSave: (result) async {
          Playlist created;
          try {
            created = await playlistService.createPlaylist(
              name: result.name,
              description: result.description,
              coverUrl: result.coverUrl,
              isPublic: result.isPublic,
            );
          } catch (_) {
            messenger.showSnackBar(
              const SnackBar(content: Text('Failed to create playlist')),
            );
            return;
          }
          await _addQueueToPlaylist(
            messenger,
            playlistService,
            created,
            trackIds,
          );
        },
      ),
    );
  }

  /// Duplicate handling is the backend's: [AddTracksResult] reports what was
  /// added versus already present, and that report is what the user is told.
  Future<void> _addQueueToPlaylist(
    ScaffoldMessengerState messenger,
    PlaylistService playlistService,
    Playlist playlist,
    List<int> trackIds,
  ) async {
    try {
      final result = await playlistService.addTracks(playlist.id, trackIds);
      messenger.showSnackBar(
        SnackBar(content: Text(result.feedbackMessage(playlist.name))),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Failed to save queue as playlist')),
      );
    }
  }

  bool _canEditAnalysis(QueueTrack track) {
    return _analysisTrackId(track) != null;
  }

  String? _analysisTrackId(QueueTrack track) {
    for (final candidate in [track.playbackTrackId, track.id]) {
      final parsed = int.tryParse(candidate ?? '');
      if (parsed != null && parsed > 0) return parsed.toString();
    }
    return null;
  }

  Future<void> _showAnalysisCorrectionSheet(
    BuildContext context,
    QueueProvider provider,
    QueueTrack track, {
    int? currentSourcePositionMs,
  }) async {
    if (!_canEditAnalysis(track)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No analysis target for "${track.title}"')),
      );
      return;
    }

    final playback = context.read<PlaybackState>();
    final desktopWorkspace = usesDesktopAnalysisCorrectionWorkspace(context);
    late final QueueTrack editorTrack;
    try {
      if (desktopWorkspace) {
        final analysis = await provider.refreshAnalysisAuthoritatively(track);
        editorTrack = track.copyWith(analysis: analysis);
      } else {
        editorTrack = provider.trackWithAnalysis(
          track,
          requestHydration: false,
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not load the latest analysis for "${track.title}".',
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    var editorRevision = editorTrack.analysis?.overrideRevision ??
        editorTrack.analysis?.overrides?.manualTiming?.revision ??
        0;
    final authoritativeEditorTrack = ValueNotifier<QueueTrack>(editorTrack);
    final settingsContainer = _settingsContainer(context);
    final initialSettings =
        settingsContainer?.read(settingsProvider) ?? const SettingsModel();
    AuditionOutputRouteMonitor? routeMonitor;
    try {
      routeMonitor = await (widget.auditionOutputRouteMonitorFactory ??
          AuditionOutputRouteMonitor.create)();
      await routeMonitor.start();
    } catch (error) {
      await _disposeRouteMonitor(routeMonitor);
      routeMonitor = null;
      if (kDebugMode) {
        debugPrint('Click audition route observation unavailable: $error');
      }
    }
    if (!mounted) {
      await _disposeRouteMonitor(routeMonitor);
      authoritativeEditorTrack.dispose();
      return;
    }

    final route =
        routeMonitor?.current ?? AuditionOutputRouteObservation.unknown;
    final initialCalibrationRoute = route.activeRouteConfirmed
        ? route.route
        : ClickAuditionOutputRoute.unknown;
    final routeListenable =
        ValueNotifier<AuditionOutputRouteObservation>(route);
    final routeSubscription = routeMonitor?.observations.listen(
      (observation) => routeListenable.value = observation,
    );
    final initialProjection =
        analysisTimingAuditionProjectionForTrack(editorTrack);
    ClickAuditionLease? lease;
    try {
      lease = playback.openClickAudition(
        ClickAuditionRequest(
          queueItemId: track.queueItemId,
          sourceBeatsMs: initialProjection.sourceBeatsMs,
          sourceDownbeatsMs: initialProjection.sourceDownbeatsMs,
          // Both toggles are independent. Beat clicks remain session-local and
          // off by default; the remembered accent preference can audition
          // explicit downbeats on its own.
          beatClicksEnabled: false,
          downbeatAccentsEnabled:
              initialSettings.clickAuditionDownbeatAccentEnabled &&
                  initialProjection.sourceDownbeatsMs.isNotEmpty,
          volume: initialSettings.clickAuditionVolume,
          outputOffsetMs: initialSettings
              .clickAuditionOutputOffsetMsFor(initialCalibrationRoute),
        ),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Click audition unavailable: $error');
      }
    }

    TrackAnalysisOverrides? corrected;
    try {
      corrected = await showAnalysisCorrectionEditor(
        context: this.context,
        track: editorTrack,
        currentSourcePositionMs: currentSourcePositionMs,
        liveSourcePositionMs: desktopWorkspace
            ? () => playback.sourcePositionMsForQueueItemId(track.queueItemId)
            : null,
        playbackListenable: desktopWorkspace ? playback : null,
        analysisListenable: desktopWorkspace ? authoritativeEditorTrack : null,
        trackResolver:
            desktopWorkspace ? () => authoritativeEditorTrack.value : null,
        onPlayPause: desktopWorkspace
            ? () async {
                final selectedIsCurrent =
                    playback.sourcePositionMsForQueueItemId(
                          track.queueItemId,
                        ) !=
                        null;
                if (selectedIsCurrent && playback.isPlaying) {
                  await playback.pause();
                  return;
                }
                await playback.playQueueItemByQueueItemId(track.queueItemId);
              }
            : null,
        isPlaying: desktopWorkspace
            ? () =>
                playback.isPlaying &&
                playback.sourcePositionMsForQueueItemId(track.queueItemId) !=
                    null
            : null,
        onSave: desktopWorkspace
            ? (overrides) async {
                try {
                  final analysis = await provider.updateAnalysisOverrides(
                    editorTrack,
                    overrides,
                    expectedRevision: editorRevision,
                  );
                  final trackId = _analysisTrackId(track);
                  if (trackId != null) {
                    try {
                      await playback.refreshTrackAnalysis(trackId, analysis);
                    } catch (error) {
                      if (kDebugMode) {
                        debugPrint(
                          'Saved analysis but could not refresh playback: $error',
                        );
                      }
                    }
                  }
                  return null;
                } catch (error) {
                  if (error is ApiException && error.statusCode == 409) {
                    try {
                      final latest =
                          await provider.refreshAnalysisAuthoritatively(track);
                      editorRevision = latest.overrideRevision ??
                          latest.overrides?.manualTiming?.revision ??
                          editorRevision;
                      authoritativeEditorTrack.value =
                          track.copyWith(analysis: latest);
                    } catch (_) {
                      // Keep the original conflict visible; never auto-retry.
                    }
                    return 'This analysis changed elsewhere. Your draft is '
                        'still here. Review the conflict, then choose Save '
                        'again to apply it to revision $editorRevision.';
                  }
                  return 'Could not save analysis for "${track.title}". '
                      'Your draft is still here.';
                }
              }
            : null,
        clickAudition: AnalysisClickAuditionConfiguration(
          initialDownbeatAccentsEnabled:
              initialSettings.clickAuditionDownbeatAccentEnabled,
          initialVolume: initialSettings.clickAuditionVolume,
          initialRoute: route,
          routeListenable: routeListenable,
          outputOffsetForRoute: (outputRoute) {
            return (settingsContainer?.read(settingsProvider) ??
                    initialSettings)
                .clickAuditionOutputOffsetMsFor(outputRoute);
          },
          onPreviewChanged: (preview) {
            final activeLease = lease;
            if (activeLease == null) return;
            unawaited(
              _updateClickAudition(
                activeLease,
                ClickAuditionRequest(
                  queueItemId: track.queueItemId,
                  sourceBeatsMs: preview.sourceBeatsMs,
                  sourceDownbeatsMs: preview.sourceDownbeatsMs,
                  beatClicksEnabled: preview.beatClicksEnabled,
                  downbeatAccentsEnabled: preview.downbeatAccentsEnabled,
                  volume: preview.volume,
                  outputOffsetMs: preview.outputOffsetMs,
                ),
              ),
            );
          },
          onVolumeChanged: (volume) => settingsContainer
              ?.read(settingsProvider.notifier)
              .setClickAuditionVolume(volume),
          onDownbeatAccentsChanged: (enabled) => settingsContainer
              ?.read(settingsProvider.notifier)
              .setClickAuditionDownbeatAccentEnabled(enabled),
          onOutputOffsetChanged: (outputRoute, offsetMs) => settingsContainer
              ?.read(settingsProvider.notifier)
              .setClickAuditionOutputOffsetMs(outputRoute, offsetMs),
        ),
      );
    } finally {
      await _disposeClickAuditionLease(lease);
      await routeSubscription?.cancel();
      routeListenable.dispose();
      authoritativeEditorTrack.dispose();
      await _disposeRouteMonitor(routeMonitor);
    }
    if (desktopWorkspace) return;
    if (corrected == null || !mounted) return;

    try {
      final analysis = await provider.updateAnalysisOverrides(track, corrected);
      final trackId = _analysisTrackId(track);
      if (trackId != null && mounted) {
        await this.context.read<PlaybackState>().refreshTrackAnalysis(
              trackId,
              analysis,
            );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(content: Text('Could not save analysis for "${track.title}"')),
      );
    }
  }

  ProviderContainer? _settingsContainer(BuildContext context) {
    try {
      return ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      // Some narrow widget harnesses mount QueueScreen without the app-level
      // ProviderScope. Audition still works with safe local defaults.
      return null;
    }
  }

  Future<void> _updateClickAudition(
    ClickAuditionLease lease,
    ClickAuditionRequest request,
  ) async {
    try {
      await lease.update(request);
    } catch (error) {
      if (kDebugMode) debugPrint('Could not update click audition: $error');
    }
  }

  Future<void> _disposeClickAuditionLease(ClickAuditionLease? lease) async {
    try {
      await lease?.dispose();
    } catch (error) {
      if (kDebugMode) debugPrint('Could not close click audition: $error');
    }
  }

  Future<void> _disposeRouteMonitor(
    AuditionOutputRouteMonitor? monitor,
  ) async {
    try {
      await monitor?.dispose();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Could not close click audition route monitor: $error');
      }
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
  final List<QueueTrack> tracks;
  final QueueTrack? previous;
  final QueueTrack current;
  final List<QueueTrack> upcoming;

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
