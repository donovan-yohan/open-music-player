import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:just_audio/just_audio.dart' as just_audio;

import '../engine/playback_engine.dart';
import 'playback_state.dart' as app_audio;

typedef MixMediaItemLookup = audio_service.MediaItem? Function(String trackId);

const defaultNotificationStateThrottle = Duration(milliseconds: 750);

String mixIdentity(
  MixNowPlayingInfo info, {
  audio_service.MediaItem? dominantItem,
}) {
  final dominantId = dominantItem?.id ?? info.trackId;
  if (info.activeVoiceCount == 1 && dominantId != null) return dominantId;
  if (info.activeVoiceCount > 1) {
    return 'mix:${info.clipId ?? dominantId ?? 'layered'}';
  }
  return dominantId ?? 'open-music-player-mix';
}

String mixTitle(
  MixNowPlayingInfo info, {
  audio_service.MediaItem? dominantItem,
}) {
  final dominantTitle = dominantItem?.title.trim();
  final baseTitle = dominantTitle != null && dominantTitle.isNotEmpty
      ? dominantTitle
      : 'Open Music Player mix';
  if (info.activeVoiceCount > 1) {
    return '$baseTitle · ${info.activeVoiceCount} layered';
  }
  return baseTitle;
}

class MixAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.SeekHandler {
  MixAudioHandler({
    required PlaybackEngine engine,
    app_audio.PlaybackState? playbackState,
    MixMediaItemLookup? mediaItemForTrackId,
    Duration statePushThrottle = defaultNotificationStateThrottle,
    DateTime Function()? now,
  })  : _engine = engine,
        _playbackState = playbackState,
        _mediaItemForTrackId = mediaItemForTrackId,
        _statePushThrottle = statePushThrottle,
        _now = now ?? DateTime.now {
    _currentItem = playbackState?.currentItem;
    _position = Duration(milliseconds: engine.positionMs);
    _bufferedPosition = _position;
    _isPlaying = playbackState?.isPlaying ?? engine.isPlaying;
    mediaItem.add(_mediaItem());
    _subscriptions
      ..add(
        _engine.isPlayingStream.listen((isPlaying) {
          if (_playbackState == null) _isPlaying = isPlaying;
          _publishState(force: true);
        }),
      )
      ..add(
        _engine.nowPlayingStream.listen((info) {
          _nowPlaying = info;
          _publishMediaItem();
          _publishState(force: true);
        }),
      );
    if (playbackState != null) {
      _subscriptions
        ..add(
          playbackState.playerStateStream.listen((state) {
            _isPlaying = state.playing;
            _processingState = _audioProcessingStateFor(state.processingState);
            _publishState(force: true);
          }),
        )
        ..add(
          playbackState.timelinePositionMsStream.listen((positionMs) {
            _position = Duration(milliseconds: positionMs);
            _bufferedPosition = _position;
            _publishState();
          }),
        )
        ..add(
          playbackState.currentMediaItemStream.listen((item) {
            _currentItem = item;
            _publishMediaItem();
            _publishState(force: true);
          }),
        );
    } else {
      _subscriptions.add(
        _engine.positionMsStream.listen((positionMs) {
          _position = Duration(milliseconds: positionMs);
          _bufferedPosition = _position;
          _publishState();
        }),
      );
    }
    _publishState(force: true);
  }

  final PlaybackEngine _engine;
  final app_audio.PlaybackState? _playbackState;
  final MixMediaItemLookup? _mediaItemForTrackId;
  final Duration _statePushThrottle;
  final DateTime Function() _now;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  MixNowPlayingInfo? _nowPlaying;
  audio_service.MediaItem? _currentItem;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isPlaying = false;
  audio_service.AudioProcessingState _processingState =
      audio_service.AudioProcessingState.ready;
  DateTime? _lastStatePushAt;
  Timer? _pendingStateTimer;

  @override
  Future<void> play() => _engine.play();

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> seek(Duration position) async {
    await _engine.seek(position.inMilliseconds);
    _position = position;
    _publishState(force: true);
  }

  @override
  Future<void> stop() async {
    await _engine.pause();
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

  audio_service.MediaItem _mediaItem() {
    final info = _nowPlaying ??
        MixNowPlayingInfo(
          clipId: null,
          trackId: _currentItem?.id,
          activeVoiceCount: _currentItem == null ? 0 : 1,
        );
    final dominant = _dominantMediaItem(info);
    final extras = <String, dynamic>{
      ...?dominant?.extras,
      'activeVoiceCount': info.activeVoiceCount,
      if (info.trackId != null) 'dominantTrackId': info.trackId,
      'notificationKind':
          info.activeVoiceCount > 1 ? 'layered_mix' : 'single_voice',
    };
    return audio_service.MediaItem(
      id: mixIdentity(info, dominantItem: dominant),
      title: mixTitle(info, dominantItem: dominant),
      artist: dominant?.artist ?? 'Open Music Player',
      album: dominant?.album,
      duration: _durationForNotification(dominant),
      artUri: dominant?.artUri,
      extras: extras,
    );
  }

  audio_service.MediaItem? _dominantMediaItem(MixNowPlayingInfo info) {
    final trackId = info.trackId;
    if (trackId != null) {
      final explicit = _mediaItemForTrackId?.call(trackId);
      if (explicit != null) return explicit;
      for (final item
          in _playbackState?.queue ?? const <audio_service.MediaItem>[]) {
        if (item.id == trackId) return item;
      }
    }
    if (_currentItem?.id == trackId || trackId == null) return _currentItem;
    return null;
  }

  Duration _durationForNotification(audio_service.MediaItem? dominant) {
    if (_engine.durationMs > 0) {
      return Duration(milliseconds: _engine.durationMs);
    }
    return dominant?.duration ?? Duration.zero;
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
          if (_isPlaying)
            audio_service.MediaControl.pause
          else
            audio_service.MediaControl.play,
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
