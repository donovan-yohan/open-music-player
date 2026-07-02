import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;

import '../engine/playback_engine.dart';

class MixAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.SeekHandler {
  MixAudioHandler({required PlaybackEngine engine}) : _engine = engine {
    mediaItem.add(_mediaItem());
    _subscriptions
      ..add(_engine.positionMsStream.listen((_) => _publishState()))
      ..add(_engine.isPlayingStream.listen((_) => _publishState()))
      ..add(_engine.nowPlayingStream.listen((_) {
        mediaItem.add(_mediaItem());
        _publishState();
      }));
    _publishState();
  }

  final PlaybackEngine _engine;
  final List<StreamSubscription> _subscriptions = [];

  @override
  Future<void> play() => _engine.play();

  @override
  Future<void> pause() => _engine.pause();

  @override
  Future<void> seek(Duration position) => _engine.seek(position.inMilliseconds);

  @override
  Future<void> stop() async {
    await _engine.pause();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    return super.stop();
  }

  void updateDuration() {
    mediaItem.add(_mediaItem());
    _publishState();
  }

  audio_service.MediaItem _mediaItem() => audio_service.MediaItem(
        id: 'mix-engine-phase-2',
        title: 'Mix engine Phase 2 proof',
        artist: 'Open Music Player debug',
        duration: Duration(milliseconds: _engine.durationMs),
      );

  void _publishState() {
    playbackState.add(
      audio_service.PlaybackState(
        controls: [
          if (_engine.isPlaying)
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
        processingState: audio_service.AudioProcessingState.ready,
        playing: _engine.isPlaying,
        updatePosition: Duration(milliseconds: _engine.positionMs),
        bufferedPosition: Duration(milliseconds: _engine.positionMs),
        speed: 1,
        updateTime: DateTime.now(),
      ),
    );
  }
}
