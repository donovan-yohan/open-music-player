import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../engine/playback_engine.dart';
import '../engine/timeline_model.dart';
import 'playback_media_item_source.dart';
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

  List<MediaItem> _queue = const [];
  List<int> _playOrder = const [];
  int? _currentIndex;
  bool _shuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  ProcessingState _processingState = ProcessingState.idle;
  bool _started = false;
  bool _suppressPositionSync = false;

  PlaybackEngine get engine => _engine;
  List<MediaItem> get queue => _queue;
  int? get currentIndex => _currentIndex;
  MediaItem? get currentMediaItem => _currentMediaItemSubject.valueOrNull;
  bool get shuffleEnabled => _shuffleEnabled;
  LoopMode get loopMode => _loopMode;
  Duration get position => _positionSubject.value;
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

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _engine.start();
  }

  Future<void> setQueue(List<MediaItem> items, {int initialIndex = 0}) async {
    await start();
    _queue = List.unmodifiable(items);
    _playOrder = [for (var i = 0; i < _queue.length; i++) i];
    _currentIndex = _queue.isEmpty
        ? null
        : initialIndex.clamp(0, _queue.length - 1).toInt();
    _processingState =
        _queue.isEmpty ? ProcessingState.idle : ProcessingState.ready;
    await _loadModel(seekToCurrent: true);
    _publishQueueState();
  }

  Future<void> addToQueue(MediaItem item) async {
    await insertIntoQueue(_queue.length, item);
  }

  Future<void> insertIntoQueue(int index, MediaItem item) async {
    final insertIndex = index.clamp(0, _queue.length).toInt();
    final previousCurrent = _currentIndex;
    final localPosition = _positionSubject.value.inMilliseconds;
    final nextQueue = List<MediaItem>.from(_queue)..insert(insertIndex, item);
    _queue = List.unmodifiable(nextQueue);
    if (previousCurrent == null) {
      _currentIndex = 0;
    } else if (insertIndex <= previousCurrent) {
      _currentIndex = previousCurrent + 1;
    }
    _rebuildPlayOrderKeepCurrent();
    _processingState = ProcessingState.ready;
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    _publishQueueState();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final previousCurrent = _currentIndex;
    final localPosition = _positionSubject.value.inMilliseconds;
    final nextQueue = List<MediaItem>.from(_queue)..removeAt(index);
    _queue = List.unmodifiable(nextQueue);
    if (_queue.isEmpty) {
      _currentIndex = null;
      _playOrder = const [];
      _processingState = ProcessingState.idle;
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
      await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    }
    _publishQueueState();
  }

  Future<void> play() async {
    if (_queue.isEmpty) return;
    await start();
    if (_processingState == ProcessingState.completed) {
      await skipToIndex(_currentIndex ?? 0);
    }
    _processingState = ProcessingState.ready;
    _publishPlayerState();
    await _engine.play();
  }

  Future<void> pause() async {
    await _engine.pause();
  }

  Future<void> stop() async {
    await _engine.pause();
    _processingState = ProcessingState.idle;
    _publishPlayerState();
  }

  Future<void> seek(Duration position) async {
    final globalMs = _globalForCurrentLocal(position.inMilliseconds);
    await _engine.seek(globalMs);
  }

  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
    final next = _nextQueueIndex();
    if (next == null) {
      if (_loopMode == LoopMode.one) {
        await skipToIndex(_currentIndex ?? 0);
      } else if (_loopMode == LoopMode.all) {
        await skipToIndex(_playOrder.isEmpty ? 0 : _playOrder.first);
      }
      return;
    }
    await skipToIndex(next);
  }

  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;
    final previous = _previousQueueIndex();
    await skipToIndex(previous ?? (_currentIndex ?? 0));
  }

  Future<void> skipToIndex(int index) async {
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
    if (_shuffleEnabled == enabled) return;
    final localPosition = _positionSubject.value.inMilliseconds;
    _shuffleEnabled = enabled;
    _rebuildPlayOrderKeepCurrent();
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    _publishQueueState();
  }

  Future<void> setLoopMode(LoopMode mode) async {
    _loopMode = mode;
    _loopModeSubject.add(mode);
  }

  Future<void> toggleShuffle() => setShuffleMode(!_shuffleEnabled);

  Future<void> cycleLoopMode() async {
    final modes = [LoopMode.off, LoopMode.all, LoopMode.one];
    final current = modes.indexOf(_loopMode);
    await setLoopMode(modes[(current + 1) % modes.length]);
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
    await _engine.dispose();
  }

  void _bind() {
    _subscriptions
      ..add(_engine.positionMsStream.listen(_onGlobalPosition))
      ..add(_engine.isPlayingStream.listen((_) => _publishPlayerState()))
      ..add(_engine.clock.completedStream.listen((_) => _onCompleted()));
  }

  Future<void> _loadModel({
    required bool seekToCurrent,
    int localPositionMs = 0,
  }) async {
    final ids = [for (final queueIndex in _playOrder) _queue[queueIndex].id];
    final model = TimelineModel.sequential(
      ids,
      sourceDurationMsFor: (_) => 0,
      sourceDurationMsForEntry: (_, sequenceIndex) {
        final queueIndex = _playOrder[sequenceIndex];
        return _queue[queueIndex].duration?.inMilliseconds ?? 0;
      },
      audioSourceRefFor: (_, sequenceIndex) {
        final queueIndex = _playOrder[sequenceIndex];
        return audioSourceUriForItem(_queue[queueIndex]).toString();
      },
      queueItemIdFor: (_, sequenceIndex) =>
          _playOrder[sequenceIndex].toString(),
      clipIdFor: (_, sequenceIndex) => 'queue_${_playOrder[sequenceIndex]}',
    );
    _suppressPositionSync = true;
    try {
      await _engine.loadMix(model);
      if (seekToCurrent && _currentIndex != null) {
        await _engine.seek(_globalForCurrentLocal(localPositionMs));
      }
    } finally {
      _suppressPositionSync = false;
    }
    _publishPosition(_engine.positionMs);
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
    _syncCurrentIndexFromGlobal(globalMs);
    _publishPosition(globalMs);
    _publishQueueState(includeQueue: false);
  }

  void _syncCurrentIndexFromGlobal(int globalMs) {
    final index = _queueIndexForGlobal(globalMs);
    if (index != null) _currentIndex = index;
  }

  int? _queueIndexForGlobal(int globalMs) {
    if (_queue.isEmpty || _playOrder.isEmpty) return null;
    final clips = _engine.model.clips;
    for (final clip in clips) {
      final queueIndex = int.tryParse(clip.queueItemId ?? '');
      if (queueIndex == null) continue;
      if (globalMs >= clip.timelineStartMs && globalMs < clip.timelineEndMs) {
        return queueIndex;
      }
    }
    if (_engine.durationMs > 0 && globalMs >= _engine.durationMs) {
      return _playOrder.last;
    }
    return _currentIndex ?? _playOrder.first;
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
  }

  Duration _durationForCurrentItem() {
    final index = _currentIndex;
    if (index == null || index < 0 || index >= _queue.length) {
      return Duration.zero;
    }
    return _queue[index].duration ?? Duration.zero;
  }

  int _localForGlobal(int globalMs) {
    final current = _currentIndex;
    if (current == null) return 0;
    final start = _clipStartForQueueIndex(current);
    final durationMs = _durationForCurrentItem().inMilliseconds;
    return (globalMs - start).clamp(0, durationMs).toInt();
  }

  int _globalForCurrentLocal(int localMs) {
    final current = _currentIndex;
    if (current == null) return 0;
    final durationMs = _durationForCurrentItem().inMilliseconds;
    return _clipStartForQueueIndex(current) +
        localMs.clamp(0, durationMs).toInt();
  }

  int _clipStartForQueueIndex(int queueIndex) {
    for (final clip in _engine.model.clips) {
      if (clip.queueItemId == queueIndex.toString()) {
        return clip.timelineStartMs;
      }
    }
    return 0;
  }

  int? _nextQueueIndex() {
    final current = _currentIndex;
    if (current == null) return null;
    final orderIndex = _playOrder.indexOf(current);
    if (orderIndex == -1 || orderIndex + 1 >= _playOrder.length) return null;
    return _playOrder[orderIndex + 1];
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
    _publishPlayerState();
  }

  void _publishPlayerState() {
    _playerStateSubject.add(PlayerState(_engine.isPlaying, _processingState));
  }

  Future<void> _onCompleted() async {
    if (_loopMode == LoopMode.one && _currentIndex != null) {
      await skipToIndex(_currentIndex!);
      await _engine.play();
      return;
    }
    if (_loopMode == LoopMode.all && _queue.isNotEmpty) {
      await skipToIndex(_playOrder.isEmpty ? 0 : _playOrder.first);
      await _engine.play();
      return;
    }
    _processingState = ProcessingState.completed;
    _publishPosition(_engine.positionMs);
    _publishPlayerState();
  }
}
