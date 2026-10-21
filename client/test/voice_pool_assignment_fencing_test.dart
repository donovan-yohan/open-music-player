import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_voice.dart';

class _DelayedResolver implements EngineAudioSourceResolver {
  final firstSource = Completer<ResolvedAudioSource>();

  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) {
    if (clip.id == 'a') return firstSource.future;
    return Future.value(ResolvedAudioSource.local(Uri.file('/${clip.id}.wav')));
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

MixClip _clip(String id, int start) => MixClip(
      audioSourceRef: id,
      placement: TimelineClip.clamped(
        id: id,
        trackId: id,
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 10000,
        timelineStartMs: start,
      ),
    );

void main() {
  test('superseded resolver cannot load old bytes onto a reassigned voice',
      () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026, 1, 1),
      uiTickInterval: const Duration(hours: 1),
    );
    final resolver = _DelayedResolver();
    final voice = FakeVoice('only-deck');
    final pool = VoicePool(
      clock: clock,
      resolver: resolver,
      maxVoices: 1,
      warmSpareVoices: 0,
      prepareTimeout: const Duration(milliseconds: 5),
      voiceFactory: () => voice,
    );
    addTearDown(() async {
      await pool.dispose();
      await clock.dispose();
    });
    await pool.start();
    await pool
        .loadMix(TimelineModel(clips: [_clip('a', 0), _clip('b', 20000)]));
    await pool.syncAt(20000);
    expect(pool.activeVoices['b'], same(voice));
    expect(voice.loads, [Uri.file('/b.wav')]);

    resolver.firstSource
        .complete(ResolvedAudioSource.local(Uri.file('/a.wav')));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(voice.loads, [Uri.file('/b.wav')],
        reason: 'stale source resolution must be rejected before native load');
    expect(pool.activeVoices['b'], same(voice));
  });
}
