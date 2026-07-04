import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:just_audio/just_audio.dart' as just_audio;

import 'playback_session.dart';
import 'playback_state.dart' as app_audio;

const defaultNotificationStateThrottle = Duration(milliseconds: 750);

class MixAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.SeekHandler {
  MixAudioHandler({
    required app_audio.PlaybackState playbackState,
    Duration statePushThrottle = defaultNotificationStateThrottle,
    DateTime Function()? now,
  })  : _playbackState = playbackState,
        _statePushThrottle = statePushThrottle,
        _now = now ?? DateTime.now {
    _applySnapshot(playbackState.snapshot);
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
    _publishState(force: true);
  }

  final app_audio.PlaybackState _playbackState;
  final Duration _statePushThrottle;
  final DateTime Function() _now;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  List<audio_service.MediaItem> _queueItems = const [];
  audio_service.MediaItem? _currentItem;
  int? _queueIndex;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isPlaying = false;
  int _activeVoiceCount = 0;
  audio_service.AudioProcessingState _processingState =
      audio_service.AudioProcessingState.ready;
  DateTime? _lastStatePushAt;
  Timer? _pendingStateTimer;

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

  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _pendingStateTimer?.cancel();
    _pendingStateTimer = null;
  }

  void updateDuration() {
    _publishMediaItem();
    _publishState(force: true);
  }

  void _applySnapshot(PlaybackSnapshot snapshot) {
    _queueItems = [for (final cue in snapshot.cues) cue.mediaItem];
    _currentItem = snapshot.currentMediaItem;
    _queueIndex = snapshot.currentQueueIndex;
    _position = snapshot.localPosition;
    _bufferedPosition = snapshot.localDuration;
    _isPlaying = snapshot.playing;
    _activeVoiceCount = snapshot.activeVoiceCount;
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
    _lastStatePushAt = _now();
    playbackState.add(
      audio_service.PlaybackState(
        controls: [
          audio_service.MediaControl.skipToPrevious,
          if (_isPlaying)
            audio_service.MediaControl.pause
          else
            audio_service.MediaControl.play,
          audio_service.MediaControl.skipToNext,
          audio_service.MediaControl.stop,
        ],
        systemActions: const {
          audio_service.MediaAction.seek,
          audio_service.MediaAction.seekForward,
          audio_service.MediaAction.seekBackward,
        },
        processingState: _processingState,
        playing: _isPlaying,
        updatePosition: _position,
        bufferedPosition: _bufferedPosition,
        speed: 1,
        updateTime: _now(),
        queueIndex: _queueIndex,
      ),
    );
  }

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
