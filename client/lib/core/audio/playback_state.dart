import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../cache/playback_cache_manager.dart';
import 'audio_player_service.dart';
import 'local_audio_artifact_resolver.dart';
import 'playback_context.dart';
import 'playback_source_resolver.dart';
import 'queue_ordering.dart';
import 'queue_persistence.dart';
import 'signed_audio_url_service.dart';

class PlaybackState extends ChangeNotifier {
  final AudioPlayerService _audioService;
  final SignedAudioUrlService _signedAudioUrlService;
  final PlaybackSourceResolver _sourceResolver;

  /// Local store for the resumable queue snapshot. Null disables persistence
  /// entirely (used in tests and on platforms without a store), keeping every
  /// save/restore a no-op.
  final QueuePersistenceStore? _persistence;

  List<StreamSubscription> _subscriptions = [];

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  Duration _duration = Duration.zero;
  MediaItem? _currentItem;
  List<MediaItem> _queue = [];
  int? _currentIndex;
  bool _shuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;
  String? _playbackError;
  bool _isResolvingSignedUrl = false;
  PlaybackContext? _playbackContext;

  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration get bufferedPosition => _bufferedPosition;
  Duration get duration => _duration;
  MediaItem? get currentItem => _currentItem;
  List<MediaItem> get queue => _queue;
  int? get currentIndex => _currentIndex;
  bool get shuffleEnabled => _shuffleEnabled;
  LoopMode get loopMode => _loopMode;
  bool get hasTrack => _currentItem != null;
  String? get playbackError => _playbackError;
  bool get isResolvingSignedUrl => _isResolvingSignedUrl;

  /// Where the current listening queue was launched from (album, playlist, ...),
  /// or null when the queue was started without a context. Drives the
  /// "Playing from <label>" attribution in the mini/full player.
  PlaybackContext? get playbackContext => _playbackContext;

  /// Raw playback streams, exposed so the play-event recorder can observe
  /// position/track-change/completion without reaching into the audio service
  /// directly. These forward the underlying just_audio streams unchanged.
  Stream<Duration> get positionStream => _audioService.positionStream;
  Stream<MediaItem?> get currentMediaItemStream =>
      _audioService.currentMediaItemStream;
  Stream<PlayerState> get playerStateStream => _audioService.playerStateStream;

  PlaybackState(
    this._audioService, {
    required SignedAudioUrlService signedAudioUrlService,
    LocalAudioArtifactResolver? localResolver,
    PlaybackCacheManager? cacheManager,
    QueuePersistenceStore? persistence,
  })  : _signedAudioUrlService = signedAudioUrlService,
        _persistence = persistence,
        _sourceResolver = PlaybackSourceResolver(
          signedAudioUrlService: signedAudioUrlService,
          localResolver: localResolver,
          cacheManager: cacheManager,
        ) {
    _init();
  }

  void _init() {
    _subscriptions = [
      _audioService.playerStateStream.listen((state) {
        final wasPlaying = _isPlaying;
        _isPlaying = state.playing;
        // Persist the resting position whenever playback pauses so a resume
        // picks up where the listener left off.
        if (wasPlaying && !_isPlaying) _persistQueue();
        notifyListeners();
      }),
      _audioService.positionStream.listen((pos) {
        _position = pos;
        notifyListeners();
      }),
      _audioService.bufferedPositionStream.listen((pos) {
        _bufferedPosition = pos;
        notifyListeners();
      }),
      _audioService.durationStream.listen((dur) {
        _duration = dur ?? Duration.zero;
        notifyListeners();
      }),
      _audioService.currentMediaItemStream.listen((item) {
        _currentItem = item;
        notifyListeners();
      }),
      _audioService.queueStream.listen((q) {
        _queue = q;
        _persistQueue();
        notifyListeners();
      }),
      _audioService.currentIndexStream.listen((index) {
        _currentIndex = index;
        _persistQueue();
        notifyListeners();
      }),
      _audioService.shuffleEnabledStream.listen((enabled) {
        _shuffleEnabled = enabled;
        notifyListeners();
      }),
      _audioService.loopModeStream.listen((mode) {
        _loopMode = mode;
        notifyListeners();
      }),
    ];
  }

  Future<void> playTrack(Map<String, dynamic> track) async {
    await _resolveSignedUrls(() async {
      await _startWithRecovery(() async {
        final item = await _sourceResolver.resolveTrack(track);
        await _audioService.setQueue([item]);
        await _audioService.play();
      });
    });
  }

  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    if (tracks.isEmpty) return;

    // Stamp (or clear) the attribution before playback starts so the player
    // updates immediately and a context-less play never leaves a stale label.
    _playbackContext = context;
    notifyListeners();

    await _resolveSignedUrls(() async {
      await _startWithRecovery(() async {
        final items = await _sourceResolver.resolveQueue(tracks);
        await _audioService.setQueue(items, initialIndex: startIndex);
        await _audioService.play();
      });
    });
  }

  /// Adds [track] to the active listening queue after the current item and any
  /// already-queued manual items, before the context tail. If nothing is
  /// playing yet, starts a fresh queue with just this track. This is the
  /// "Add to queue" action; it operates on the real playing queue, not the
  /// separate Redis edit-queue.
  Future<void> enqueue(Map<String, dynamic> track) async {
    if (_queue.isEmpty) {
      await playQueue([track]);
      return;
    }
    final item = markOrigin(
        await _sourceResolver.resolveTrack(track), queueOriginManual);
    await _audioService.insertIntoQueue(
      manualEnqueueIndex(_queue, _currentIndex),
      item,
    );
  }

  /// Inserts [track] to play immediately after the current item ("Play next").
  /// Starts a fresh queue when nothing is playing.
  Future<void> playNext(Map<String, dynamic> track) async {
    if (_queue.isEmpty) {
      await playQueue([track]);
      return;
    }
    final item = markOrigin(
        await _sourceResolver.resolveTrack(track), queueOriginManual);
    await _audioService.insertIntoQueue((_currentIndex ?? -1) + 1, item);
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

  Future<void> _resolveSignedUrls(Future<void> Function() action) async {
    _isResolvingSignedUrl = true;
    _playbackError = null;
    notifyListeners();

    try {
      await action();
    } on SignedAudioUrlException catch (error) {
      _playbackError = _userFacingPlaybackError(error);
      if (kDebugMode) {
        debugPrint('Playback URL resolution failed: ${error.code}');
      }
      rethrow;
    } catch (error) {
      _playbackError = 'Playback failed before audio could start.';
      if (kDebugMode) {
        debugPrint('Playback start failed: $error');
      }
      rethrow;
    } finally {
      _isResolvingSignedUrl = false;
      notifyListeners();
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

  Future<void> play() async {
    await _refreshCurrentSignedUrlIfNeeded();
    try {
      await _audioService.play();
    } catch (error) {
      if (!_isRecoverableObjectUrlFailure(error)) rethrow;
      await _refreshCurrentSignedUrl(force: true);
      await _audioService.play();
    }
  }

  Future<void> _refreshCurrentSignedUrlIfNeeded() async {
    final item = _currentItem;
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
    final index = _currentIndex;
    final item = _currentItem;
    if (index == null || item == null || index < 0 || index >= _queue.length) {
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
    if (descriptor.etag != null) {
      extras['etag'] = descriptor.etag;
    }
    if (descriptor.storageKeyVersion != null) {
      extras['storageKeyVersion'] = descriptor.storageKeyVersion;
    }

    final refreshedQueue = List<MediaItem>.from(_queue);
    refreshedQueue[index] = item.copyWith(extras: extras);
    await _audioService.setQueue(refreshedQueue, initialIndex: index);
  }

  Future<void> pause() => _audioService.pause();
  Future<void> stop() => _audioService.stop();
  Future<void> seek(Duration position) => _audioService.seek(position);
  Future<void> skipToNext() => _audioService.skipToNext();
  Future<void> skipToPrevious() => _audioService.skipToPrevious();

  /// Previous-button behavior: restart the current track when more than 3s in,
  /// otherwise skip to the previous track (see [previousAction]).
  Future<void> previous() async {
    switch (previousAction(_position.inMilliseconds)) {
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

    final snapshot = await store.load();
    if (snapshot.isEmpty) return;

    try {
      final items = await _sourceResolver.resolveQueue(snapshot.tracks);
      if (items.isEmpty) return;
      final index = snapshot.currentIndex.clamp(0, items.length - 1);
      await _audioService.setQueue(items, initialIndex: index);
      if (snapshot.positionMs > 0) {
        await _audioService.seek(Duration(milliseconds: snapshot.positionMs));
      }
      // Deliberately stay paused: restore never auto-plays.
    } catch (error) {
      // A failed restore leaves the player empty; the queue is re-resolved on
      // the next explicit play. Never turn this into a user-facing error.
      if (kDebugMode) {
        debugPrint('Queue restore failed: $error');
      }
    }
  }

  /// Fire-and-forget persistence of the current queue/index/position. A no-op
  /// when no store is configured or when nothing is queued (which clears any
  /// stale saved state).
  void _persistQueue() {
    final store = _persistence;
    if (store == null) return;

    final snapshot = _queue.isEmpty
        ? const QueueSnapshot()
        : QueueSnapshot(
            tracks: _queue.map(mediaItemToPlaybackJson).toList(),
            currentIndex: _currentIndex ?? 0,
            positionMs: _position.inMilliseconds,
          );
    unawaited(store.save(snapshot));
  }
  Future<void> skipToIndex(int index) => _audioService.skipToIndex(index);
  Future<void> toggleShuffle() => _audioService.toggleShuffle();
  Future<void> cycleLoopMode() => _audioService.cycleLoopMode();

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
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
    super.dispose();
  }
}
