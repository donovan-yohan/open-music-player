import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import '../cache/playback_cache_manager.dart';
import '../engine/playback_engine.dart';
import '../engine/tempo_automation.dart';
import '../engine/timeline_model.dart';
import '../../models/timeline_clip.dart';
import '../../models/track_analysis.dart';
import '../../models/trim_range.dart';
import 'audio_focus_playback.dart';
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
  PlaybackSnapshot get snapshot => _queueController.snapshot;

  /// Live global mix timeline state for the waveform surface. This is the raw
  /// engine clock/model contract, not the source-relative player position.
  Stream<int> get timelinePositionMsStream =>
      _queueController.engine.positionMsStream;
  int get timelinePositionMs => _queueController.engine.positionMs;
  TimelineModel get timelineModel => _queueController.engine.model;
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
  })  : _queueController = QueueTimelineController(engine),
        _signedAudioUrlService = signedAudioUrlService,
        _persistence = persistence,
        _persistenceReady = persistence == null,
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
        // picks up where the listener left off.
        if (wasPlaying && !_isPlaying) _persistQueue();
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
        _shuffleEnabled = enabled;
        notifyListeners();
      }),
      _queueController.loopModeStream.listen((mode) {
        _loopMode = mode;
        notifyListeners();
      }),
    ];
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

  Future<int> _beginPlaybackReplacement({
    required PlaybackContext? context,
  }) async {
    final generation = ++_playRequestGeneration;
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
      initialIndex: index,
      initialPosition: _queueController.livePosition,
      preserveTimelineEdits: true,
    );
  }

  Future<void> refreshTrackAnalysis(
    String trackId,
    TrackAnalysis analysis,
  ) async {
    final normalizedTrackId = trackId.trim();
    if (normalizedTrackId.isEmpty || queue.isEmpty) return;

    var changed = false;
    int? firstChangedIndex;
    final refreshedQueue = <MediaItem>[];
    for (var index = 0; index < queue.length; index++) {
      final item = queue[index];
      if (_mediaItemMatchesAnalysisTrack(item, normalizedTrackId)) {
        refreshedQueue.add(
          _mediaItemWithAnalysis(item, normalizedTrackId, analysis),
        );
        changed = true;
        firstChangedIndex ??= index;
      } else {
        refreshedQueue.add(item);
      }
    }
    if (!changed) return;

    final index =
        currentIndex?.clamp(0, refreshedQueue.length - 1).toInt() ?? 0;
    await _queueController.setQueue(
      refreshedQueue,
      initialIndex: index,
      initialPosition: _queueController.livePosition,
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
    extras['analysisStatus'] = analysis.status.name;
    final summary = analysis.summary;
    final overrides = analysis.overrides;
    if (summary == null) {
      extras.remove('analysisSummary');
      extras.remove('analysis_summary');
    } else {
      extras['analysisSummary'] = summary.toJson();
      extras.remove('analysis_summary');
    }
    if (overrides == null) {
      extras.remove('analysisOverrides');
      extras.remove('analysis_overrides');
    } else {
      extras['analysisOverrides'] = overrides.toJson();
      extras.remove('analysis_overrides');
    }
    if (analysis.updatedAt == null) {
      extras.remove('analysisUpdatedAt');
      extras.remove('analysis_updated_at');
    } else {
      extras['analysisUpdatedAt'] =
          analysis.updatedAt!.toUtc().toIso8601String();
      extras.remove('analysis_updated_at');
    }
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
  Future<void> skipToNext() => _queueController.skipToNext();
  Future<void> skipToPrevious() => _queueController.skipToPrevious();

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
  Future<void> restore() async {
    final store = _persistence;
    if (store == null) return;

    try {
      final snapshot = await store.load();
      if (snapshot.isEmpty) return;
      final items = await _sourceResolver.resolveQueue(snapshot.tracks);
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

    final currentQueue = queue;
    final snapshot = currentQueue.isEmpty
        ? const QueueSnapshot()
        : QueueSnapshot(
            tracks: currentQueue.map(mediaItemToPlaybackJson).toList(),
            currentIndex: currentIndex ?? 0,
            positionMs: position.inMilliseconds,
            session: _queueController.session,
          );
    unawaited(store.save(snapshot));
  }

  Future<void> skipToIndex(int index) => _queueController.skipToIndex(index);
  Future<void> removeFromQueue(int index) =>
      _queueController.removeFromQueue(index);
  Future<void> removeFromQueueByQueueItemId(String queueItemId) =>
      _queueController.removeFromQueueByQueueItemId(queueItemId);
  Future<void> toggleShuffle() => _queueController.toggleShuffle();
  Future<void> cycleLoopMode() => _queueController.cycleLoopMode();

  Future<void> togglePlayPause() async {
    if (isPlaying || _isResolvingSignedUrl) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    unawaited(_queueController.dispose());
    super.dispose();
  }
}
