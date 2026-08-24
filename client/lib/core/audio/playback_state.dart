import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../cache/playback_cache_manager.dart';
import '../engine/click_audition_projection.dart';
import '../engine/click_auditioner.dart';
import '../engine/playback_engine.dart';
import '../engine/tempo_automation.dart';
import '../engine/timeline_model.dart';
import '../../models/mix_plan.dart';
import '../../models/timeline_clip.dart';
import '../../models/track_analysis.dart';
import '../../models/trim_range.dart';
import '../models/settings_model.dart';
import 'audio_focus_playback.dart';
import 'queue_continuation.dart';
import 'local_audio_artifact_resolver.dart';
import 'playback_media_item_source.dart';
import 'playback_session.dart';
import 'playback_context.dart';
import 'playback_source_resolver.dart';
import 'queue_timeline_controller.dart';
import 'queue_ordering.dart';
import 'queue_persistence.dart';
import 'signed_audio_url_service.dart';

class AudioPlaybackDefaults {
  const AudioPlaybackDefaults({this.defaultCrossfadeMs = 0});

  final int defaultCrossfadeMs;
}

class PlaybackState extends ChangeNotifier implements AudioFocusPlayback {
  final QueueTimelineController _queueController;
  final SignedAudioUrlService _signedAudioUrlService;
  final PlaybackSourceResolver _sourceResolver;

  /// Local store for the resumable queue snapshot. Null disables persistence
  /// entirely (used in tests and on platforms without a store), keeping every
  /// save/restore a no-op.
  final QueuePersistenceStore? _persistence;

  /// A configured store must be restored before seeded queue-stream emissions
  /// are allowed to write. Otherwise a fresh controller can erase the durable
  /// snapshot before [restore] reads it.
  bool _persistenceReady;
  bool _persistenceDirty = false;
  bool _receivedInitialQueueEmission = false;
  bool _receivedInitialIndexEmission = false;
  bool _receivedInitialShuffleEmission = false;
  bool _receivedInitialLoopModeEmission = false;
  final Duration _persistenceDebounce;
  Timer? _persistenceTimer;

  List<StreamSubscription> _subscriptions = [];

  bool _isPlaying = false;
  bool _shuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  String? _playbackError;
  bool _isResolvingSignedUrl = false;
  PlaybackContext? _playbackContext;

  /// Monotonic user intent token for direct playback replacement.
  ///
  /// Direct play resolves URLs asynchronously. If the user taps B while A is
  /// playing, A must stop immediately; and if the user then pauses/stops before
  /// B finishes resolving, that stale pending request must not auto-start B.
  int _playRequestGeneration = 0;
  int _transportCommandGeneration = 0;

  /// End-of-queue continuation (#352). The source is injected so the playback
  /// core never learns about the library API; a null source (tests, or a build
  /// without a continuation wired up) makes the feature inert regardless of the
  /// selected mode.
  final QueueContinuationSource? _continuationSource;
  final int _continuationBatchSize;
  EndOfQueueMode _endOfQueueMode = EndOfQueueMode.off;

  /// Guards against a second continuation starting while one is still fetching
  /// or appending. The controller emits at most one exhaustion per completion,
  /// but the fetch is async and an appended batch can itself finish quickly.
  bool _continuationInFlight = false;

  @override
  bool get isPlaying => _queueController.snapshot.playing;
  @override
  int get transportCommandGeneration => _transportCommandGeneration;
  Duration get position => _queueController.snapshot.localPosition;
  Duration get bufferedPosition => _queueController.bufferedPosition;
  Duration get duration => _queueController.snapshot.localDuration;
  MediaItem? get currentItem => _queueController.snapshot.currentMediaItem;
  List<MediaItem> get queue => _queueController.queue;
  int? get currentIndex => _queueController.currentIndex;
  bool get shuffleEnabled => _shuffleEnabled;
  LoopMode get loopMode => _loopMode;
  bool get canSkipNext => _queueController.canSkipNext;
  bool get canSkipPrevious => _queueController.canSkipPrevious;
  bool get hasPreviousInPlayOrder => _queueController.hasPreviousInPlayOrder;
  bool get hasTrack => currentItem != null;
  String? get playbackError => _playbackError;
  bool get isResolvingSignedUrl => _isResolvingSignedUrl;

  /// Where the current listening queue was launched from (album, playlist, ...),
  /// or null when the queue was started without a context. Drives the
  /// "Playing from <label>" attribution in the mini/full player.
  PlaybackContext? get playbackContext => _playbackContext;

  /// Raw playback streams, exposed so the play-event recorder can observe
  /// position/track-change/completion without reaching into the mix engine
  /// directly. These synthesize the previous just_audio stream contract from
  /// the engine-backed queue timeline.
  Stream<Duration> get positionStream => _queueController.positionStream;
  Stream<MediaItem?> get currentMediaItemStream =>
      _queueController.currentMediaItemStream;
  Stream<PlayerState> get playerStateStream =>
      _queueController.playerStateStream;
  ValueStream<PlaybackSnapshot> get snapshotStream =>
      _queueController.snapshotStream;

  /// Shuffle/repeat are queue-mode facts rather than snapshot facts, so OS
  /// media-session surfaces observe them separately from [snapshotStream].
  Stream<bool> get shuffleEnabledStream =>
      _queueController.shuffleEnabledStream;
  Stream<LoopMode> get loopModeStream => _queueController.loopModeStream;
  PlaybackSnapshot get snapshot => _queueController.snapshot;

  /// Live global mix timeline state for the waveform surface. This is the raw
  /// engine clock/model contract, not the source-relative player position.
  Stream<int> get timelinePositionMsStream =>
      _queueController.engine.positionMsStream;
  int get timelinePositionMs => _queueController.engine.positionMs;
  TimelineModel get timelineModel => _queueController.engine.model;
  int? sourcePositionMsForQueueItemId(String queueItemId) {
    final clip = uniqueMixClipForQueueItemId(timelineModel, queueItemId);
    if (clip == null || !clip.isActiveAt(timelinePositionMs)) return null;
    return clip.sourcePositionAt(timelinePositionMs);
  }

  ClickAuditionLease openClickAudition(ClickAuditionRequest request) =>
      _queueController.engine.openClickAudition(request);
  BeatSnapMode get transitionSnapMode => _queueController.transitionSnapMode;
  int get defaultCrossfadeMs => _queueController.defaultCrossfadeMs;
  TimelineClip? timelineClipForQueueIndex(int index) =>
      _queueController.timelineClipForIndex(index);
  TrimRange trimRangeForQueueIndex(int index) {
    final clip = _queueController.timelineClipForIndex(index);
    final item = index >= 0 && index < queue.length ? queue[index] : null;
    final durationMs = item?.duration?.inMilliseconds ?? 0;
    if (clip == null) return TrimRange.full(durationMs);
    return TrimRange.clamped(
      trackDurationMs: durationMs,
      startOffsetMs: clip.sourceStartMs,
      endOffsetMs: clip.sourceEndMs,
    );
  }

  Future<void> setQueueTimelineStartMs(
    int index,
    int ms, {
    bool snapToDownbeat = true,
  }) =>
      _queueController.setTimelineStartMs(
        index,
        ms,
        snapToDownbeat: snapToDownbeat,
      );
  Future<void> setQueueTimelineStartMsByQueueItemId(
    String queueItemId,
    int ms, {
    bool snapToDownbeat = true,
  }) =>
      _queueController.setTimelineStartMsByQueueItemId(
        queueItemId,
        ms,
        snapToDownbeat: snapToDownbeat,
      );
  Future<void> setQueueTrimStartMs(int index, int ms) =>
      _queueController.setSourceStartMs(index, ms);
  Future<void> setQueueTrimStartMsByQueueItemId(
    String queueItemId,
    int ms,
  ) =>
      _queueController.setSourceStartMsByQueueItemId(queueItemId, ms);
  Future<void> setQueueTrimEndMs(int index, int ms) =>
      _queueController.setSourceEndMs(index, ms);
  Future<void> setQueueTrimEndMsByQueueItemId(
    String queueItemId,
    int ms,
  ) =>
      _queueController.setSourceEndMsByQueueItemId(queueItemId, ms);
  Future<void> setQueuePitchMode(int index, String pitchMode) =>
      _queueController.setPitchMode(index, pitchMode);
  Future<void> setQueuePitchModeByQueueItemId(
    String queueItemId,
    String pitchMode,
  ) =>
      _queueController.setPitchModeByQueueItemId(queueItemId, pitchMode);
  Future<void> setTransitionSnapMode(BeatSnapMode mode) =>
      _queueController.setTransitionSnapMode(mode);
  Future<void> applyAudioDefaults(AudioPlaybackDefaults defaults) =>
      _queueController.setDefaultCrossfadeMs(defaults.defaultCrossfadeMs);
  Future<void> reorderPlaybackQueue(int oldIndex, int newIndex) =>
      _queueController.reorderQueue(oldIndex, newIndex);
  Future<void> movePlaybackQueueItemByQueueItemId(
    String queueItemId,
    int delta,
  ) =>
      _queueController.moveQueueItemByQueueItemId(queueItemId, delta);

  void beginTimelineScrub() => _queueController.engine.beginScrub();
  void updateTimelineScrub(int globalMs) =>
      _queueController.engine.updateScrub(globalMs);
  Future<void> endTimelineScrub(int globalMs) =>
      _queueController.engine.endScrub(globalMs);

  PlaybackState(
    PlaybackEngine engine, {
    required SignedAudioUrlService signedAudioUrlService,
    LocalAudioArtifactResolver? localResolver,
    PlaybackCacheManager? cacheManager,
    QueuePersistenceStore? persistence,
    Future<String?> Function()? accountIdProvider,
    QueueContinuationSource? continuationSource,
    int continuationBatchSize = defaultQueueContinuationBatchSize,
    Duration persistenceDebounce = const Duration(milliseconds: 500),
  })  : _queueController = QueueTimelineController(engine),
        _signedAudioUrlService = signedAudioUrlService,
        _persistence = persistence,
        _persistenceReady = persistence == null,
        _persistenceDebounce = persistenceDebounce,
        _continuationSource = continuationSource,
        _continuationBatchSize = continuationBatchSize,
        _sourceResolver = PlaybackSourceResolver(
          signedAudioUrlService: signedAudioUrlService,
          localResolver: localResolver,
          cacheManager: cacheManager,
          accountIdProvider: accountIdProvider,
        ) {
    _init();
  }

  void _init() {
    _subscriptions = [
      _queueController.playerStateStream.listen((state) {
        final wasPlaying = _isPlaying;
        _isPlaying = state.playing;
        // Persist the resting position whenever playback pauses so a resume
        // picks up where the listener left off. Pause is rare and
        // user-initiated, so flush immediately instead of waiting out the
        // debounce — a process kill right after pausing must not lose it.
        if (wasPlaying && !_isPlaying) {
          _persistQueue();
          _flushPersistence();
        }
        notifyListeners();
      }),
      _queueController.positionStream.listen((pos) {
        notifyListeners();
      }),
      _queueController.bufferedPositionStream.listen((pos) {
        notifyListeners();
      }),
      _queueController.durationStream.listen((dur) {
        notifyListeners();
      }),
      _queueController.currentMediaItemStream.listen((item) {
        notifyListeners();
      }),
      _queueController.queueStream.listen((q) {
        final isStartupSeed = !_receivedInitialQueueEmission;
        _receivedInitialQueueEmission = true;
        _persistQueue(isStartupSeed: isStartupSeed);
        notifyListeners();
      }),
      _queueController.currentIndexStream.listen((index) {
        final isStartupSeed = !_receivedInitialIndexEmission;
        _receivedInitialIndexEmission = true;
        _persistQueue(isStartupSeed: isStartupSeed);
        notifyListeners();
      }),
      _queueController.shuffleEnabledStream.listen((enabled) {
        final isStartupSeed = !_receivedInitialShuffleEmission;
        _receivedInitialShuffleEmission = true;
        _shuffleEnabled = enabled;
        _persistQueue(isStartupSeed: isStartupSeed);
        notifyListeners();
      }),
      _queueController.loopModeStream.listen((mode) {
        final isStartupSeed = !_receivedInitialLoopModeEmission;
        _receivedInitialLoopModeEmission = true;
        _loopMode = mode;
        _persistQueue(isStartupSeed: isStartupSeed);
        notifyListeners();
      }),
      _queueController.queueExhaustedStream.listen((_) {
        unawaited(_handleQueueExhausted());
      }),
    ];
  }

  /// The selected end-of-queue behavior (#352). Pushed in from the settings
  /// screen — the playback core never reads preferences itself, mirroring how
  /// crossfade arrives via [applyAudioDefaults].
  EndOfQueueMode get endOfQueueMode => _endOfQueueMode;

  void setEndOfQueueMode(EndOfQueueMode mode) {
    _endOfQueueMode = mode;
  }

  /// Continues playback past the natural end of the queue.
  ///
  /// Runs only for a natural completion: [QueueTimelineController]
  /// .queueExhaustedStream is fed exclusively by the repeat-off completion path,
  /// so a manual stop, pause, or skip never reaches here.
  ///
  /// Every failure degrades to the historical silent stop. The listener did not
  /// ask for this fetch, so an offline library must not raise a
  /// [playbackError] or a toast — the queue simply ends, exactly as it did
  /// before the feature existed.
  Future<void> _handleQueueExhausted() async {
    if (_endOfQueueMode == EndOfQueueMode.off) return;
    if (_continuationInFlight) return;
    final source = _continuationSource;
    if (source == null) return;
    final exhaustedQueue = queue;
    if (exhaustedQueue.isEmpty) return;

    _continuationInFlight = true;
    final playGeneration = _playRequestGeneration;
    final transportGeneration = _transportCommandGeneration;
    // Anything the user does while the batch is in flight (play, pause, stop,
    // skip, starting a different queue) wins: an appended batch that lands
    // afterwards would hijack a session the listener already redirected.
    bool stillCurrent() =>
        playGeneration == _playRequestGeneration &&
        transportGeneration == _transportCommandGeneration;

    try {
      final tracks = await source.fetch(
        // Exclude everything already in the queue so a continuation never
        // replays what the listener just heard. Once the source has nothing
        // left to offer it returns empty and playback stops, which is the
        // honest end of a shuffled library pass.
        excludeTrackIds: {for (final item in exhaustedQueue) item.id},
        limit: _continuationBatchSize,
      );
      if (tracks.isEmpty || !stillCurrent()) return;

      final resolved = await _sourceResolver.resolveQueue(tracks);
      if (resolved.isEmpty || !stillCurrent()) return;

      final appendIndex = queue.length;
      await _queueController.appendToQueue([
        for (final item in resolved) markOrigin(item, queueOriginContinuation),
      ]);
      // Accepted asymmetry, not a race to "fix": a generation change landing
      // between the append and this check leaves the batch in the queue while
      // the skip and play below are abandoned. That is the intended graceful
      // degradation — the append is an additive tail insert that keeps session
      // placements, so the worst outcome is a labelled auto-continuation
      // segment sitting unplayed after whatever the listener redirected to.
      // Rolling it back would mean mutating a queue the user is now driving,
      // which is strictly worse than leaving a visible, removable tail.
      if (!stillCurrent()) return;
      await _queueController.skipToIndex(appendIndex);
      if (!stillCurrent()) return;
      // Straight to the controller: PlaybackState.play() would bump the
      // transport generation and cancel the guard we are still holding.
      await _queueController.play();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('End-of-queue continuation skipped: $error');
      }
    } finally {
      _continuationInFlight = false;
    }
  }

  Future<void> playTrack(Map<String, dynamic> track) async {
    final generation = await _beginPlaybackReplacement(context: null);
    await _resolveSignedUrls(() async {
      await _startWithRecovery(() async {
        final item = await _sourceResolver.resolveTrack(track);
        if (!_isCurrentPlayRequest(generation)) return;
        await _queueController.setQueue([item]);
        if (!_isCurrentPlayRequest(generation)) return;
        await _queueController.play();
      });
    }, generation: generation);
  }

  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    if (tracks.isEmpty) return;

    // Stamp (or clear) the attribution before playback starts so the player
    // updates immediately and a context-less play never leaves a stale label.
    final generation = await _beginPlaybackReplacement(context: context);

    await _resolveSignedUrls(() async {
      await _startWithRecovery(() async {
        final items = await _sourceResolver.resolveQueue(tracks);
        if (!_isCurrentPlayRequest(generation)) return;
        await _queueController.setQueue(items, initialIndex: startIndex);
        if (!_isCurrentPlayRequest(generation)) return;
        await _queueController.play();
      });
    }, generation: generation);
  }

  /// Validates that the persisted plan retains Slice 1's canonical playlist
  /// order, then loads it through the single queue timeline controller.
  Future<void> playMixPlan(
    List<Map<String, dynamic>> tracks,
    MixPlan plan, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    if (tracks.isEmpty || plan.clips.isEmpty) return;
    _validateMixPlanOrder(tracks, plan);
    final generation = await _beginPlaybackReplacement(context: context);

    await _resolveSignedUrls(() async {
      await _startWithRecovery(() async {
        final items = await _sourceResolver.resolveQueue(tracks);
        if (!_isCurrentPlayRequest(generation)) return;
        final session = MixSession.fromMixPlan(plan: plan, queue: items);
        await _queueController.setQueue(
          items,
          initialIndex: startIndex,
          session: session,
        );
        if (!_isCurrentPlayRequest(generation)) return;
        await _queueController.play();
      });
    }, generation: generation);
  }

  void _validateMixPlanOrder(
    List<Map<String, dynamic>> tracks,
    MixPlan plan,
  ) {
    if (tracks.length != plan.clips.length) {
      throw FormatException(
        'Mix plan clip count (${plan.clips.length}) does not match playlist '
        'track count (${tracks.length}).',
      );
    }
    for (var index = 0; index < tracks.length; index++) {
      final trackId = PlaybackSourceResolver.readTrackId(tracks[index]);
      final clip = plan.clips[index];
      if (trackId.toString() != clip.trackId) {
        throw FormatException(
          'Mix plan clip ${clip.clipId} does not match playlist position '
          '$index (track $trackId).',
        );
      }
    }
  }

  Future<int> _beginPlaybackReplacement({
    required PlaybackContext? context,
  }) async {
    final generation = ++_playRequestGeneration;
    _transportCommandGeneration++;
    _playbackContext = context;
    _playbackError = null;

    // Stop/release the old session before waiting on signed URL resolution.
    // Otherwise Android keeps playing A while B is still preparing, which makes
    // the pause button appear to "stop A and start B" once the pending request
    // finally resolves.
    await _queueController.setQueue(const []);
    return generation;
  }

  bool _isCurrentPlayRequest(int generation) {
    return generation == _playRequestGeneration;
  }

  void _cancelPendingPlayRequests() {
    _playRequestGeneration += 1;
    if (_isResolvingSignedUrl) {
      _isResolvingSignedUrl = false;
      notifyListeners();
    }
  }

  /// Adds [track] to the active listening queue after the current item and any
  /// already-queued manual items, before the context tail. If nothing is
  /// playing yet, starts a fresh queue with just this track. This is the
  /// "Add to queue" action; it operates on the real playing queue, not the
  /// separate Redis edit-queue.
  Future<void> enqueue(Map<String, dynamic> track) async {
    if (queue.isEmpty) {
      await playQueue([track]);
      return;
    }
    final item = markOrigin(
      await _sourceResolver.resolveTrack(track),
      queueOriginManual,
    );
    await _queueController.insertIntoQueue(
      manualEnqueueIndex(queue, currentIndex),
      item,
    );
  }

  /// Inserts [track] to play immediately after the current item ("Play next").
  /// Starts a fresh queue when nothing is playing.
  Future<void> playNext(Map<String, dynamic> track) async {
    if (queue.isEmpty) {
      await playQueue([track]);
      return;
    }
    final item = markOrigin(
      await _sourceResolver.resolveTrack(track),
      queueOriginManual,
    );
    await _queueController.insertIntoQueue((currentIndex ?? -1) + 1, item);
  }

  /// Runs [start], retrying it once if the failure looks like a stale/expired
  /// signed URL. The retry re-runs [start], which re-resolves the queue from
  /// scratch — re-validating local artifacts and re-requesting fresh signed
  /// descriptors for the remote tracks.
  Future<void> _startWithRecovery(Future<void> Function() start) async {
    try {
      await start();
    } catch (error) {
      if (!_isRecoverableObjectUrlFailure(error)) rethrow;
      await start();
    }
  }

  bool _isRecoverableObjectUrlFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('403') ||
        message.contains('forbidden') ||
        message.contains('expired') ||
        message.contains('signature') ||
        message.contains('accessdenied') ||
        message.contains('access denied');
  }

  Future<void> _resolveSignedUrls(
    Future<void> Function() action, {
    int? generation,
  }) async {
    _isResolvingSignedUrl = true;
    _playbackError = null;
    notifyListeners();

    bool requestIsCurrent() =>
        generation == null || _isCurrentPlayRequest(generation);

    try {
      await action();
    } on SignedAudioUrlException catch (error) {
      if (!requestIsCurrent()) return;
      _playbackError = _userFacingPlaybackError(error);
      if (kDebugMode) {
        debugPrint('Playback URL resolution failed: ${error.code}');
      }
      rethrow;
    } catch (error) {
      if (!requestIsCurrent()) return;
      _playbackError = 'Playback failed before audio could start.';
      if (kDebugMode) {
        debugPrint('Playback start failed: $error');
      }
      rethrow;
    } finally {
      if (requestIsCurrent()) {
        _isResolvingSignedUrl = false;
        notifyListeners();
      }
    }
  }

  String _userFacingPlaybackError(SignedAudioUrlException error) {
    final code = error.code.toLowerCase();
    switch (code) {
      case 'audio_unavailable':
      case 'artifact_missing':
      case 'audio_unavailable_error':
      case 'object_unavailable':
        return 'Audio is unavailable for this track.';
      case 'playback_url_expired':
        return 'The playback link expired. Try playing the track again.';
      case 'track_not_found':
        return 'This track is no longer available.';
      case 'forbidden':
        return 'You do not have access to play this track.';
      default:
        return 'Could not prepare a signed playback URL.';
    }
  }

  @override
  Future<void> play() async {
    final commandGeneration = ++_transportCommandGeneration;
    await _refreshCurrentSignedUrlIfNeeded();
    if (commandGeneration != _transportCommandGeneration) return;
    try {
      await _queueController.play();
    } catch (error) {
      if (!_isRecoverableObjectUrlFailure(error)) rethrow;
      await _refreshCurrentSignedUrl(force: true);
      if (commandGeneration != _transportCommandGeneration) return;
      await _queueController.play();
    }
  }

  Future<void> _refreshCurrentSignedUrlIfNeeded() async {
    final item = currentItem;
    if (item == null) return;
    // A local-backed item plays from an on-device file and never expires, so it
    // must never trigger a signed-URL refresh (which would hit the network and,
    // when offline, mask the real failure).
    if (localArtifactPath(item) != null) return;
    final expiresAt = item.extras?['expiresAt'];
    if (expiresAt is! String) return;
    final parsed = DateTime.tryParse(expiresAt)?.toUtc();
    if (parsed == null) return;
    final descriptor = SignedAudioDescriptor(
      trackId: int.tryParse(item.id) ?? -1,
      url: item.extras?['url'] as String? ?? '',
      expiresAt: parsed,
    );
    if (!descriptor.shouldRefreshSoon()) return;
    await _refreshCurrentSignedUrl(force: true);
  }

  Future<void> _refreshCurrentSignedUrl({bool force = false}) async {
    final index = currentIndex;
    final item = currentItem;
    final currentQueue = queue;
    if (index == null ||
        item == null ||
        index < 0 ||
        index >= currentQueue.length) {
      return;
    }
    if (localArtifactPath(item) != null) return;
    final trackId = int.tryParse(item.id);
    if (trackId == null || trackId <= 0) return;
    if (!force) return;

    final descriptor = await _signedAudioUrlService.requireDescriptor(trackId);
    final extras = Map<String, dynamic>.from(item.extras ?? const {});
    extras['url'] = descriptor.url;
    extras['expiresAt'] = descriptor.expiresAt.toIso8601String();
    if (descriptor.contentType != null) {
      extras['contentType'] = descriptor.contentType;
    }
    if (descriptor.sizeBytes != null) {
      extras['sizeBytes'] = descriptor.sizeBytes;
    }
    if (descriptor.codec != null) {
      extras['codec'] = descriptor.codec;
    }
    if (descriptor.bitrateKbps != null) {
      extras['bitrateKbps'] = descriptor.bitrateKbps;
    }
    if (descriptor.sampleRateHz != null) {
      extras['sampleRateHz'] = descriptor.sampleRateHz;
    }
    if (descriptor.channels != null) {
      extras['channels'] = descriptor.channels;
    }
    if (descriptor.etag != null) {
      extras['etag'] = descriptor.etag;
    }
    if (descriptor.storageKeyVersion != null) {
      extras['storageKeyVersion'] = descriptor.storageKeyVersion;
    }

    final refreshedQueue = List<MediaItem>.from(currentQueue);
    refreshedQueue[index] = item.copyWith(extras: extras);
    await _queueController.setQueue(
      refreshedQueue,
      preserveCurrentTransport: true,
      preserveTimelineEdits: true,
    );
  }

  Future<void> refreshTrackAnalysis(
    String trackId,
    TrackAnalysis analysis,
  ) =>
      refreshTrackAnalyses({trackId: analysis});

  Future<void> refreshTrackAnalyses(
    Map<String, TrackAnalysis> analysesByTrackId,
  ) async {
    if (analysesByTrackId.isEmpty || queue.isEmpty) return;
    final normalizedAnalyses = <String, TrackAnalysis>{};
    for (final entry in analysesByTrackId.entries) {
      final trackId = entry.key.trim();
      if (trackId.isNotEmpty) normalizedAnalyses[trackId] = entry.value;
    }
    if (normalizedAnalyses.isEmpty) return;

    var changed = false;
    int? firstChangedIndex;
    final refreshedQueue = <MediaItem>[];
    for (var index = 0; index < queue.length; index++) {
      final item = queue[index];
      MapEntry<String, TrackAnalysis>? matchingAnalysis;
      for (final entry in normalizedAnalyses.entries) {
        if (_mediaItemMatchesAnalysisTrack(item, entry.key)) {
          matchingAnalysis = entry;
          break;
        }
      }
      if (matchingAnalysis != null) {
        refreshedQueue.add(
          _mediaItemWithAnalysis(
            item,
            matchingAnalysis.key,
            matchingAnalysis.value,
          ),
        );
        changed = true;
        firstChangedIndex ??= index;
      } else {
        refreshedQueue.add(item);
      }
    }
    if (!changed) return;

    await _queueController.setQueue(
      refreshedQueue,
      preserveCurrentTransport: true,
      preserveTimelineEdits: true,
      reflowDefaultTransitionsFromIndex: firstChangedIndex,
    );
  }

  bool _mediaItemMatchesAnalysisTrack(MediaItem item, String trackId) {
    if (item.id == trackId) return true;
    final extras = item.extras ?? const <String, dynamic>{};
    return extras['analysisRef']?.toString() == trackId ||
        extras['trackId']?.toString() == trackId ||
        extras['track_id']?.toString() == trackId;
  }

  MediaItem _mediaItemWithAnalysis(
    MediaItem item,
    String trackId,
    TrackAnalysis analysis,
  ) {
    final extras = Map<String, dynamic>.from(item.extras ?? const {});
    extras['analysisRef'] = trackId;
    for (final key in const [
      'analysisStatus',
      'analysis_status',
      'analysisSummary',
      'analysis_summary',
      'analysisOverrides',
      'analysis_overrides',
      'analysisUpdatedAt',
      'analysis_updated_at',
      'analysisOverrideRevision',
      'analysis_override_revision',
      'analysisOverrideUpdatedAt',
      'analysis_override_updated_at',
    ]) {
      extras.remove(key);
    }
    extras.addAll(
      trackAnalysisFields(
        analysis,
        summarySerializer: (summary) =>
            compactAnalysisSummary(summary.toJson()),
        overridesSerializer: (overrides) =>
            compactAnalysisOverrides(overrides?.toJson()) ?? const {},
      ),
    );
    return item.copyWith(extras: extras);
  }

  @override
  Future<void> pause() async {
    _transportCommandGeneration++;
    _cancelPendingPlayRequests();
    await _queueController.pause();
  }

  Future<void> stop() async {
    _transportCommandGeneration++;
    _cancelPendingPlayRequests();
    await _queueController.stop();
  }

  Future<void> seek(Duration position) => _queueController.seek(position);
  void beginLocalScrub() => _queueController.beginLocalScrub();
  void updateLocalScrub(Duration position) =>
      _queueController.updateLocalScrub(position);
  Future<void> endLocalScrub(Duration position) =>
      _queueController.endLocalScrub(position);
  Future<void> skipToNext() async {
    _transportCommandGeneration++;
    await _queueController.skipToNext();
  }

  Future<void> skipToPrevious() async {
    _transportCommandGeneration++;
    await _queueController.skipToPrevious();
  }

  /// Previous-button behavior: restart the current track when more than 3s in,
  /// otherwise skip to the previous track (see [previousAction]).
  Future<void> previous() async {
    switch (previousAction(position.inMilliseconds)) {
      case PreviousAction.restart:
        await seek(Duration.zero);
      case PreviousAction.skip:
        await skipToPrevious();
    }
  }

  /// Rebuilds the last persisted listening queue on startup: it restores the
  /// queue at the saved index, seeks to the saved position, and stays PAUSED
  /// (never auto-plays). Remote items are re-resolved through the source
  /// resolver so their signed URLs are fresh. Empty/absent saved state is a
  /// no-op ([hasTrack] stays false) and any restore failure is swallowed so it
  /// can never surface as a [playbackError] or crash startup.
  ///
  /// Auto-continuation and the snapshot (#352 x #339): a continuation segment is
  /// part of the real listening queue, so it is snapshotted and restored like
  /// any other item — dropping it would lose whatever is currently playing. What
  /// it is *not* is user-built, so the per-item origin marker is persisted too
  /// (see `mediaItemToPlaybackJson`) and restamped here. A restored queue
  /// therefore comes back still labelled "Auto-continuation" in the queue
  /// screen rather than masquerading as a queue the listener assembled.
  Future<void> restore() async {
    final store = _persistence;
    if (store == null) return;

    try {
      final snapshot = await store.load();
      if (snapshot.isEmpty) return;
      final resolved = await _sourceResolver.resolveQueue(snapshot.tracks);
      final items = [
        for (var index = 0; index < resolved.length; index++)
          _withPersistedOrigin(resolved[index], snapshot.tracks[index]),
      ];
      if (items.isEmpty) return;
      // A queue change made while loading/resolving is newer than the durable
      // startup snapshot. Leave it authoritative and replay it in [finally].
      if (_persistenceDirty) return;
      final index = snapshot.currentIndex.clamp(0, items.length - 1);
      await _queueController.setQueue(
        items,
        initialIndex: index,
        session: snapshot.session,
      );
      // Playback modes are restored against the rebuilt queue: shuffle has to
      // run after setQueue so the fresh permutation covers the restored items
      // (setQueue always resets the play order to linear).
      await setLoopMode(snapshot.loopMode);
      if (snapshot.shuffleEnabled) {
        await setShuffleEnabled(true);
      }
      if (snapshot.positionMs > 0) {
        await _queueController.seek(
          Duration(milliseconds: snapshot.positionMs),
        );
      }
      // Deliberately stay paused: restore never auto-plays.
    } catch (error) {
      // A failed restore leaves the player empty; the queue is re-resolved on
      // the next explicit play. Never turn this into a user-facing error.
      if (kDebugMode) {
        debugPrint('Queue restore failed: $error');
      }
    } finally {
      // The load/restore decision is complete, including empty and failure
      // paths. Future queue changes may now persist, including an empty queue
      // that deliberately clears stale storage.
      _persistenceReady = true;
      if (_persistenceDirty) {
        _persistenceDirty = false;
        _persistQueue();
      }
    }
  }

  /// Restamps the persisted queue-item origin onto a re-resolved item.
  ///
  /// The source resolver rebuilds extras from the track payload and only owns
  /// the fields it resolves (URLs, artwork, analysis), so the origin annotation
  /// has to be re-applied from the snapshot row it came from.
  MediaItem _withPersistedOrigin(MediaItem item, Map<String, dynamic> track) {
    final origin = track['itemOrigin'];
    if (origin is! String || origin.isEmpty) return item;
    return markOrigin(item, origin);
  }

  /// Fire-and-forget persistence of the current queue/index/position. A no-op
  /// when no store is configured or when nothing is queued (which clears any
  /// stale saved state).
  void _persistQueue({bool isStartupSeed = false}) {
    final store = _persistence;
    if (store == null) return;
    if (!_persistenceReady) {
      if (!isStartupSeed) _persistenceDirty = true;
      return;
    }

    _persistenceTimer?.cancel();
    _persistenceTimer = Timer(_persistenceDebounce, _flushPersistence);
  }

  void _flushPersistence() {
    _persistenceTimer?.cancel();
    _persistenceTimer = null;
    final store = _persistence;
    if (store == null || !_persistenceReady) return;
    final currentQueue = queue;
    final snapshot = currentQueue.isEmpty
        ? const QueueSnapshot()
        : QueueSnapshot(
            tracks: currentQueue.map(mediaItemToPlaybackJson).toList(),
            currentIndex: currentIndex ?? 0,
            positionMs: position.inMilliseconds,
            shuffleEnabled: _shuffleEnabled,
            loopMode: _loopMode,
            session: _queueController.session,
          );
    unawaited(store.save(snapshot));
  }

  Future<void> skipToIndex(int index) async {
    _transportCommandGeneration++;
    await _queueController.skipToIndex(index);
  }

  Future<bool> playQueueItemByQueueItemId(String queueItemId) async {
    final commandGeneration = ++_transportCommandGeneration;
    final selected =
        await _queueController.selectQueueItemByQueueItemId(queueItemId);
    if (!selected || commandGeneration != _transportCommandGeneration) {
      return false;
    }
    await play();
    return true;
  }

  Future<void> removeFromQueue(int index) =>
      _queueController.removeFromQueue(index);
  Future<void> removeFromQueueByQueueItemId(String queueItemId) =>
      _queueController.removeFromQueueByQueueItemId(queueItemId);
  Future<void> toggleShuffle() => _queueController.toggleShuffle();
  Future<void> cycleLoopMode() => _queueController.cycleLoopMode();

  /// Idempotent absolute forms of [toggleShuffle] / [cycleLoopMode]. Restore
  /// and OS media-session commands both carry a target mode rather than a
  /// "next" intent, so they must not flip an already-correct mode.
  Future<void> setShuffleEnabled(bool enabled) =>
      _queueController.setShuffleMode(enabled);
  Future<void> setLoopMode(LoopMode mode) => _queueController.setLoopMode(mode);

  Future<void> togglePlayPause() async {
    if (isPlaying || _isResolvingSignedUrl) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  void dispose() {
    if (_persistenceTimer != null) _flushPersistence();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    unawaited(_queueController.dispose());
    super.dispose();
  }
}
