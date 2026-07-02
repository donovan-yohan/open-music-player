import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio_service;

import '../engine/timeline_clock.dart';

/// Throwaway Phase 0 handler: keeps the debug mix proof attached to a media
/// session in the background and forwards coarse transport controls to the
/// TimelineClock. Full metadata/focus/notification behavior is intentionally
/// out of scope for this skeleton.
class DebugMixAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.SeekHandler {
  DebugMixAudioHandler({required TimelineClock clock}) : _clock = clock {
    mediaItem.add(_mediaItem());
    _subscriptions
      ..add(_clock.positionMsStream.listen((_) => _publishState()))
      ..add(_clock.isPlayingStream.listen((_) => _publishState()))
      ..add(_clock.isBufferingHeldStream.listen((_) => _publishState()));
    _publishState();
  }

  final TimelineClock _clock;
  final List<StreamSubscription> _subscriptions = [];

  @override
  Future<void> play() => _clock.play();

  @override
  Future<void> pause() => _clock.pause();

  @override
  Future<void> seek(Duration position) => _clock.seek(position.inMilliseconds);

  @override
  Future<void> stop() async {
    await _clock.pause();
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
    id: 'debug-mix-engine-phase-0',
    title: 'Mix engine Phase 0 proof',
    artist: 'Open Music Player debug',
    duration: Duration(milliseconds: _clock.durationMs),
  );

  void _publishState() {
    playbackState.add(
      audio_service.PlaybackState(
        controls: [
          if (_clock.isPlaying)
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
        processingState: _clock.isBufferingHeld
            ? audio_service.AudioProcessingState.buffering
            : audio_service.AudioProcessingState.ready,
        playing: _clock.isPlaying,
        updatePosition: Duration(milliseconds: _clock.positionMs),
        bufferedPosition: Duration(milliseconds: _clock.positionMs),
        speed: _clock.rate,
        updateTime: DateTime.now(),
      ),
    );
  }
}
