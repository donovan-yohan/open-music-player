import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../engine/playback_engine.dart';
import '../engine/tempo_automation.dart';
import '../engine/timeline_model.dart';
import '../../models/timeline_clip.dart';
import 'playback_session.dart';
import 'queue_persistence.dart';

class QueueTimelineController {
  QueueTimelineController(this._engine, {math.Random? shuffleRandom})
      : _shuffleRandom = shuffleRandom ?? math.Random() {
    _bind();
  }

  final PlaybackEngine _engine;
  final math.Random _shuffleRandom;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  final BehaviorSubject<List<MediaItem>> _queueSubject = BehaviorSubject.seeded(
    const [],
  );
  final BehaviorSubject<int?> _currentIndexSubject = BehaviorSubject.seeded(
    null,
  );
  final BehaviorSubject<bool> _shuffleEnabledSubject = BehaviorSubject.seeded(
    false,
  );
  final BehaviorSubject<LoopMode> _loopModeSubject = BehaviorSubject.seeded(
    LoopMode.off,
  );
  final BehaviorSubject<Duration> _positionSubject = BehaviorSubject.seeded(
    Duration.zero,
  );
  final BehaviorSubject<Duration> _bufferedPositionSubject =
      BehaviorSubject.seeded(Duration.zero);
  final BehaviorSubject<Duration?> _durationSubject = BehaviorSubject.seeded(
    Duration.zero,
  );
  final BehaviorSubject<MediaItem?> _currentMediaItemSubject =
      BehaviorSubject.seeded(null);
  final BehaviorSubject<PlayerState> _playerStateSubject =
      BehaviorSubject.seeded(PlayerState(false, ProcessingState.idle));
  final BehaviorSubject<PlaybackSnapshot> _snapshotSubject =
      BehaviorSubject.seeded(PlaybackSnapshot.empty());

  List<MediaItem> _queue = const [];
  List<int> _playOrder = const [];
  MixSession _session = MixSession.empty();
  CueTimeline _cueTimeline = CueTimeline.empty;
  int _sessionGeneration = 0;
  String _sessionId = 'session_0';
  int? _currentIndex;
  bool _shuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  ProcessingState _processingState = ProcessingState.idle;
  bool _started = false;
  bool _suppressPositionSync = false;
  Future<void> _commandChain = Future<void>.value();

  PlaybackEngine get engine => _engine;
  MixSession get session => _session;
  List<MediaItem> get queue => _queue;
  int? get currentIndex => _currentIndex;
  MediaItem? get currentMediaItem => _currentMediaItemSubject.valueOrNull;
  bool get shuffleEnabled => _shuffleEnabled;
  LoopMode get loopMode => _loopMode;
  Duration get position => _positionSubject.value;
  Duration get livePosition =>
      Duration(milliseconds: _localForGlobal(_engine.positionMs));
  Duration get bufferedPosition => _bufferedPositionSubject.value;
  Duration get duration => _durationSubject.value ?? Duration.zero;

  Stream<List<MediaItem>> get queueStream => _queueSubject.stream;
  Stream<int?> get currentIndexStream => _currentIndexSubject.stream;
  Stream<bool> get shuffleEnabledStream => _shuffleEnabledSubject.stream;
  Stream<LoopMode> get loopModeStream => _loopModeSubject.stream;
  Stream<Duration> get positionStream => _positionSubject.stream;
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionSubject.stream;
  Stream<Duration?> get durationStream => _durationSubject.stream;
  Stream<MediaItem?> get currentMediaItemStream =>
      _currentMediaItemSubject.stream;
  Stream<PlayerState> get playerStateStream => _playerStateSubject.stream;
  ValueStream<PlaybackSnapshot> get snapshotStream => _snapshotSubject.stream;
  PlaybackSnapshot get snapshot => _snapshotSubject.value;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _engine.start();
  }

  Future<void> setQueue(
    List<MediaItem> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool preserveTimelineEdits = false,
    int? reflowDefaultTransitionsFromIndex,
    MixSession? session,
  }) async {
    await _enqueueCommand(
      () => _setQueue(
        items,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
        preserveTimelineEdits: preserveTimelineEdits,
        reflowDefaultTransitionsFromIndex: reflowDefaultTransitionsFromIndex,
        session: session,
      ),
    );
  }

  Future<void> _setQueue(
    List<MediaItem> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool preserveTimelineEdits = false,
    int? reflowDefaultTransitionsFromIndex,
    MixSession? session,
  }) async {
    await start();
    _sessionGeneration += 1;
    _queue = List.unmodifiable(items);
    _playOrder = [for (var i = 0; i < _queue.length; i++) i];
    _sessionId = session?.sessionId ?? 'session_$_sessionGeneration';
    _session = session == null
        ? (preserveTimelineEdits
            ? _session.normalizedForQueue(_queue)
            : MixSession.fromQueue(sessionId: _sessionId, queue: _queue))
        : session.normalizedForQueue(_queue);
    if (reflowDefaultTransitionsFromIndex != null) {
      _session = _session.reflowDefaultTransitionsFrom(
        reflowDefaultTransitionsFromIndex,
      );
    }
    if (_queue.isEmpty) {
      _currentIndex = null;
      _session = MixSession.empty(sessionId: _sessionId);
      _cueTimeline = CueTimeline.empty;
      _processingState = ProcessingState.idle;
      await _engine.pause();
      await _engine.loadMix(TimelineModel());
      await _engine.seek(0);
      _publishQueueState();
      return;
    }
    _currentIndex = initialIndex.clamp(0, _queue.length - 1).toInt();
    _processingState = ProcessingState.ready;
    await _loadModel(
      seekToCurrent: true,
      localPositionMs: initialPosition.inMilliseconds,
    );
    _currentIndex = initialIndex.clamp(0, _queue.length - 1).toInt();
    _publishQueueState();
  }

  Future<void> addToQueue(MediaItem item) async {
    await _enqueueCommand(() => _insertIntoQueue(_queue.length, item));
  }

  Future<void> insertIntoQueue(int index, MediaItem item) async {
    await _enqueueCommand(() => _insertIntoQueue(index, item));
  }

  Future<void> _insertIntoQueue(int index, MediaItem item) async {
    final insertIndex = index.clamp(0, _queue.length).toInt();
    final previousCurrent = _currentIndex;
    final previousCurrentQueueItemId = previousCurrent == null
        ? null
        : _session.clipAt(previousCurrent)?.queueItemId;
    final localPosition = livePosition.inMilliseconds;
    final preserveActivePlayback = _canPreserveActivePlaybackForFutureInsert(
      insertIndex,
      previousCurrent,
      previousCurrentQueueItemId,
    );
    final nextQueue = List<MediaItem>.from(_queue)..insert(insertIndex, item);
    _queue = List.unmodifiable(nextQueue);
    _session = _session.insertAt(insertIndex, item).normalizedForQueue(_queue);
    if (previousCurrent == null) {
      _currentIndex = 0;
    } else if (insertIndex <= previousCurrent) {
      _currentIndex = previousCurrent + 1;
    }
    _rebuildPlayOrderKeepCurrent();
    _processingState = ProcessingState.ready;
    await _loadModel(
      seekToCurrent: !preserveActivePlayback,
      localPositionMs: localPosition,
      preserveActivePlayback: preserveActivePlayback,
    );
    _publishQueueState();
  }

  Future<void> removeFromQueue(int index) async {
    await _enqueueCommand(() => _removeFromQueue(index));
  }

  Future<void> _removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final previousCurrent = _currentIndex;
    final previousCurrentQueueItemId = previousCurrent == null
        ? null
        : _session.clipAt(previousCurrent)?.queueItemId;
    final localPosition = livePosition.inMilliseconds;
    final preserveActivePlayback = _canPreserveActivePlaybackForFutureRemove(
      index,
      previousCurrent,
      previousCurrentQueueItemId,
    );
    final nextQueue = List<MediaItem>.from(_queue)..removeAt(index);
    _queue = List.unmodifiable(nextQueue);
    _session = _session.removeAt(index).normalizedForQueue(_queue);
    if (_queue.isEmpty) {
      _currentIndex = null;
      _playOrder = const [];
      _session = MixSession.empty(sessionId: _sessionId);
      _cueTimeline = CueTimeline.empty;
      _processingState = ProcessingState.idle;
      await _engine.pause();
      await _engine.loadMix(TimelineModel());
      await _engine.seek(0);
    } else if (previousCurrent == index) {
      _currentIndex = math.min(index, _queue.length - 1);
      _rebuildPlayOrderKeepCurrent();
      _processingState = ProcessingState.ready;
      await _loadModel(seekToCurrent: true);
    } else {
      if (previousCurrent != null && index < previousCurrent) {
        _currentIndex = previousCurrent - 1;
      }
      _rebuildPlayOrderKeepCurrent();
      _processingState = ProcessingState.ready;
      await _loadModel(
        seekToCurrent: !preserveActivePlayback,
        localPositionMs: localPosition,
        preserveActivePlayback: preserveActivePlayback,
      );
    }
    _publishQueueState();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    await _enqueueCommand(() => _reorderQueue(oldIndex, newIndex));
  }

  Future<void> _reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex >= _queue.length) return;

    final localPosition = livePosition.inMilliseconds;
    final nextQueue = List<MediaItem>.from(_queue);
    final item = nextQueue.removeAt(oldIndex);
    nextQueue.insert(newIndex, item);
    _queue = List.unmodifiable(nextQueue);
    _session = _session.reorder(oldIndex, newIndex).normalizedForQueue(_queue);

    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (_currentIndex != null &&
        oldIndex < _currentIndex! &&
        newIndex >= _currentIndex!) {
      _currentIndex = _currentIndex! - 1;
    } else if (_currentIndex != null &&
        oldIndex > _currentIndex! &&
        newIndex <= _currentIndex!) {
      _currentIndex = _currentIndex! + 1;
    }

    _rebuildPlayOrderKeepCurrent();
    _session = _session.reflowedByOrder(_playOrder);
    _processingState = ProcessingState.ready;
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    _publishQueueState();
  }

  TimelineClip? timelineClipForIndex(int index) =>
      _session.clipAt(index)?.placement;

  Future<void> setTimelineStartMs(
    int index,
    int ms, {
    bool snapToDownbeat = true,
  }) async {
    await _enqueueCommand(
      () => _setTimelineStartMs(index, ms, snapToDownbeat: snapToDownbeat),
    );
  }

  Future<void> _setTimelineStartMs(
    int index,
    int ms, {
    required bool snapToDownbeat,
  }) async {
    if (index < 0 || index >= _queue.length) return;
    final requested = _placementForIndex(index).withTimelineStartMs(ms);
    final placement =
        snapToDownbeat ? _snapPlacementToDownbeat(index, requested) : requested;
    await _applyCueOverride(index, placement);
  }

  Future<void> setSourceStartMs(int index, int ms) async {
    await _enqueueCommand(() => _setSourceStartMs(index, ms));
  }

  Future<void> _setSourceStartMs(int index, int ms) async {
    if (index < 0 || index >= _queue.length) return;
    final placement = _placementForIndex(index);
    await _applyCueOverride(
      index,
      placement.withSourceRange(
        sourceStartMs: ms,
        sourceEndMs: placement.sourceEndMs,
      ),
    );
  }

  Future<void> setSourceEndMs(int index, int ms) async {
    await _enqueueCommand(() => _setSourceEndMs(index, ms));
  }

  Future<void> _setSourceEndMs(int index, int ms) async {
    if (index < 0 || index >= _queue.length) return;
    final placement = _placementForIndex(index);
    await _applyCueOverride(
      index,
      placement.withSourceRange(
        sourceStartMs: placement.sourceStartMs,
        sourceEndMs: ms,
      ),
    );
  }

  Future<void> play() async {
    await _enqueueCommand(_play);
  }

  Future<void> _play() async {
    if (_queue.isEmpty) return;
    await start();
    if (_processingState == ProcessingState.completed) {
      await _skipToIndex(_currentIndex ?? 0);
    }
    _processingState = ProcessingState.ready;
    _publishPlayerState();
    await _engine.play();
  }

  Future<void> pause() async {
    await _enqueueCommand(_pause);
  }

  Future<void> _pause() async {
    await _engine.pause();
  }

  Future<void> stop() async {
    await _enqueueCommand(_stop);
  }

  Future<void> _stop() async {
    await _engine.pause();
    _processingState = ProcessingState.idle;
    _publishPlayerState();
  }

  Future<void> seek(Duration position) async {
    await _enqueueCommand(() => _seek(position));
  }

  Future<void> _seek(Duration position) async {
    final globalMs = _globalForCurrentLocal(position.inMilliseconds);
    await _engine.seek(globalMs);
  }

  void beginLocalScrub() => _engine.beginScrub();

  void updateLocalScrub(Duration position) {
    final globalMs = _globalForCurrentLocal(position.inMilliseconds);
    _engine.updateScrub(globalMs);
  }

  Future<void> endLocalScrub(Duration position) {
    return _enqueueCommand(() => _endLocalScrub(position));
  }

  Future<void> _endLocalScrub(Duration position) {
    final globalMs = _globalForCurrentLocal(position.inMilliseconds);
    return _engine.endScrub(globalMs);
  }

  Future<void> skipToNext() async {
    await _enqueueCommand(_skipToNext);
  }

  Future<void> _skipToNext() async {
    if (_queue.isEmpty) return;
    final next = _nextQueueIndex();
    if (next == null) {
      if (_loopMode == LoopMode.one) {
        await _skipToIndex(_currentIndex ?? 0);
      } else if (_loopMode == LoopMode.all) {
        await _skipToIndex(_playOrder.isEmpty ? 0 : _playOrder.first);
      }
      return;
    }
    await _skipToIndex(next);
  }

  Future<void> skipToPrevious() async {
    await _enqueueCommand(_skipToPrevious);
  }

  Future<void> _skipToPrevious() async {
    if (_queue.isEmpty) return;
    final previous = _previousQueueIndex();
    await _skipToIndex(previous ?? (_currentIndex ?? 0));
  }

  Future<void> skipToIndex(int index) async {
    await _enqueueCommand(() => _skipToIndex(index));
  }

  Future<void> _skipToIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    await start();
    _currentIndex = index;
    if (!_playOrder.contains(index)) {
      _rebuildPlayOrderKeepCurrent();
      await _loadModel(seekToCurrent: true);
    } else {
      await _engine.seek(_clipStartForQueueIndex(index));
    }
    _processingState = ProcessingState.ready;
    _publishQueueState();
  }

  Future<void> setShuffleMode(bool enabled) async {
    await _enqueueCommand(() => _setShuffleMode(enabled));
  }

  Future<void> _setShuffleMode(bool enabled) async {
    if (_shuffleEnabled == enabled) return;
    final current = _queueIndexForGlobal(_engine.positionMs) ?? _currentIndex;
    final localPosition = livePosition.inMilliseconds;
    _shuffleEnabled = enabled;
    if (current != null && current >= 0 && current < _queue.length) {
      _currentIndex = current;
    }
    _rebuildPlayOrderKeepCurrent();
    _session = _session.reflowedByOrder(_playOrder);
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    if (current != null && current >= 0 && current < _queue.length) {
      _currentIndex = current;
      await _engine.seek(_globalForCurrentLocal(localPosition));
    }
    _publishQueueState();
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await _enqueueCommand(() => _setLoopMode(mode));
  }

  Future<void> _setLoopMode(LoopMode mode) async {
    _loopMode = mode;
    _loopModeSubject.add(mode);
  }

  Future<void> toggleShuffle() =>
      _enqueueCommand(() => _setShuffleMode(!_shuffleEnabled));

  Future<void> cycleLoopMode() async {
    await _enqueueCommand(() async {
      final modes = [LoopMode.off, LoopMode.all, LoopMode.one];
      final current = modes.indexOf(_loopMode);
      await _setLoopMode(modes[(current + 1) % modes.length]);
    });
  }

  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _queueSubject.close();
    await _currentIndexSubject.close();
    await _shuffleEnabledSubject.close();
    await _loopModeSubject.close();
    await _positionSubject.close();
    await _bufferedPositionSubject.close();
    await _durationSubject.close();
    await _currentMediaItemSubject.close();
    await _playerStateSubject.close();
    await _snapshotSubject.close();
    await _engine.dispose();
  }

  void _bind() {
    _subscriptions
      ..add(_engine.positionMsStream.listen(_onGlobalPosition))
      ..add(_engine.isPlayingStream.listen((_) => _publishPlayerState()))
      ..add(
        _engine.clipCompletionStream.listen((event) {
          if (_suppressPositionSync) return;
          unawaited(_onClipCompleted(event));
        }),
      )
      ..add(
        _engine.clock.completedStream.listen((_) {
          if (_suppressPositionSync) return;
          unawaited(_onCompleted());
        }),
      )
      ..add(_engine.pool.pitchFallbackClipIdsStream
          .listen((_) => _publishSnapshot(_engine.positionMs)));
  }

  Future<T> _enqueueCommand<T>(Future<T> Function() command) {
    final completer = Completer<T>();
    final next = _commandChain.then((_) async {
      try {
        completer.complete(await command());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _commandChain = next.then((_) {}, onError: (_) {});
    return completer.future;
  }

  Future<void> _loadModel({
    required bool seekToCurrent,
    int localPositionMs = 0,
    bool preserveActivePlayback = false,
  }) async {
    _session = _session.normalizedForQueue(_queue);
    _cueTimeline = CueTimeline.fromSession(
      session: _session,
      queue: _queue,
      playOrder: _playOrder,
    );
    _suppressPositionSync = true;
    try {
      await _engine.loadMix(
        _cueTimeline.toTimelineModel(),
        preserveActivePlayback: preserveActivePlayback,
      );
      if (seekToCurrent && _currentIndex != null) {
        await _engine.seek(_globalForCurrentLocal(localPositionMs));
      }
    } finally {
      await Future<void>.delayed(Duration.zero);
      _suppressPositionSync = false;
    }
    _publishPosition(_engine.positionMs);
  }

  bool _canPreserveActivePlaybackForFutureInsert(
    int insertIndex,
    int? previousCurrent,
    String? previousCurrentQueueItemId,
  ) {
    if (!_engine.isPlaying || previousCurrent == null) return false;
    if (previousCurrentQueueItemId == null) return false;
    if (insertIndex <= previousCurrent) return false;
    final active = _engine.model.activeClipsAt(_engine.positionMs);
    return active.length == 1 &&
        active.single.queueItemId == previousCurrentQueueItemId;
  }

  bool _canPreserveActivePlaybackForFutureRemove(
    int removeIndex,
    int? previousCurrent,
    String? previousCurrentQueueItemId,
  ) {
    if (!_engine.isPlaying || previousCurrent == null) return false;
    if (previousCurrentQueueItemId == null) return false;
    if (removeIndex <= previousCurrent) return false;
    final active = _engine.model.activeClipsAt(_engine.positionMs);
    return active.length == 1 &&
        active.single.queueItemId == previousCurrentQueueItemId;
  }

  TimelineClip _placementForIndex(int index) {
    final current = _session.clipAt(index)?.placement;
    if (current != null) return current;

    final item = _queue[index];
    final durationMs = item.duration?.inMilliseconds ?? 0;
    return TimelineClip.clamped(
      id: '${_sessionId}_queue_$index',
      trackId: item.id,
      sourceDurationMs: durationMs,
      sourceStartMs: 0,
      sourceEndMs: durationMs,
      timelineStartMs: 0,
    );
  }

  Future<void> _applyCueOverride(int index, TimelineClip placement) async {
    final nextSession = _session.withPlacementAt(index, placement);
    if (!_canApplySession(nextSession)) return;

    final localPosition = livePosition.inMilliseconds;
    _session = nextSession.normalizedForQueue(_queue);
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    _publishQueueState();
  }

  bool _canApplySession(MixSession session) {
    final timeline = CueTimeline.fromSession(
      session: session,
      queue: _queue,
      playOrder: _playOrder,
    );
    final clips = timeline.cues.map((cue) => cue.toMixClip()).toList();
    final model = TimelineModel(clips: clips);
    return model.clips.length == clips.length;
  }

  void _rebuildPlayOrderKeepCurrent() {
    if (_queue.isEmpty) {
      _playOrder = const [];
      return;
    }
    final current = (_currentIndex ?? 0).clamp(0, _queue.length - 1).toInt();
    if (_shuffleEnabled) {
      _playOrder = shufflePermutation(
        _queue.length,
        current,
        random: _shuffleRandom,
      );
    } else {
      _playOrder = [for (var i = 0; i < _queue.length; i++) i];
    }
  }

  void _onGlobalPosition(int globalMs) {
    if (_suppressPositionSync) return;
    final previousIndex = _currentIndex;
    if (!_shouldDeferCurrentIndexSync(globalMs)) {
      _syncCurrentIndexFromGlobal(globalMs);
    }
    _publishPosition(globalMs);
    if (_currentIndex != previousIndex) {
      _publishQueueState(includeQueue: false);
    }
  }

  bool _shouldDeferCurrentIndexSync(int globalMs) {
    final currentClip = _currentClip();
    return currentClip != null &&
        currentClip.timelineEndMs < _engine.durationMs &&
        globalMs >= currentClip.timelineEndMs;
  }

  void _syncCurrentIndexFromGlobal(int globalMs) {
    final index = _queueIndexForGlobal(globalMs);
    if (index != null) _currentIndex = index;
  }

  int? _queueIndexForGlobal(int globalMs) {
    if (_queue.isEmpty || _playOrder.isEmpty) return null;
    final dominant = _engine.model.dominantClipAt(globalMs);
    final queueItemId = dominant?.queueItemId;
    if (queueItemId != null) {
      final cue = _cueTimeline.cueForQueueItemId(queueItemId);
      if (cue != null) return cue.queueIndex;
    }
    return _cueTimeline
            .currentCueAt(Duration(milliseconds: globalMs))
            ?.queueIndex ??
        _currentIndex ??
        _playOrder.first;
  }

  void _publishPosition(int globalMs) {
    final localMs = _localForGlobal(globalMs);
    final position = Duration(milliseconds: localMs);
    final duration = _durationForCurrentItem();
    _positionSubject.add(position);
    _bufferedPositionSubject.add(duration);
    _durationSubject.add(duration);
    _currentMediaItemSubject.add(
      _currentIndex == null ? null : _queue[_currentIndex!],
    );
    _publishSnapshot(globalMs);
  }

  Duration _durationForCurrentItem() {
    return _currentCue()?.selectedDuration ?? Duration.zero;
  }

  int _localForGlobal(int globalMs) {
    final clip = _currentClip();
    if (clip != null) {
      return clip.sourcePositionAt(globalMs) - clip.placement.sourceStartMs;
    }
    final cue = _currentCue();
    if (cue == null) return 0;
    return _cueTimeline
        .localFor(cue, Duration(milliseconds: globalMs))
        .inMilliseconds;
  }

  int _globalForCurrentLocal(int localMs) {
    final clip = _currentClip();
    if (clip != null) {
      return clip.timelineMsForSourcePosition(
        clip.placement.sourceStartMs + localMs,
      );
    }
    final cue = _currentCue();
    if (cue == null) return 0;
    return _cueTimeline
        .globalFor(cue, Duration(milliseconds: localMs))
        .inMilliseconds;
  }

  int _clipStartForQueueIndex(int queueIndex) {
    return _cueTimeline
            .cueForQueueIndex(queueIndex)
            ?.timelineStart
            .inMilliseconds ??
        0;
  }

  PlaybackCue? _currentCue() {
    final current = _currentIndex;
    if (current == null) return null;
    return _cueTimeline.cueForQueueIndex(current);
  }

  int? _nextQueueIndex() {
    final current = _currentIndex;
    if (current == null) return null;
    return _nextQueueIndexAfter(current);
  }

  int? _nextQueueIndexAfter(int current) {
    final orderIndex = _playOrder.indexOf(current);
    if (orderIndex == -1 || orderIndex + 1 >= _playOrder.length) return null;
    return _playOrder[orderIndex + 1];
  }

  MixClip? _clipForCompletion(ClipCompletionEvent event) {
    for (final clip in _engine.model.clips) {
      if (clip.id == event.clipId) return clip;
    }
    return null;
  }

  MixClip? _currentClip() {
    final current = _currentIndex;
    if (current == null) return null;
    final queueItemId = _session.clipAt(current)?.queueItemId;
    if (queueItemId == null) return null;
    for (final clip in _engine.model.clips) {
      if (clip.queueItemId == queueItemId) return clip;
    }
    return null;
  }

  TimelineClip _snapPlacementToDownbeat(int index, TimelineClip requested) {
    final incoming = _session.clipAt(index);
    if (incoming == null) return requested;
    final previousIndex = _previousQueueIndexFor(index);
    if (previousIndex == null) return requested;
    final outgoing = _session.clipAt(previousIndex);
    if (outgoing == null) return requested;

    final snappedStart = snapIncomingStartToNearestDownbeat(
      requestedStartMs: requested.timelineStartMs,
      incomingSourceStartMs: requested.sourceStartMs,
      incomingTempo: incoming.tempo,
      outgoingTimelineStartMs: outgoing.timelineStartMs,
      outgoingSourceStartMs: outgoing.sourceStartMs,
      outgoingTempo: outgoing.tempo,
    );
    if (snappedStart == null) return requested;
    return requested.withTimelineStartMs(snappedStart);
  }

  int? _previousQueueIndexFor(int queueIndex) {
    final orderIndex = _playOrder.indexOf(queueIndex);
    if (orderIndex <= 0) return null;
    return _playOrder[orderIndex - 1];
  }

  int? _previousQueueIndex() {
    final current = _currentIndex;
    if (current == null) return null;
    final orderIndex = _playOrder.indexOf(current);
    if (orderIndex <= 0) return null;
    return _playOrder[orderIndex - 1];
  }

  void _publishQueueState({bool includeQueue = true}) {
    if (includeQueue) _queueSubject.add(_queue);
    _currentIndexSubject.add(_currentIndex);
    _shuffleEnabledSubject.add(_shuffleEnabled);
    _loopModeSubject.add(_loopMode);
    _currentMediaItemSubject.add(
      _currentIndex == null ? null : _queue[_currentIndex!],
    );
    _durationSubject.add(_durationForCurrentItem());
    _bufferedPositionSubject.add(_durationForCurrentItem());
    _publishSnapshot(_engine.positionMs);
    _publishPlayerState();
  }

  void _publishPlayerState() {
    _playerStateSubject.add(PlayerState(_engine.isPlaying, _processingState));
    _publishSnapshot(_engine.positionMs);
  }

  void _publishSnapshot(int globalMs) {
    final cue = _currentCue();
    final localPosition = cue == null
        ? Duration.zero
        : Duration(milliseconds: _localForGlobal(globalMs));
    _snapshotSubject.add(
      PlaybackSnapshot(
        sessionId: _sessionId,
        cues: _cueTimeline.cues,
        currentCueId: cue?.cueId,
        currentQueueIndex: _currentIndex,
        currentMediaItem: cue?.mediaItem,
        localPosition: localPosition,
        localDuration: cue?.selectedDuration ?? Duration.zero,
        globalPosition: Duration(milliseconds: globalMs),
        globalDuration: Duration(milliseconds: _engine.durationMs),
        playing: _engine.isPlaying,
        processingState: _processingState,
        activeVoiceCount: _engine.pool.activeVoiceCount,
        playbackSpeed: _playbackSpeedForGlobal(globalMs),
        pitchPreservationFallback: _engine.pool.hasPitchFallback,
        pitchFallbackClipIds: _engine.pool.pitchFallbackClipIds,
      ),
    );
  }

  double _playbackSpeedForGlobal(int globalMs) {
    final clip = _currentClip();
    if (clip == null) return 1;
    return (_engine.clock.rate * clip.playbackRateAt(globalMs))
        .clamp(minTempoAutomationRate, maxTempoAutomationRate)
        .toDouble();
  }

  Future<void> _onClipCompleted(ClipCompletionEvent event) async {
    await _enqueueCommand(() => _handleClipCompleted(event));
  }

  Future<void> _handleClipCompleted(ClipCompletionEvent event) async {
    if (_queue.isEmpty) return;
    final clip = _clipForCompletion(event);
    if (clip == null || clip.timelineEndMs >= _engine.durationMs) return;
    if (event.wasSkipped) {
      _syncCurrentIndexFromGlobal(_engine.positionMs);
      _publishPosition(_engine.positionMs);
      _publishQueueState(includeQueue: false);
      return;
    }
    final completedQueueItemId = clip.queueItemId;
    final completedIndex = completedQueueItemId == null
        ? null
        : _cueTimeline.cueForQueueItemId(completedQueueItemId)?.queueIndex;
    if (completedIndex == null ||
        completedIndex < 0 ||
        completedIndex >= _queue.length) {
      return;
    }

    _currentIndex = completedIndex;
    _processingState = ProcessingState.completed;
    _publishPosition(clip.timelineEndMs);
    _publishQueueState(includeQueue: false);

    if (_loopMode == LoopMode.one) {
      await _skipToIndex(completedIndex);
      await _engine.play();
      return;
    }

    final next = _nextQueueIndexAfter(completedIndex);
    if (next != null) {
      _currentIndex = next;
      _processingState = ProcessingState.ready;
      _publishPosition(_engine.positionMs);
      _publishQueueState(includeQueue: false);
    }
  }

  Future<void> _onCompleted() async {
    await _enqueueCommand(_handleCompleted);
  }

  Future<void> _handleCompleted() async {
    if (_loopMode == LoopMode.one && _currentIndex != null) {
      await _skipToIndex(_currentIndex!);
      await _engine.play();
      return;
    }
    if (_loopMode == LoopMode.all && _queue.isNotEmpty) {
      await _skipToIndex(_playOrder.isEmpty ? 0 : _playOrder.first);
      await _engine.play();
      return;
    }
    _processingState = ProcessingState.completed;
    _publishPosition(_engine.positionMs);
    _publishPlayerState();
  }
}
