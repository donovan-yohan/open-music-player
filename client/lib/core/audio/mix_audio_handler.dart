import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:just_audio/just_audio.dart' as just_audio;

import '../services/liked_tracks_state.dart';
import 'playback_session.dart';
import 'playback_state.dart' as app_audio;

const defaultNotificationStateThrottle = Duration(milliseconds: 750);

/// Name of the notification's like/heart control, received back through
/// [MixAudioHandler.customAction].
const likeCustomActionName = 'omp.toggleLike';

class MixAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.SeekHandler {
  // OS media controls remain a thin PlaybackState client. The app command
  // registry above PlaybackState is the canonical command vocabulary; this
  // handler is intentionally not a second command bus.
  MixAudioHandler({
    required app_audio.PlaybackState playbackState,
    LikedTracksState? likedTracksState,
    Duration statePushThrottle = defaultNotificationStateThrottle,
    DateTime Function()? now,
  })  : _playbackState = playbackState,
        _likedTracksState = likedTracksState,
        _statePushThrottle = statePushThrottle,
        _now = now ?? DateTime.now {
    _applySnapshot(playbackState.snapshot);
    _shuffleEnabled = playbackState.shuffleEnabled;
    _loopMode = playbackState.loopMode;
    _publishQueue();
    mediaItem.add(_mediaItem());
    _subscriptions.add(
      playbackState.snapshotStream.listen((snapshot) {
        _applySnapshot(snapshot);
        _publishQueue();
        _publishMediaItem();
        _publishState(force: true);
      }),
    );
    // Shuffle/repeat live outside the playback snapshot, and a loop-mode change
    // alone produces no snapshot at all. Without these the OS would keep
    // showing a stale off-state after an in-app toggle.
    _subscriptions.add(
      playbackState.shuffleEnabledStream.listen((enabled) {
        _shuffleEnabled = enabled;
        _publishState(force: true);
      }),
    );
    _subscriptions.add(
      playbackState.loopModeStream.listen((mode) {
        _loopMode = mode;
        _publishState(force: true);
      }),
    );
    likedTracksState?.addListener(_onLikedTracksChanged);
    _publishState(force: true);
  }

  final app_audio.PlaybackState _playbackState;
  final LikedTracksState? _likedTracksState;
  final Duration _statePushThrottle;
  final DateTime Function() _now;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  List<audio_service.MediaItem> _queueItems = const [];

  /// Queue-item ids parallel to [_queueItems]. The OS addresses queue entries
  /// by position, while PlaybackState addresses them by stable occurrence id
  /// (a queue can hold the same track twice).
  List<String> _queueItemIds = const [];
  audio_service.MediaItem? _currentItem;
  int? _queueIndex;
  bool _shuffleEnabled = false;
  just_audio.LoopMode _loopMode = just_audio.LoopMode.off;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isPlaying = false;
  int _activeVoiceCount = 0;
  double _playbackSpeed = 1;
  bool _pitchPreservationFallback = false;
  audio_service.AudioProcessingState _processingState =
      audio_service.AudioProcessingState.ready;
  DateTime? _lastStatePushAt;
  Timer? _pendingStateTimer;
  bool _disposed = false;

  @override
  Future<void> play() => _playbackState.play();

  @override
  Future<void> pause() => _playbackState.pause();

  @override
  Future<void> seek(Duration position) async {
    await _playbackState.seek(position);
    _position = position;
    _publishState(force: true);
  }

  @override
  Future<void> skipToNext() => _playbackState.skipToNext();

  @override
  Future<void> skipToPrevious() => _playbackState.skipToPrevious();

  @override
  Future<void> stop() async {
    await _playbackState.stop();
    _isPlaying = false;
    _publishState(force: true);
    return super.stop();
  }

  /// OS surfaces (Bluetooth controllers, headset apps, Android Auto) send an
  /// absolute target mode, never a "flip it" intent, so this maps onto the
  /// idempotent PlaybackState setter rather than [app_audio.PlaybackState
  /// .toggleShuffle].
  @override
  Future<void> setShuffleMode(
    audio_service.AudioServiceShuffleMode shuffleMode,
  ) async {
    final enabled = shuffleMode != audio_service.AudioServiceShuffleMode.none;
    await _playbackState.setShuffleEnabled(enabled);
    _shuffleEnabled = enabled;
    _publishState(force: true);
  }

  /// Same contract as [setShuffleMode]: an absolute repeat mode, mapped onto
  /// the queue's loop mode instead of cycling it.
  @override
  Future<void> setRepeatMode(
    audio_service.AudioServiceRepeatMode repeatMode,
  ) async {
    final mode = _loopModeFor(repeatMode);
    await _playbackState.setLoopMode(mode);
    _loopMode = mode;
    _publishState(force: true);
  }

  /// Tapping an entry in a system queue UI. The OS supplies a position in the
  /// queue this handler published, which maps to the occurrence id
  /// PlaybackState selects by.
  ///
  /// The position is only meaningful against the queue it was rendered from,
  /// and that queue can be rebuilt between the OS dispatching the tap and this
  /// call arriving. So the position is resolved to an occurrence id under the
  /// published snapshot, and that occurrence must still be in the live queue
  /// before anything plays: a stale position is a no-op, never a wrong-track
  /// play, and never a transport command that pre-empts an in-flight skip.
  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queueItemIds.length) return;
    final queueItemId = _queueItemIds[index];
    if (!_isLiveQueueItemId(queueItemId)) return;
    await _playbackState.playQueueItemByQueueItemId(queueItemId);
  }

  bool _isLiveQueueItemId(String queueItemId) {
    for (final cue in _playbackState.snapshot.cues) {
      if (cue.queueItemId == queueItemId) return true;
    }
    return false;
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name != likeCustomActionName) {
      return super.customAction(name, extras);
    }
    await _toggleLike();
    return null;
  }

  /// Releases the snapshot/mode subscriptions, the [LikedTracksState] listener
  /// and any pending throttled state push.
  ///
  /// Idempotent, and safe to call from more than one teardown path: the
  /// liked-state listener outlives the handler's subscriptions (it hangs off an
  /// app-scoped notifier, not a stream this handler owns), so a second dispose
  /// must not re-run removal against a notifier that has already moved on, and
  /// nothing may publish afterwards.
  ///
  /// Deliberately not wired into [stop]: an OS stop ends the media session but
  /// leaves this handler and its [app_audio.PlaybackState] alive, and playback
  /// can be started again from the in-app transport. Dropping the liked-state
  /// listener there would leave the notification heart permanently stale.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _likedTracksState?.removeListener(_onLikedTracksChanged);
    _pendingStateTimer?.cancel();
    _pendingStateTimer = null;
  }

  void _onLikedTracksChanged() => _publishState();

  int? get _currentTrackId {
    final id = _currentItem?.id;
    return id == null ? null : int.tryParse(id);
  }

  /// The liked value the notification heart should render, or null when it is
  /// unknown (local-only track, another account's payload, not loaded yet).
  bool? _currentLiked() {
    final likedState = _likedTracksState;
    final trackId = _currentTrackId;
    if (likedState == null || trackId == null) return null;
    return likedState.isLiked(trackId) ?? _payloadLiked(likedState);
  }

  bool? _payloadLiked(LikedTracksState likedState) {
    final extras = _currentItem?.extras;
    final liked = extras?['isLiked'];
    final likedAccountId = extras?['likedAccountId'] as String?;
    if (liked is! bool || !likedState.acceptsPlaybackAccount(likedAccountId)) {
      return null;
    }
    return liked;
  }

  Future<void> _toggleLike() async {
    final likedState = _likedTracksState;
    final trackId = _currentTrackId;
    if (likedState == null || trackId == null) return;
    if (likedState.isToggling(trackId)) return;
    if (likedState.isLiked(trackId) == null) {
      final payloadLiked = _payloadLiked(likedState);
      // Without a known starting value a toggle would be a guess; leave liked
      // state untouched until the app has seeded it.
      if (payloadLiked == null) return;
      likedState.seedPlaybackValue(
        trackId,
        payloadLiked,
        sourceAccountId: _currentItem?.extras?['likedAccountId'] as String?,
      );
    }
    try {
      await likedState.toggle(trackId);
    } catch (_) {
      // LikedTracksState already rolled the optimistic write back; the control
      // simply re-renders the restored value.
    }
    _publishState(force: true);
  }

  just_audio.LoopMode _loopModeFor(
    audio_service.AudioServiceRepeatMode repeatMode,
  ) {
    switch (repeatMode) {
      case audio_service.AudioServiceRepeatMode.none:
        return just_audio.LoopMode.off;
      case audio_service.AudioServiceRepeatMode.one:
        return just_audio.LoopMode.one;
      case audio_service.AudioServiceRepeatMode.all:
      case audio_service.AudioServiceRepeatMode.group:
        return just_audio.LoopMode.all;
    }
  }

  audio_service.AudioServiceRepeatMode get _repeatMode {
    switch (_loopMode) {
      case just_audio.LoopMode.off:
        return audio_service.AudioServiceRepeatMode.none;
      case just_audio.LoopMode.one:
        return audio_service.AudioServiceRepeatMode.one;
      case just_audio.LoopMode.all:
        return audio_service.AudioServiceRepeatMode.all;
    }
  }

  void updateDuration() {
    _publishMediaItem();
    _publishState(force: true);
  }

  void _applySnapshot(PlaybackSnapshot snapshot) {
    _queueItems = [for (final cue in snapshot.cues) cue.mediaItem];
    _queueItemIds = [for (final cue in snapshot.cues) cue.queueItemId];
    _currentItem = snapshot.currentMediaItem;
    _queueIndex = snapshot.currentQueueIndex;
    _position = snapshot.localPosition;
    _bufferedPosition = snapshot.localDuration;
    _isPlaying = snapshot.playing;
    _activeVoiceCount = snapshot.activeVoiceCount;
    _playbackSpeed = snapshot.playbackSpeed;
    _pitchPreservationFallback = snapshot.pitchPreservationFallback;
    _processingState = _audioProcessingStateFor(snapshot.processingState);
  }

  audio_service.MediaItem _mediaItem() {
    final item = _currentItem;
    final activeVoiceCount =
        _activeVoiceCount == 0 && item != null ? 1 : _activeVoiceCount;
    final extras = <String, dynamic>{
      ...?item?.extras,
      'activeVoiceCount': activeVoiceCount,
      if (item?.id != null) 'dominantTrackId': item!.id,
      'notificationKind': activeVoiceCount > 1 ? 'layered_mix' : 'single_voice',
      'pitchPreservation': _pitchPreservationFallback ? 'fallback' : 'locked',
      if (_pitchPreservationFallback) 'pitchLockUnavailable': true,
    };
    final baseTitle = item?.title.trim();
    final title = baseTitle != null && baseTitle.isNotEmpty
        ? baseTitle
        : 'Open Music Player mix';
    return audio_service.MediaItem(
      id: item?.id ?? 'open-music-player-session',
      title:
          activeVoiceCount > 1 ? '$title · $activeVoiceCount layered' : title,
      artist: item?.artist ?? 'Open Music Player',
      album: item?.album,
      duration: item?.duration ?? _bufferedPosition,
      artUri: item?.artUri,
      extras: extras,
    );
  }

  void _publishQueue() {
    queue.add(_queueItems);
  }

  void _publishMediaItem() {
    mediaItem.add(_mediaItem());
  }

  void _publishState({bool force = false}) {
    if (_disposed) return;
    if (!force && !_shouldPublishStateNow()) {
      _scheduleTrailingStatePush();
      return;
    }
    _pendingStateTimer?.cancel();
    _pendingStateTimer = null;
    _publishStateNow();
  }

  bool _shouldPublishStateNow() {
    if (_statePushThrottle <= Duration.zero) return true;
    final last = _lastStatePushAt;
    if (last == null) return true;
    return !_now().difference(last).isNegative &&
        _now().difference(last) >= _statePushThrottle;
  }

  void _scheduleTrailingStatePush() {
    if (_pendingStateTimer != null) return;
    final last = _lastStatePushAt;
    if (last == null) {
      _publishStateNow();
      return;
    }
    final elapsed = _now().difference(last);
    final delay =
        elapsed.isNegative ? _statePushThrottle : _statePushThrottle - elapsed;
    _pendingStateTimer = Timer(
      delay <= Duration.zero ? Duration.zero : delay,
      () {
        _pendingStateTimer = null;
        _publishStateNow();
      },
    );
  }

  void _publishStateNow() {
    if (_disposed) return;
    _lastStatePushAt = _now();
    final liked = _currentLiked();
    playbackState.add(
      audio_service.PlaybackState(
        controls: [
          // Transport occupies the first three slots so the compact
          // notification stays prev / play-pause / next; the heart is an
          // expanded-only extra.
          audio_service.MediaControl.skipToPrevious,
          if (_isPlaying)
            audio_service.MediaControl.pause
          else
            audio_service.MediaControl.play,
          audio_service.MediaControl.skipToNext,
          audio_service.MediaControl.stop,
          if (liked != null) _likeControl(liked),
        ],
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: const {
          audio_service.MediaAction.seek,
          audio_service.MediaAction.seekForward,
          audio_service.MediaAction.seekBackward,
          audio_service.MediaAction.setShuffleMode,
          audio_service.MediaAction.setRepeatMode,
          audio_service.MediaAction.skipToQueueItem,
        },
        processingState: _processingState,
        playing: _isPlaying,
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        speed: _playbackSpeed,
        updateTime: _now(),
        queueIndex: _queueIndex,
        shuffleMode: _shuffleEnabled
            ? audio_service.AudioServiceShuffleMode.all
            : audio_service.AudioServiceShuffleMode.none,
        repeatMode: _repeatMode,
      ),
    );
  }

  audio_service.MediaControl _likeControl(bool liked) =>
      audio_service.MediaControl.custom(
        androidIcon:
            liked ? 'drawable/omp_favorite' : 'drawable/omp_favorite_border',
        label: liked ? 'Unlike' : 'Like',
        name: likeCustomActionName,
      );

  audio_service.AudioProcessingState _audioProcessingStateFor(
    just_audio.ProcessingState state,
  ) {
    switch (state) {
      case just_audio.ProcessingState.idle:
        return audio_service.AudioProcessingState.idle;
      case just_audio.ProcessingState.loading:
        return audio_service.AudioProcessingState.loading;
      case just_audio.ProcessingState.buffering:
        return audio_service.AudioProcessingState.buffering;
      case just_audio.ProcessingState.ready:
        return audio_service.AudioProcessingState.ready;
      case just_audio.ProcessingState.completed:
        return audio_service.AudioProcessingState.completed;
    }
  }
}
