import 'dart:async';
import 'queue_ordering.dart';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../engine/playback_engine.dart';
import '../engine/native_playback_backend.dart';
import '../engine/tempo_automation.dart';
import '../engine/timeline_model.dart';
import '../../models/timeline_clip.dart';
import '../../models/stem_edits.dart';
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

  /// Fires when the mix clock runs off the end of a non-empty queue with repeat
  /// off. Deliberately not a [BehaviorSubject]: this is an event, and a late
  /// subscriber must not be handed a stale "the queue already ended".
  final StreamController<Object> _queueExhaustedController =
      StreamController<Object>.broadcast();
  Object? _exhaustion;
  int _continuationRevision = 0;

  bool _disposed = false;
  ContinuationDisposition _continuationDisposition =
      ContinuationDisposition.none;

  bool isCurrentExhaustion(Object event) =>
      !_disposed && identical(event, _exhaustion);

  void beginContinuation(Object event) {
    if (!isCurrentExhaustion(event)) return;
    _continuationDisposition = ContinuationDisposition.waiting;
    _publishSnapshot(_engine.positionMs);
  }

  void finishContinuation(Object event) {
    if (!isCurrentExhaustion(event)) return;
    _continuationDisposition = ContinuationDisposition.completed;
    _processingState = ProcessingState.completed;
    _publishPlayerState();
  }

  void cancelContinuation() {
    _exhaustion = null;
    _continuationRevision++;
    _continuationDisposition = ContinuationDisposition.none;
    if (!_disposed) _publishSnapshot(_engine.positionMs);
  }

  List<MediaItem> _queue = const [];
  List<int> _playOrder = const [];
  MixSession _session = MixSession.empty();
  CueTimeline _cueTimeline = CueTimeline.empty;
  int _sessionGeneration = 0;
  String _sessionId = 'session_0';
  int? _configuredDefaultCrossfadeMs;
  int? _currentIndex;
  bool _shuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  ProcessingState _processingState = ProcessingState.idle;
  bool _started = false;
  bool _suppressPositionSync = false;
  bool _nativeCandidatePending = false;
  bool _deferredLegacyDefaultCrossfadeAdoption = false;
  Future<void> _commandChain = Future<void>.value();
  // One active Jam's bounded, ephemeral admission history, not another queue.
  // Keep receipts/tombstones after row removal and queue replacement: neither
  // permits reapproval. Only a newly designated Jam ID resets this history.
  // Callers must retire old host identities monotonically (never revive an old
  // stillCurrent closure). Restart loses history; never auto-replay approvals.
  String? _jamAdmissionId;
  final Map<String, ({String trackId, String? receipt})> _jamAdmissions = {};

  PlaybackEngine get engine => _engine;
  MixSession get session => _session;

  /// Incarnation fence even when a saved mix reuses its persisted session ID.
  int get sessionGeneration => _sessionGeneration;

  /// The legacy voice renderer does not execute saved stem automation.
  /// Metadata acceptance must not be presented as audible replay.
  bool get hasUnsupportedStemEdits =>
      _session.clips.any((clip) => clip.stemEdits != null) &&
      !_engine.usesNativeBackend;
  List<MediaItem> get queue => _queue;
  int? get currentIndex => _currentIndex;
  MediaItem? get currentMediaItem => _currentMediaItemSubject.valueOrNull;
  bool get shuffleEnabled => _shuffleEnabled;
  LoopMode get loopMode => _loopMode;
  bool get canSkipNext =>
      _queue.isNotEmpty &&
      (_loopMode != LoopMode.off || _nextQueueIndex() != null);
  bool get canSkipPrevious =>
      _queue.isNotEmpty &&
      (_loopMode != LoopMode.off || _previousQueueIndex() != null);
  bool get hasPreviousInPlayOrder => _previousQueueIndex() != null;
  BeatSnapMode get transitionSnapMode => _session.transitionSnapMode;
  int get defaultCrossfadeMs => _session.defaultCrossfadeMs;
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

  /// Emits once each time playback runs past the last item of a non-empty queue
  /// with repeat off — the natural end of the queue (#352).
  ///
  /// This is the *only* path that emits, which is what makes it a trustworthy
  /// end-of-queue trigger: pause, stop, and skip never reach [_handleCompleted]
  /// (they pause the clock, and the clock only completes by playing past its
  /// duration), and the clock latches its own completion so a queue that sits
  /// finished cannot re-emit without playing again.
  Stream<Object> get queueExhaustedStream => _queueExhaustedController.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _engine.start();
  }

  /// Replaces the queue.
  ///
  /// When [preserveCurrentTransport] is true, the current index and live local
  /// position are captured inside this controller's serialized command. The
  /// caller-supplied [initialIndex] and [initialPosition] are ignored.
  Future<void> setQueue(
    List<MediaItem> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool preserveCurrentTransport = false,
    bool preserveTimelineEdits = false,
    int? reflowDefaultTransitionsFromIndex,
    MixSession? session,
  }) async {
    await _enqueueCommand(
      () => _setQueue(
        items,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
        preserveCurrentTransport: preserveCurrentTransport,
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
    bool preserveCurrentTransport = false,
    bool preserveTimelineEdits = false,
    int? reflowDefaultTransitionsFromIndex,
    MixSession? session,
  }) async {
    final previousTimeline = _cueTimeline;
    final previousModel = _engine.model;
    final wasPlaying = _engine.isPlaying;
    final previousCurrentIndex = _currentIndex;
    final previousLocalPositionMs = livePosition.inMilliseconds;
    final nextQueue = List<MediaItem>.unmodifiable(items);
    final nextPlayOrder = [for (var i = 0; i < nextQueue.length; i++) i];
    final nextSessionId =
        session?.sessionId ?? 'session_${_sessionGeneration + 1}';
    final transitionSnapMode =
        session?.transitionSnapMode ?? _session.transitionSnapMode;
    final defaultCrossfadeMs = _configuredDefaultCrossfadeMs ??
        session?.defaultCrossfadeMs ??
        _session.defaultCrossfadeMs;
    var deferredAdoption = _deferredLegacyDefaultCrossfadeAdoption;
    MixSession nextSession;
    if (session == null) {
      nextSession = preserveTimelineEdits
          ? _session.normalizedForQueue(nextQueue)
          : MixSession.fromQueue(
              sessionId: nextSessionId,
              queue: nextQueue,
              transitionSnapMode: transitionSnapMode,
              defaultCrossfadeMs: defaultCrossfadeMs,
            );
      if (!preserveTimelineEdits) deferredAdoption = false;
    } else {
      final normalizedSession = session.normalizedForQueue(nextQueue);
      if (wasPlaying &&
          normalizedSession.hasPendingLegacyDefaultCrossfadeAdoption) {
        nextSession =
            normalizedSession.deferLegacyDefaultCrossfadeMs(defaultCrossfadeMs);
        deferredAdoption = true;
      } else {
        nextSession =
            normalizedSession.withDefaultCrossfadeMs(defaultCrossfadeMs);
        deferredAdoption = false;
      }
    }
    if (reflowDefaultTransitionsFromIndex != null) {
      nextSession = nextSession
          .reflowDefaultTransitionsFrom(reflowDefaultTransitionsFromIndex);
    }
    if (nextQueue.isEmpty) {
      nextSession = MixSession.empty(
        sessionId: nextSessionId,
        transitionSnapMode: transitionSnapMode,
        defaultCrossfadeMs: defaultCrossfadeMs,
      );
      deferredAdoption = false;
    } else if ((session == null && !preserveTimelineEdits) ||
        reflowDefaultTransitionsFromIndex != null) {
      nextSession = _refineSessionRuntimeBeatAlignments(nextSession,
          queue: nextQueue, playOrder: nextPlayOrder);
    }
    // Build and validate the complete candidate before changing queue/session,
    // publishing snapshots, cancelling continuation, or touching the engine.
    final nextTimeline = CueTimeline.fromSession(
      session: nextSession,
      queue: nextQueue,
      playOrder: nextPlayOrder,
    );
    final nextModel = nextTimeline.toTimelineModel();
    final nativeLoaded = _engine.usesNativeBackend;
    if (nativeLoaded) {
      // Admit/ACK complete native candidate before publishing canonical state.
      final targetIndex =
          (preserveCurrentTransport ? previousCurrentIndex ?? 0 : initialIndex)
              .clamp(0, math.max(0, nextQueue.length - 1))
              .toInt();
      final cue = nextTimeline.cueForQueueIndex(targetIndex);
      final targetLocal = preserveCurrentTransport
          ? previousLocalPositionMs
          : initialPosition.inMilliseconds;
      final targetMs = cue == null
          ? 0
          : nextTimeline
              .globalFor(cue, Duration(milliseconds: targetLocal))
              .inMilliseconds;
      if (wasPlaying) {
        await _engine.replacePreparedMix(nextModel);
      } else {
        await _engine.loadPreparedMixAt(nextModel, targetMs);
      }
    }
    cancelContinuation();
    await start();
    _sessionGeneration += 1;
    _queue = nextQueue;
    _playOrder = nextPlayOrder;
    _sessionId = nextSessionId;
    _session = nextSession;
    _deferredLegacyDefaultCrossfadeAdoption = deferredAdoption;
    if (_queue.isEmpty) {
      _currentIndex = null;
      _cueTimeline = CueTimeline.empty;
      _processingState = ProcessingState.idle;
      await _engine.pause();
      await _engine.loadMix(nextModel);
      await _engine.seek(0);
      _publishQueueState();
      return;
    }
    final requestedInitialIndex = preserveCurrentTransport
        ? (previousCurrentIndex ?? 0).clamp(0, _queue.length - 1).toInt()
        : initialIndex.clamp(0, _queue.length - 1).toInt();
    final requestedLocalPositionMs = preserveCurrentTransport
        ? previousLocalPositionMs
        : initialPosition.inMilliseconds;
    _currentIndex = requestedInitialIndex;
    _processingState = ProcessingState.ready;
    final transportUnchanged = previousCurrentIndex == requestedInitialIndex &&
        previousLocalPositionMs == requestedLocalPositionMs;
    final metadataOnly = transportUnchanged &&
        _sameTimelinePlacementsAndSources(
          previousTimeline,
          nextTimeline,
        );
    final preserveActivePlayback = !metadataOnly &&
        transportUnchanged &&
        wasPlaying &&
        _soundingClipPlacementsUnchanged(previousModel, nextModel);
    _cueTimeline = nextTimeline;
    if (nativeLoaded) {
      _publishPosition(_engine.positionMs);
    } else if (metadataOnly) {
      _engine.replaceMixMetadata(nextModel);
      _publishPosition(_engine.positionMs);
    } else {
      await _loadModel(
        seekToCurrent: !preserveActivePlayback,
        localPositionMs: requestedLocalPositionMs,
        preserveActivePlayback: preserveActivePlayback,
      );
    }
    _currentIndex = requestedInitialIndex;
    _publishQueueState();
  }

  Future<void> addToQueue(MediaItem item) async {
    await _enqueueCommand(() => _insertIntoQueue(_queue.length, item));
  }

  Future<void> insertIntoQueue(int index, MediaItem item,
      {bool Function()? guard}) async {
    await _enqueueCommand(
        () => _insertAllIntoQueue(index, [item], guard: guard));
  }

  /// Inserts [items] contiguously at [index] in a single command, preserving
  /// their given order.
  ///
  /// The bulk form of [insertIntoQueue]. Looping it would rebuild the mix model
  /// — and re-run the O(queue) downbeat-alignment refinement — once per item,
  /// so a bulk add would cost a quadratic reload storm; it would also let a
  /// context tail sort itself between two items of the same batch, because each
  /// single insert recomputes where the *next* manual item belongs. Splice
  /// order here is the caller's order.
  Future<void> insertAllIntoQueue(int index, List<MediaItem> items,
      {bool Function()? guard}) async {
    if (items.isEmpty) return;
    await _enqueueCommand(
        () => _insertAllIntoQueue(index, items, guard: guard));
  }

  Future<void> _insertAllIntoQueue(int index, List<MediaItem> items,
      {bool appendOnly = false,
      bool Function()? guard,
      void Function()? beforeMutation}) async {
    if (items.isEmpty) return;
    await start();
    if (guard != null && !guard()) return;
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
    final nextQueue = List<MediaItem>.from(_queue)
      ..insertAll(insertIndex, items);
    final minimumStartMs = _exhaustion == null ? 0 : _engine.positionMs;
    var nextCurrentIndex = previousCurrent;
    if (previousCurrent == null) {
      nextCurrentIndex = 0;
    } else if (insertIndex <= previousCurrent) {
      nextCurrentIndex = previousCurrent + items.length;
    }
    final nextPlayOrder = _playOrderForInsert(
        insertIndex, items.length, nextQueue, nextCurrentIndex,
        appendOnly: appendOnly);
    var nextSession = _session
        .insertAllInPlayOrder(
          insertIndex,
          items,
          nextPlayOrder,
          minimumStartMs: minimumStartMs,
        )
        .normalizedForQueue(nextQueue);
    nextSession = _refineSessionRuntimeBeatAlignments(nextSession,
        queue: nextQueue, playOrder: nextPlayOrder);
    _validateSession(nextSession, queue: nextQueue, playOrder: nextPlayOrder);
    if (guard != null && !guard()) return;
    beforeMutation?.call();
    _queue = List.unmodifiable(nextQueue);
    _currentIndex = nextCurrentIndex;
    _playOrder = nextPlayOrder;
    _session = nextSession;
    _processingState = ProcessingState.ready;
    await _loadModel(
      seekToCurrent: !preserveActivePlayback,
      localPositionMs: localPosition,
      preserveActivePlayback: preserveActivePlayback,
    );
    _publishQueueState();
  }

  /// Appends one approved occurrence; source IO belongs outside this command.
  Future<String> admitJamRequest({
    required String jamId,
    required String requestId,
    required MediaItem item,
    required String expectedSessionId,
    required bool Function() stillCurrent,
  }) {
    final generation = _sessionGeneration;
    return _enqueueCommand(() async {
      if (jamId.trim().isEmpty ||
          jamId.length > 128 ||
          requestId.trim().isEmpty ||
          requestId.length > 128) {
        throw ArgumentError(
            'Jam and request IDs must be nonblank, at most 128 characters');
      }
      bool valid() =>
          !_disposed &&
          _sessionGeneration == generation &&
          _sessionId == expectedSessionId &&
          stillCurrent();
      if (!valid()) throw StateError('Jam admission is no longer current');
      if (_jamAdmissionId != jamId) {
        _jamAdmissions.clear();
        _jamAdmissionId = jamId;
      }
      final previous = _jamAdmissions[requestId];
      if (previous != null) {
        if (previous.trackId != item.id) {
          throw StateError('Jam request track changed');
        }
        final receipt = previous.receipt;
        if (receipt == null) {
          throw StateError('Jam admission outcome is uncertain; do not replay');
        }
        return receipt;
      }
      if (_jamAdmissions.length >= 50) {
        throw StateError('Jam admission capacity reached');
      }
      final index = _queue.length;
      await _insertAllIntoQueue(index, [item], appendOnly: true, guard: () {
        if (!valid()) {
          throw StateError('Jam admission is no longer current');
        }
        return true;
      }, beforeMutation: () {
        // From this point failures (including native rollback) are not
        // safe to automatically replay. Only a completed load confirms
        // the receipt. Keep uncertain markers within the same hard cap.
        _jamAdmissions[requestId] = (trackId: item.id, receipt: null);
      });
      if (!valid()) throw StateError('Jam admission is no longer current');
      final receipt = _session.clips[index].queueItemId;
      _jamAdmissions[requestId] = (trackId: item.id, receipt: receipt);
      return receipt;
    });
  }

  /// Appends [items] to the tail of the queue in a single command.
  ///
  /// This is the bulk, tail-only form of [insertIntoQueue]. Looping
  /// [insertIntoQueue] would be correct but rebuilds the mix model — and re-runs
  /// the O(queue) downbeat-alignment refinement — once per item, so a
  /// continuation batch would cost a quadratic reload storm. Unlike [setQueue]
  /// it preserves the existing play order and places the new tail after its
  /// actual chronological predecessor, not the last physical queue row.
  Future<void> appendToQueue(List<MediaItem> items) async {
    await _enqueueCommand(() => _appendToQueue(items));
  }

  /// IO stays outside serialization. Mutation and next-occurrence selection
  /// are one command, and user cancellation is rechecked after engine awaits.
  Future<void> continueExhaustedQueue(Object event, List<MediaItem> items,
          {required bool Function() stillCurrent}) =>
      _enqueueCommand(() async {
        bool valid() =>
            isCurrentExhaustion(event) &&
            stillCurrent() &&
            _session.continuationAllowed &&
            _loopMode == LoopMode.off;
        if (!valid()) return;
        final currentId = _session.clipAt(_currentIndex ?? -1)?.queueItemId;
        final pending = _nextQueueIndex();
        final pendingId =
            pending == null ? null : _session.clipAt(pending)?.queueItemId;
        final oldLength = _queue.length;
        await _appendToQueue(items, guard: valid);
        if (!valid()) return;
        final nextId = pendingId ?? _session.clipAt(oldLength)?.queueItemId;
        if (nextId == null || currentId == null) return;
        final next =
            _session.clips.indexWhere((clip) => clip.queueItemId == nextId);
        if (next < 0) return;
        await _skipToIndex(next);
        if (!valid()) return;
        await _engine.playGuarded(stillCurrent: valid);
        if (!valid()) return;
        _exhaustion = null;
        _continuationDisposition = ContinuationDisposition.none;
        _publishSnapshot(_engine.positionMs);
      });

  Future<void> _appendToQueue(List<MediaItem> items,
          {bool Function()? guard}) =>
      _insertAllIntoQueue(_queue.length, items, appendOnly: true, guard: guard);

  Future<void> _insertIntoQueue(int index, MediaItem item) =>
      _insertAllIntoQueue(index, [item]);

  Future<void> removeFromQueue(int index) async {
    await _enqueueCommand(() => _removeFromQueue(index));
  }

  Future<void> removeFromQueueByQueueItemId(String queueItemId) async {
    await _enqueueCommand(() async {
      final index = _queueIndexForQueueItemId(queueItemId);
      if (index == null) return;
      await _removeFromQueue(index);
    });
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
    var nextSession = _session.removeAt(index).normalizedForQueue(nextQueue);
    var nextCurrentIndex = previousCurrent;
    if (nextQueue.isEmpty) {
      nextCurrentIndex = null;
      // Do not recycle occurrence IDs when the last row is removed: Jam
      // receipts remain valid historical admissions within this session.
      nextSession = MixSession(
        sessionId: _sessionId,
        clips: const [],
        nextClipOrdinal: nextSession.nextClipOrdinal,
        transitionSnapMode: _session.transitionSnapMode,
        defaultCrossfadeMs:
            _configuredDefaultCrossfadeMs ?? _session.defaultCrossfadeMs,
      );
    } else if (previousCurrent == index) {
      nextCurrentIndex = math.min(index, nextQueue.length - 1);
    } else if (previousCurrent != null && index < previousCurrent) {
      nextCurrentIndex = previousCurrent - 1;
    }
    final nextPlayOrder = _playOrderKeepingCurrent(
        queueLength: nextQueue.length, currentIndex: nextCurrentIndex);
    nextSession = _refineSessionRuntimeBeatAlignments(nextSession,
        queue: nextQueue, playOrder: nextPlayOrder);
    _validateSession(nextSession, queue: nextQueue, playOrder: nextPlayOrder);
    _queue = List.unmodifiable(nextQueue);
    _session = nextSession;
    _currentIndex = nextCurrentIndex;
    _playOrder = nextPlayOrder;
    if (_queue.isEmpty) {
      _cueTimeline = CueTimeline.empty;
      _processingState = ProcessingState.idle;
      await _engine.pause();
      await _engine.loadMix(TimelineModel());
      await _engine.seek(0);
    } else {
      _processingState = ProcessingState.ready;
      await _loadModel(
        seekToCurrent: previousCurrent == index || !preserveActivePlayback,
        localPositionMs: previousCurrent == index ? 0 : localPosition,
        preserveActivePlayback:
            previousCurrent != index && preserveActivePlayback,
      );
    }
    _publishQueueState();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    await _enqueueCommand(() => _reorderQueue(oldIndex, newIndex));
  }

  Future<void> moveQueueItemByQueueItemId(
    String queueItemId,
    int delta,
  ) async {
    await _enqueueCommand(() async {
      if (delta == 0) return;
      final oldIndex = _queueIndexForQueueItemId(queueItemId);
      if (oldIndex == null || _queue.isEmpty) return;
      final newIndex = (oldIndex + delta).clamp(0, _queue.length - 1).toInt();
      await _reorderQueue(oldIndex, newIndex);
    });
  }

  Future<void> _reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    if (newIndex < 0 || newIndex >= _queue.length) return;

    final localPosition = livePosition.inMilliseconds;
    final nextQueue = List<MediaItem>.from(_queue);
    final item = nextQueue.removeAt(oldIndex);
    nextQueue.insert(newIndex, item);
    var nextCurrentIndex = _currentIndex;
    if (nextCurrentIndex == oldIndex) {
      nextCurrentIndex = newIndex;
    } else if (nextCurrentIndex != null &&
        oldIndex < nextCurrentIndex &&
        newIndex >= nextCurrentIndex) {
      nextCurrentIndex -= 1;
    } else if (nextCurrentIndex != null &&
        oldIndex > nextCurrentIndex &&
        newIndex <= nextCurrentIndex) {
      nextCurrentIndex += 1;
    }
    final nextPlayOrder = _playOrderKeepingCurrent(
        queueLength: nextQueue.length, currentIndex: nextCurrentIndex);
    var nextSession = _session
        .reorder(oldIndex, newIndex)
        .normalizedForQueue(nextQueue)
        .reflowedByOrder(nextPlayOrder);
    nextSession = _refineSessionRuntimeBeatAlignments(nextSession,
        queue: nextQueue, playOrder: nextPlayOrder);
    _validateSession(nextSession, queue: nextQueue, playOrder: nextPlayOrder);
    _queue = List.unmodifiable(nextQueue);
    _session = nextSession;
    _currentIndex = nextCurrentIndex;
    _playOrder = nextPlayOrder;
    _processingState = ProcessingState.ready;
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    _publishQueueState();
  }

  TimelineClip? timelineClipForIndex(int index) =>
      _session.clipAt(index)?.placement;

  int? _queueIndexForQueueItemId(String queueItemId) {
    if (queueItemId.isEmpty) return null;
    int? match;
    for (var index = 0; index < _queue.length; index++) {
      if (_session.clipAt(index)?.queueItemId != queueItemId) continue;
      if (match != null) return null;
      match = index;
    }
    return match;
  }

  Future<void> setTimelineStartMs(
    int index,
    int ms, {
    bool snapToDownbeat = true,
  }) async {
    await _enqueueCommand(
      () => _setTimelineStartMs(index, ms, snapToDownbeat: snapToDownbeat),
    );
  }

  Future<void> setTimelineStartMsByQueueItemId(
    String queueItemId,
    int ms, {
    bool snapToDownbeat = true,
  }) async {
    await _enqueueCommand(() async {
      final index = _queueIndexForQueueItemId(queueItemId);
      if (index == null) return;
      await _setTimelineStartMs(
        index,
        ms,
        snapToDownbeat: snapToDownbeat,
      );
    });
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

  Future<void> setSourceStartMsByQueueItemId(
    String queueItemId,
    int ms,
  ) async {
    await _enqueueCommand(() async {
      final index = _queueIndexForQueueItemId(queueItemId);
      if (index == null) return;
      await _setSourceStartMs(index, ms);
    });
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

  Future<void> setSourceEndMsByQueueItemId(
    String queueItemId,
    int ms,
  ) async {
    await _enqueueCommand(() async {
      final index = _queueIndexForQueueItemId(queueItemId);
      if (index == null) return;
      await _setSourceEndMs(index, ms);
    });
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

  Future<void> setPitchMode(int index, String pitchMode) async {
    await _enqueueCommand(() => _setPitchMode(index, pitchMode));
  }

  Future<void> setPitchModeByQueueItemId(
    String queueItemId,
    String pitchMode,
  ) async {
    await _enqueueCommand(() async {
      final index = _queueIndexForQueueItemId(queueItemId);
      if (index == null) return;
      await _setPitchMode(index, pitchMode);
    });
  }

  Future<void> _setPitchMode(int index, String pitchMode) async {
    if (index < 0 || index >= _queue.length) return;
    final normalized = normalizePitchMode(pitchMode);
    final current = _session.clipAt(index);
    if (current == null || current.pitchMode == normalized) return;

    final nextSession = _session.withPitchModeAt(index, normalized);
    _validateSession(nextSession);

    _session = nextSession.normalizedForQueue(_queue);
    await _loadModel(
      seekToCurrent: false,
      preserveActivePlayback: true,
    );
    _publishQueueState();
  }

  /// Saves metadata for exactly one queue occurrence; null explicitly clears it.
  /// The caller supplies real source identity, never a hash derived from trackId.
  /// This does not apply stem gains to the legacy renderer.
  Future<void> setStemEditsByQueueItemId(
    String queueItemId,
    StemEdits? edits, {
    required String expectedSourceFileHash,
  }) =>
      _enqueueCommand(() async {
        final index = _queueIndexForQueueItemId(queueItemId);
        if (index == null) {
          throw ArgumentError.value(queueItemId, 'queueItemId');
        }
        final current = _session.clips[index];
        final extras = _queue[index].extras;
        final sourceHash = extras?['sourceFileHash'] ??
            extras?['source_file_hash'] ??
            current.stemEdits?.sourceFileHash;
        if (!RegExp(r'^sha256:[0-9a-f]{64}$')
                .hasMatch(expectedSourceFileHash) ||
            sourceHash != expectedSourceFileHash ||
            (current.stemEdits != null &&
                current.stemEdits!.sourceFileHash != expectedSourceFileHash) ||
            (edits != null && edits.sourceFileHash != expectedSourceFileHash)) {
          throw StateError('Stem edit source identity is missing or changed.');
        }
        final nextSession = _session.withStemEditsAt(index, edits);
        if (identical(nextSession, _session)) return;
        _validateSession(nextSession);
        final nextTimeline = CueTimeline.fromSession(
          session: nextSession,
          queue: _queue,
          playOrder: _playOrder,
        );
        final nextModel = nextTimeline.toTimelineModel();
        // Stage admission before publication. Native applies and acknowledges
        // the full authored revision; legacy remains explicitly metadata-only.
        if (_engine.usesNativeBackend) {
          await _engine.replacePreparedMix(nextModel);
        } else {
          _engine.replaceMixMetadata(nextModel);
        }
        _session = nextSession;
        _cueTimeline = nextTimeline;
        _publishQueueState();
      });

  Future<StemGainAcknowledgement> setStemGain(
          String queueItemId, String channel, double gain, {int rampMs = 8}) =>
      _enqueueCommand(() =>
          _engine.setStemGain(queueItemId, channel, gain, rampMs: rampMs));

  Future<void> clearStemOverrides(String queueItemId) =>
      _enqueueCommand(() => _engine.clearStemOverrides(queueItemId));

  Future<void> setTransitionSnapMode(BeatSnapMode mode) async {
    await _enqueueCommand(() => _setTransitionSnapMode(mode));
  }

  Future<void> setDefaultCrossfadeMs(int value) async {
    final normalized = math.max(0, value);
    await _enqueueCommand(() async {
      await _setDefaultCrossfadeMs(normalized);
      _configuredDefaultCrossfadeMs = normalized;
    });
  }

  Future<void> _setDefaultCrossfadeMs(int value) async {
    if (_session.defaultCrossfadeMs == value) {
      final nextSession = _session.withDefaultCrossfadeMs(value);
      if (identical(nextSession, _session)) return;
      // Re-applying an unchanged default can still heal pre-#461
      // analysis-derived overlaps. Adopt that placement change before
      // publishing, so the live model and the canonical session agree.
      final placementsChanged = !_session.hasSameClipPlacementsAs(nextSession);
      if (placementsChanged && _queue.isNotEmpty) {
        _validateSession(nextSession);
      }
      _session = nextSession;
      if (placementsChanged && _queue.isNotEmpty) {
        _session = _session.normalizedForQueue(_queue);
        await _loadModel(
          seekToCurrent: false,
          preserveActivePlayback: true,
        );
      }
      _publishQueueState();
      return;
    }
    // Queue indices only describe timeline order for canonical playback.
    // Shuffled placement reflow is deferred until the next queue/order rebuild.
    // On a canonical timeline, protect every active clip: during the first half
    // of an overlap the outgoing clip can still be "current" while the incoming
    // clip is already sounding.
    var firstFutureIndex = _hasCanonicalPlayOrder
        ? _firstIndexAfterActiveAndCurrentClips()
        : _session.clips.length;
    final sourceSession =
        _session.withoutDeferredDefaultTransitionsBefore(firstFutureIndex);
    var nextSession = sourceSession.withDefaultCrossfadeMs(
      value,
      startIndex: firstFutureIndex,
    );
    final positionMs = _engine.positionMs;
    if (firstFutureIndex < _session.clips.length &&
        nextSession.clips[firstFutureIndex].timelineStartMs !=
            _session.clips[firstFutureIndex].timelineStartMs &&
        nextSession.clips[firstFutureIndex].timelineStartMs <= positionMs) {
      // Increasing overlap must not introduce a not-yet-active voice behind
      // the live playhead. Defer this transition and reflow the later prefix.
      final deferredSession =
          sourceSession.withDeferredDefaultTransitionAt(firstFutureIndex);
      firstFutureIndex += 1;
      nextSession = deferredSession.withDefaultCrossfadeMs(
        value,
        startIndex: firstFutureIndex,
      );
    }
    _validateSession(nextSession);

    _session = nextSession.normalizedForQueue(_queue);
    if (_queue.isNotEmpty) {
      await _loadModel(
        seekToCurrent: false,
        preserveActivePlayback: true,
      );
    }
    _publishQueueState();
  }

  bool get _hasCanonicalPlayOrder {
    if (_playOrder.length != _queue.length) return false;
    for (var index = 0; index < _playOrder.length; index++) {
      if (_playOrder[index] != index) return false;
    }
    return true;
  }

  int _firstIndexAfterActiveAndCurrentClips() {
    var protectedThrough = _currentIndex ?? -1;
    for (final active in _engine.model.activeClipsAt(_engine.positionMs)) {
      final queueItemId = active.queueItemId;
      final queueIndex = queueItemId == null
          ? _session.clips.indexWhere((clip) => clip.clipId == active.id)
          : _queueIndexForQueueItemId(queueItemId);
      if (queueIndex != null && queueIndex > protectedThrough) {
        protectedThrough = queueIndex;
      }
    }
    return protectedThrough + 1;
  }

  Future<void> _setTransitionSnapMode(BeatSnapMode mode) async {
    if (_session.transitionSnapMode == mode) return;
    var nextSession =
        _session.withTransitionSnapMode(mode).normalizedForQueue(_queue);
    nextSession = _refineSessionRuntimeBeatAlignments(nextSession);
    _validateSession(nextSession);

    final localPosition = livePosition.inMilliseconds;
    _session = nextSession;
    await _loadModel(
      seekToCurrent: true,
      localPositionMs: localPosition,
    );
    _publishQueueState();
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
    await _adoptDeferredLegacyDefaultCrossfade();
  }

  Future<void> stop() async {
    await _enqueueCommand(_stop);
  }

  Future<void> _stop() async {
    await _engine.pause();
    await _adoptDeferredLegacyDefaultCrossfade();
    _processingState = ProcessingState.idle;
    _publishPlayerState();
  }

  Future<void> _adoptDeferredLegacyDefaultCrossfade() async {
    if (!_deferredLegacyDefaultCrossfadeAdoption) return;
    final nextSession = _session
        .adoptDeferredLegacyDefaultCrossfade()
        .normalizedForQueue(_queue);
    _validateSession(nextSession);
    _deferredLegacyDefaultCrossfadeAdoption = false;
    _session = nextSession;
    if (_queue.isNotEmpty) {
      await _loadModel(
        seekToCurrent: false,
        preserveActivePlayback: true,
      );
    }
    _publishQueueState();
  }

  Future<void> seek(Duration position) async {
    await _enqueueCommand(() => _seek(position));
  }

  Future<void> _seek(Duration position) async {
    final globalMs = _globalForCurrentLocal(position.inMilliseconds);
    await _engine.seek(globalMs);
  }

  Future<void> beginLocalScrub() {
    if (_engine.usesNativeBackend) {
      // Drain an already-submitted gain ACK before scrub gates its only
      // consumer. Pausing first would strand that revision behind silence.
      return _enqueueCommand(() async => _engine.beginScrub());
    }
    _engine.beginScrub();
    return Future.value();
  }

  Future<void> updateTimelineScrub(int globalMs) {
    if (_engine.usesNativeBackend) {
      return _enqueueCommand(() async => _engine.updateScrub(globalMs));
    }
    _engine.updateScrub(globalMs);
    return Future.value();
  }

  Future<void> endTimelineScrub(int globalMs) =>
      _enqueueCommand(() => _engine.endScrub(globalMs));

  Future<void> updateLocalScrub(Duration position) {
    if (_engine.usesNativeBackend) {
      return _enqueueCommand(() async {
        _engine.updateScrub(_globalForCurrentLocal(position.inMilliseconds));
      });
    }
    final globalMs = _globalForCurrentLocal(position.inMilliseconds);
    _engine.updateScrub(globalMs);
    return Future.value();
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

  Future<bool> selectQueueItemByQueueItemId(String queueItemId) async {
    var activated = false;
    await _enqueueCommand(() async {
      final index = _queueIndexForQueueItemId(queueItemId);
      if (index == null) return;
      final active = _currentIndex == index &&
          _session.clipAt(index)?.queueItemId == queueItemId;
      if (!active) await _skipToIndex(index);
      activated = true;
    });
    return activated;
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
    final nextCurrentIndex =
        current != null && current >= 0 && current < _queue.length
            ? current
            : _currentIndex;
    final nextPlayOrder = _playOrderKeepingCurrent(
        queueLength: _queue.length,
        currentIndex: nextCurrentIndex,
        shuffleEnabled: enabled);
    final nextSession = _session.reflowedByOrder(nextPlayOrder);
    _validateSession(nextSession, playOrder: nextPlayOrder);
    _shuffleEnabled = enabled;
    _currentIndex = nextCurrentIndex;
    _playOrder = nextPlayOrder;
    _session = nextSession;
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
    if (_disposed) return;
    _disposed = true;
    cancelContinuation();
    await _commandChain;
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
    await _queueExhaustedController.close();
    await _engine.dispose();
  }

  void _bind() {
    _subscriptions
      ..add(_engine.positionMsStream.listen(_onGlobalPosition))
      ..add(_engine.isPlayingStream.listen((_) => _publishPlayerState()))
      ..add(
        _engine.clipCompletionStream.listen((event) {
          if (_suppressPositionSync || _disposed) return;
          unawaited(_onClipCompleted(event));
        }),
      )
      ..add(
        _engine.completedStream.listen((_) {
          if (_suppressPositionSync || _disposed) return;
          unawaited(_onCompleted());
        }),
      )
      ..add(_engine.runtimeStateStream
          .listen((_) => _publishSnapshot(_engine.positionMs)));
  }

  Future<T> _enqueueCommand<T>(Future<T> Function() command) {
    if (_disposed) {
      return Future.error(StateError('Playback controller disposed'));
    }
    final completer = Completer<T>();
    final next = _commandChain.then((_) async {
      // Native admission can await bytes and an audio-block ACK. Failed
      // candidates never become canonical queue/session state.
      final rollback = _engine.usesNativeBackend;
      _nativeCandidatePending = rollback;
      final queue = _queue, order = _playOrder;
      final session = _session, timeline = _cueTimeline;
      final index = _currentIndex, id = _sessionId;
      final processing = _processingState, shuffle = _shuffleEnabled;
      try {
        completer.complete(await command());
      } catch (error, stackTrace) {
        if (rollback) {
          _queue = queue;
          _playOrder = order;
          _session = session;
          _cueTimeline = timeline;
          _currentIndex = index;
          _sessionId = id;
          _processingState = processing;
          _shuffleEnabled = shuffle;
          _publishQueueState();
        }
        completer.completeError(error, stackTrace);
      } finally {
        _nativeCandidatePending = false;
        if (rollback && !_disposed) _publishQueueState();
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
      if (seekToCurrent &&
          _currentIndex != null &&
          !(_engine.usesNativeBackend && _engine.isPlaying)) {
        await _engine.seek(_globalForCurrentLocal(localPositionMs));
      }
    } finally {
      await Future<void>.delayed(Duration.zero);
      _suppressPositionSync = false;
    }
    _publishPosition(_engine.positionMs);
  }

  bool _sameTimelinePlacementsAndSources(
    CueTimeline previous,
    CueTimeline next,
  ) {
    if (previous.cues.length != next.cues.length) return false;
    for (var index = 0; index < previous.cues.length; index++) {
      final before = previous.cues[index];
      final after = next.cues[index];
      if (before.placement != after.placement ||
          before.queueItemId != after.queueItemId ||
          before.audioUri != after.audioUri ||
          before.playbackRate != after.playbackRate ||
          before.pitchMode != after.pitchMode) {
        return false;
      }
    }
    return true;
  }

  bool _soundingClipPlacementsUnchanged(
    TimelineModel previous,
    TimelineModel next,
  ) {
    final active = previous.activeClipsAt(_engine.positionMs);
    if (active.isEmpty) return false;
    for (final sounding in active) {
      MixClip? replacement;
      for (final candidate in next.clips) {
        if (candidate.id == sounding.id ||
            (sounding.queueItemId != null &&
                candidate.queueItemId == sounding.queueItemId)) {
          replacement = candidate;
          break;
        }
      }
      if (replacement == null || replacement.placement != sounding.placement) {
        return false;
      }
    }
    return true;
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
    _validateSession(nextSession);

    if (_engine.usesNativeBackend) {
      final nextTimeline = CueTimeline.fromSession(
          session: nextSession, queue: _queue, playOrder: _playOrder);
      await _engine.replacePreparedMix(nextTimeline.toTimelineModel());
      _session = nextSession.normalizedForQueue(_queue);
      _cueTimeline = nextTimeline;
      _publishQueueState();
      return;
    }
    final localPosition = livePosition.inMilliseconds;
    _session = nextSession.normalizedForQueue(_queue);
    await _loadModel(seekToCurrent: true, localPositionMs: localPosition);
    _publishQueueState();
  }

  void _validateSession(
    MixSession session, {
    List<MediaItem>? queue,
    List<int>? playOrder,
  }) {
    CueTimeline.fromSession(
      session: session,
      queue: queue ?? _queue,
      playOrder: playOrder ?? _playOrder,
    ).toTimelineModel();
  }

  bool _canApplySession(
    MixSession session, {
    List<MediaItem>? queue,
    List<int>? playOrder,
  }) {
    try {
      _validateSession(session, queue: queue, playOrder: playOrder);
      return true;
    } on StateError {
      // Automatic beat-alignment proposals may be declined; authored commands
      // use _validateSession directly so their rejection is explicit.
      return false;
    }
  }

  List<int> _playOrderForInsert(
      int index, int count, List<MediaItem> nextQueue, int? nextCurrentIndex,
      {bool appendOnly = false}) {
    if (!_shuffleEnabled || _playOrder.isEmpty) {
      return [for (var i = 0; i < nextQueue.length; i++) i];
    }
    final order = [
      for (final old in _playOrder) old >= index ? old + count : old
    ];
    var slot = order.length;
    if (!appendOnly &&
        nextQueue
            .skip(index)
            .take(count)
            .every((item) => itemOrigin(item) == queueOriginManual)) {
      slot = order.indexOf(nextCurrentIndex!) + 1;
      while (slot < order.length &&
          order[slot] < index &&
          itemOrigin(nextQueue[order[slot]]) == queueOriginManual) {
        slot++;
      }
    } else if (!appendOnly && index + count < nextQueue.length) {
      slot = order.indexOf(index + count);
    }
    order.insertAll(slot, [for (var i = 0; i < count; i++) index + i]);
    return order;
  }

  void _rebuildPlayOrderKeepCurrent() {
    _playOrder = _playOrderKeepingCurrent(
        queueLength: _queue.length, currentIndex: _currentIndex);
  }

  List<int> _playOrderKeepingCurrent({
    required int queueLength,
    required int? currentIndex,
    bool? shuffleEnabled,
  }) {
    // Explicit mode changes may reshuffle; insertion must not replay history.
    if (queueLength == 0) return const [];
    final current = (currentIndex ?? 0).clamp(0, queueLength - 1).toInt();
    if (shuffleEnabled ?? _shuffleEnabled) {
      return shufflePermutation(queueLength, current, random: _shuffleRandom);
    }
    return [for (var i = 0; i < queueLength; i++) i];
  }

  void _onGlobalPosition(int globalMs) {
    if (_suppressPositionSync || _nativeCandidatePending) return;
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
    if (_nativeCandidatePending) return;
    final localMs = _localForGlobal(globalMs);
    final position = Duration(milliseconds: localMs);
    final duration = _durationForCurrentItem();
    final mediaItem = _currentIndex == null ? null : _queue[_currentIndex!];
    _positionSubject.add(position);
    // Only the position actually moves on a steady UI tick. Republishing the
    // unchanged duration and media item costs a listener notification each,
    // and every `PlaybackState` watcher on screen rebuilds per notification —
    // so an idle tick used to cost 4x the widget work it needs to.
    if (_bufferedPositionSubject.value != duration) {
      _bufferedPositionSubject.add(duration);
    }
    if (_durationSubject.value != duration) {
      _durationSubject.add(duration);
    }
    if (!identical(_currentMediaItemSubject.value, mediaItem)) {
      _currentMediaItemSubject.add(mediaItem);
    }
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

  /// The queue index that plays after [queueIndex], or null at the end of the
  /// play order.
  ///
  /// Public because "what comes next" is a play-order question and only this
  /// controller knows the play order: under shuffle, queue index + 1 is a
  /// different track than the one that will actually play.
  int? nextQueueIndexInPlayOrder(int queueIndex) =>
      _nextQueueIndexAfter(queueIndex);

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
      outgoingBaseRate: outgoing.playbackRate,
      incomingBaseRate: incoming.playbackRate,
      snapMode: _session.transitionSnapMode,
      toleranceMs: downbeatSnapToleranceMs(
        outgoing.tempo,
        snapMode: _session.transitionSnapMode,
        baseRate: outgoing.playbackRate,
      ),
    );
    if (snappedStart == null) return requested;
    return _refineRuntimeBeatAlignment(
      index,
      requested.withTimelineStartMs(snappedStart),
    );
  }

  TimelineClip _refineRuntimeBeatAlignment(
    int index,
    TimelineClip initialPlacement, {
    MixSession? baseSession,
  }) {
    final previousIndex = _previousQueueIndexFor(index);
    if (previousIndex == null) return initialPlacement;
    final sourceSession = baseSession ?? _session;
    var placement = initialPlacement;

    for (var attempt = 0; attempt < 8; attempt++) {
      final candidateSession = sourceSession.withPlacementAt(
        index,
        placement,
        markExplicit: false,
      );
      final candidateModel = CueTimeline.fromSession(
        session: candidateSession,
        queue: _queue,
        playOrder: _playOrder,
      ).toTimelineModel();
      final incomingSessionClip = candidateSession.clipAt(index);
      final outgoingSessionClip = candidateSession.clipAt(previousIndex);
      if (incomingSessionClip == null || outgoingSessionClip == null) {
        return placement;
      }
      final incoming = _modelClipForSessionClip(
        candidateModel,
        incomingSessionClip,
      );
      final outgoing = _modelClipForSessionClip(
        candidateModel,
        outgoingSessionClip,
      );
      if (incoming == null || outgoing == null) return placement;
      final correctionMs = beatAlignmentCorrectionMs(
        outgoing: outgoing,
        incoming: incoming,
        snapMode: candidateSession.transitionSnapMode,
      );
      if (correctionMs == null) return placement;
      if (correctionMs.abs() <= 1) return placement;
      final correctedStartMs = math.max(
        0,
        placement.timelineStartMs + correctionMs,
      );
      if (correctedStartMs == placement.timelineStartMs) return placement;
      placement = placement.withTimelineStartMs(correctedStartMs);
    }

    return placement;
  }

  MixSession _refineSessionRuntimeBeatAlignments(
    MixSession session, {
    List<MediaItem>? queue,
    List<int>? playOrder,
  }) {
    final candidateQueue = queue ?? _queue;
    final candidateOrder = playOrder ?? _playOrder;
    if (session.transitionSnapMode == BeatSnapMode.free ||
        candidateOrder.length < 2) {
      return session;
    }

    var refined = session;
    for (var attempt = 0; attempt < 8; attempt++) {
      final model = CueTimeline.fromSession(
        session: refined,
        queue: candidateQueue,
        playOrder: candidateOrder,
      ).toTimelineModel();
      final clipsById = <String, MixClip>{
        for (final clip in model.clips) clip.id: clip,
      };
      final clipsByQueueItemId = <String, MixClip>{
        for (final clip in model.clips)
          if (clip.queueItemId != null) clip.queueItemId!: clip,
      };
      final updates = <(int, TimelineClip)>[];

      for (var orderIndex = 1;
          orderIndex < candidateOrder.length;
          orderIndex++) {
        final index = candidateOrder[orderIndex];
        final previousIndex = candidateOrder[orderIndex - 1];
        final incomingSessionClip = refined.clipAt(index);
        final outgoingSessionClip = refined.clipAt(previousIndex);
        if (incomingSessionClip == null || outgoingSessionClip == null) {
          continue;
        }
        final incoming = clipsById[incomingSessionClip.clipId] ??
            clipsByQueueItemId[incomingSessionClip.queueItemId];
        final outgoing = clipsById[outgoingSessionClip.clipId] ??
            clipsByQueueItemId[outgoingSessionClip.queueItemId];
        if (incoming == null || outgoing == null) continue;
        final correctionMs = beatAlignmentCorrectionMs(
          outgoing: outgoing,
          incoming: incoming,
          snapMode: refined.transitionSnapMode,
        );
        if (correctionMs == null || correctionMs.abs() <= 1) continue;
        final correctedStartMs = math.max(
          0,
          incomingSessionClip.timelineStartMs + correctionMs,
        );
        if (correctedStartMs == incomingSessionClip.timelineStartMs) continue;
        updates.add((
          index,
          incomingSessionClip.placement.withTimelineStartMs(correctedStartMs),
        ));
      }

      if (updates.isEmpty) return refined;
      var candidate = refined;
      for (final (index, placement) in updates) {
        candidate = candidate.withPlacementAt(
          index,
          placement,
          markExplicit: false,
        );
      }
      if (_canApplySession(candidate,
          queue: candidateQueue, playOrder: candidateOrder)) {
        refined = candidate;
        continue;
      }

      // Retain independent valid corrections if a combined update conflicts.
      var fallback = refined;
      for (final (index, placement) in updates) {
        final next = fallback.withPlacementAt(
          index,
          placement,
          markExplicit: false,
        );
        if (_canApplySession(next,
            queue: candidateQueue, playOrder: candidateOrder)) {
          fallback = next;
        }
      }
      if (identical(fallback, refined)) return refined;
      refined = fallback;
    }
    return refined;
  }

  MixClip? _modelClipForSessionClip(
    TimelineModel model,
    MixSessionClip sessionClip,
  ) {
    for (final clip in model.clips) {
      if (clip.id == sessionClip.clipId ||
          clip.queueItemId == sessionClip.queueItemId) {
        return clip;
      }
    }
    return null;
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
    if (_nativeCandidatePending) return;
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
    if (_nativeCandidatePending) return;
    _playerStateSubject.add(PlayerState(_engine.isPlaying, _processingState));
    _publishSnapshot(_engine.positionMs);
  }

  void _publishSnapshot(int globalMs) {
    if (_nativeCandidatePending) return;
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
        continuationDisposition: _continuationDisposition,
        playing: _engine.isPlaying,
        processingState: _processingState,
        activeVoiceCount: _engine.activeVoiceCount,
        playbackSpeed: _playbackSpeedForGlobal(globalMs),
        pitchPreservationFallback: _engine.hasPitchFallback,
        pitchFallbackClipIds: _engine.pitchFallbackClipIds,
        clipTempoStates: _clipTempoStatesForGlobal(globalMs),
      ),
    );
  }

  Map<String, ClipTempoRuntimeState> _clipTempoStatesForGlobal(int globalMs) {
    final pitchFallbacks = _engine.pitchFallbackClipIds;
    return Map.unmodifiable({
      for (final clip in _engine.activeClips)
        clip.id: _clipTempoStateForGlobal(
          clip,
          globalMs,
          pitchFallback: pitchFallbacks.contains(clip.id),
        ),
    });
  }

  ClipTempoRuntimeState _clipTempoStateForGlobal(
    MixClip clip,
    int globalMs, {
    required bool pitchFallback,
  }) {
    final speed = (_engine.clock.rate * clip.playbackRateAt(globalMs))
        .clamp(minTempoAutomationRate, maxTempoAutomationRate)
        .toDouble();
    final nativeBpm = clip.tempo.nativeBpm;
    return ClipTempoRuntimeState(
      clipId: clip.id,
      effectiveSpeed: speed,
      nativeBpm: nativeBpm,
      effectiveBpm: nativeBpm == null
          ? null
          : clip.effectiveBpmAt(globalMs, transportRate: _engine.clock.rate),
      pitchMode: clip.rateAutomation.pitchMode,
      pitchFallback: pitchFallback,
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
    if (_disposed || _queue.isEmpty) return;
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
    final revision = _continuationRevision;
    final session = _session;
    await _enqueueCommand(() async {
      if (_disposed ||
          revision != _continuationRevision ||
          !identical(session, _session)) {
        return;
      }
      await _handleCompleted();
    });
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
    _continuationDisposition = ContinuationDisposition.completed;
    _processingState = ProcessingState.completed;
    _syncCurrentIndexFromGlobal(_engine.positionMs);
    _publishQueueState(includeQueue: false);
    // The queue is published as completed *before* the notification so a
    // listener that declines to continue leaves the historical silent-stop
    // behavior exactly as it was.
    if (_queue.isNotEmpty && !_queueExhaustedController.isClosed) {
      final event = Object();
      _exhaustion = event;
      _queueExhaustedController.add(event);
    }
  }
}
