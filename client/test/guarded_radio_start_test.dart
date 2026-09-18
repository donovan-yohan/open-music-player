import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'support/fake_voice.dart';

void main() {
  for (final seekBarrier in [1, 2]) {
    test('cancel at resume seek $seekBarrier fences actual voice dispatch',
        () async {
      final clock =
          DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
      final voice = _BarrierVoice();
      final engine =
          PlaybackEngine.withClock(clock: clock, voiceFactory: () => voice);
      final controller = QueueTimelineController(engine);
      await controller.setQueue([
        const MediaItem(
          id: '1',
          title: 'one',
          duration: Duration(seconds: 5),
          extras: {'url': 'https://example.com/1.mp3'},
        )
      ]);
      await pumpEventQueue();
      voice.arm(seekBarrier);
      var valid = true;
      final clockStarts = <bool>[];
      final sub = clock.isPlayingStream.listen((v) {
        if (v) clockStarts.add(v);
      });
      final play = engine.playGuarded(stillCurrent: () => valid);
      await voice.entered.future.timeout(const Duration(seconds: 2));
      valid = false;
      voice.gate.complete();
      await play;
      await pumpEventQueue();
      expect(voice.playCalls, 0,
          reason: 'fence before Voice.play, not compensating pause');
      if (seekBarrier == 1) expect(clockStarts, isEmpty);
      expect(clock.isPlaying, isFalse);
      // A later explicit command is not permanently poisoned by cancellation.
      await engine.play();
      expect(voice.playCalls, 1);
      await sub.cancel();
      await controller.dispose();
      await clock.dispose();
    });
  }
}

class _BarrierVoice extends FakeVoice {
  _BarrierVoice() : super('barrier');
  int? remaining;
  int playCalls = 0;
  late Completer<void> entered;
  late Completer<void> gate;
  void arm(int count) {
    remaining = count;
    entered = Completer<void>();
    gate = Completer<void>();
  }

  @override
  Future<void> seekLocal(int position) async {
    if (remaining != null) remaining = remaining! - 1;
    if (remaining == 0) {
      remaining = null;
      entered.complete();
      await gate.future;
    }
    await super.seekLocal(position);
  }

  @override
  Future<void> play() async {
    playCalls++;
    await super.play();
  }
}
