import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

const _deadline = Duration(seconds: 2);

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

class _RaceVoice extends FakeVoice {
  _RaceVoice(super.debugId);

  _Gate? pauseGate;
  _Gate? loadGate;
  Object? loadError;
  Object? releaseError;
  final eventBus = StreamController<VoiceEvent>.broadcast();
  @override
  Stream<VoiceEvent> get events => eventBus.stream;
  int pauses = 0;
  int releases = 0;
  final gains = <double>[];
  final released = Completer<void>();

  @override
  Future<void> pause() async {
    pauses++;
    final gate = pauseGate;
    pauseGate = null;
    if (gate != null) await gate.wait();
    await super.pause();
  }

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    final gate = loadGate;
    loadGate = null;
    if (gate != null) await gate.wait();
    final error = loadError;
    loadError = null;
    if (error != null) {
      eventBus.add(VoiceEvent(VoiceEventKind.error, error: error));
      throw error;
    }
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
    eventBus.add(const VoiceEvent(VoiceEventKind.ready));
  }

  @override
  Future<void> setVolume(double linearGain) async => gains.add(linearGain);

  @override
  Future<void> release() async {
    releases++;
    final error = releaseError;
    if (error != null) throw error;
    await super.release();
    if (!released.isCompleted) released.complete();
  }

  @override
  Future<void> dispose() async {
    await eventBus.close();
    await super.dispose();
  }
}

class _LeaseResolver implements EngineAudioSourceResolver {
  int acquired = 0;
  int released = 0;
  final releaseEvents = StreamController<void>.broadcast();

  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async {
    acquired++;
    return ResolvedAudioSource.local(Uri.file('/${clip.audioSourceRef}.wav'),
        onRelease: () async {
      released++;
      releaseEvents.add(null);
    });
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

MixClip _clip(String id) => MixClip(
      audioSourceRef: id,
      placement: TimelineClip.clamped(
        id: id,
        trackId: id,
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 10000,
        timelineStartMs: 0,
      ),
    );

class _Fixture {
  _Fixture() {
    pool = VoicePool(
      clock: clock,
      resolver: resolver,
      maxVoices: 2,
      warmSpareVoices: 1,
      prepareTimeout: const Duration(milliseconds: 10),
      driftCheckInterval: const Duration(hours: 1),
      gainUpdateInterval: const Duration(hours: 1),
      voiceFactory: () {
        final voice = _RaceVoice('v${voices.length}');
        voices.add(voice);
        return voice;
      },
    );
    addTearDown(() async {
      for (final gate in gates) {
        gate.open();
      }
      await pool.dispose();
      await clock.dispose();
      await resolver.releaseEvents.close();
    });
  }

  final clock = DefaultTimelineClock(
    now: () => DateTime.utc(2026, 1, 1),
    uiTickInterval: const Duration(hours: 1),
  );
  final resolver = _LeaseResolver();
  final voices = <_RaceVoice>[];
  final gates = <_Gate>[];
  late final VoicePool pool;

  _Gate gate() {
    final gate = _Gate();
    gates.add(gate);
    return gate;
  }

  Future<void> stopAndCheckLeases() async {
    await pool.stop().timeout(_deadline);
    expect(pool.activeVoices, isEmpty);
    expect(voices.where((v) => v.isLoaded), isEmpty);
    expect(resolver.released, resolver.acquired);
    expect(clock.isBufferingHeld, isFalse);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playQueue returns original load failure with safe owner feedback',
      () async {
    SharedPreferences.setMockInitialValues({});
    final f = _Fixture();
    final engine = PlaybackEngine(clock: f.clock, voicePool: f.pool);
    final disposed = engine.playbackErrors.drain<void>();
    final playback = PlaybackState(engine,
        persistenceDebounce: const Duration(hours: 1),
        signedAudioUrlService:
            SignedAudioUrlService.withRequester((body) async => {
                  'urls': [
                    for (final id in body['trackIds'] as List)
                      {
                        'trackId': id,
                        'url': 'https://fixture.invalid/$id.mp3',
                        'expiresAt': DateTime.utc(2030).toIso8601String(),
                      },
                  ],
                  'unavailable': <Map<String, dynamic>>[],
                }));
    addTearDown(() async {
      playback.dispose();
      await disposed.timeout(_deadline);
    });
    await engine.start();
    final failure = PlayerException(-11828,
        'decoder rejected https://fixture.invalid/audio?token=fixture', null);
    f.voices.first.loadError = failure;
    await expectLater(
      playback.playQueue([
        {
          'id': 1,
          'title': 'Failure fixture',
          'duration': 10,
        },
      ]),
      throwsA(same(failure)),
    );
    expect(playback.playbackError, 'Playback failed before audio could start.');
    expect(playback.isResolvingSignedUrl, isFalse);
    expect(playback.isPlaying, isFalse);
    expect(f.resolver.released, f.resolver.acquired);
    await playback.playQueue([
      {'id': 1, 'title': 'Retry fixture', 'duration': 10},
    ]);
    expect(playback.playbackError, isNull);
    expect(playback.isPlaying, isTrue);
    await playback.pause();
  });

  test('stop supersedes held force seek without mutating reassigned voices',
      () async {
    final f = _Fixture();
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [_clip('a'), _clip('b')]));
    final a = f.pool.activeVoices['a']! as _RaceVoice;
    final b = f.pool.activeVoices['b']! as _RaceVoice;
    final paused = f.gate();
    a.pauseGate = paused;
    final seeking = f.pool.syncAt(0, forceSeek: true);
    await paused.entered.future.timeout(_deadline);
    await f.stopAndCheckLeases();
    final replacing = f.pool.loadMix(TimelineModel(clips: [_clip('new')]));
    // start() is queued after the old sync; release that sync before awaiting.
    final restarting = f.pool.start();
    final aGains = a.gains.length;
    final bPauses = b.pauses;
    paused.open();
    await seeking.timeout(_deadline);
    await replacing.timeout(_deadline);
    await restarting.timeout(_deadline);
    expect(a.gains.length, aGains);
    expect(b.pauses, bPauses);
    expect(f.pool.activeVoices.keys, ['new']);
    await f.stopAndCheckLeases();
  });

  test('stopped pending load failure is retired without poisoning replacement',
      () async {
    final f = _Fixture();
    await f.pool.start();
    final loading = f.gate();
    f.voices.first
      ..loadGate = loading
      ..loadError = StateError('stale failure');
    await f.pool.loadMix(TimelineModel(clips: [_clip('a')]));
    await loading.entered.future.timeout(_deadline);
    final stopped = f.pool.stop();
    final stoppingRelease = f.voices.first.released.future;
    loading.open();
    await stoppingRelease.timeout(_deadline);
    await stopped.timeout(_deadline);
    await f.pool.loadMix(TimelineModel(clips: [_clip('new')]));
    await f.pool.start();
    expect(f.pool.activeVoices['new']?.isReady, isTrue);
    await f.stopAndCheckLeases();
  });

  test('failed cleanup remains a real failure and retains its source lease',
      () async {
    final f = _Fixture();
    await f.pool.start();
    final failure = StateError('decoder rejected');
    f.voices.first
      ..loadError = failure
      ..releaseError = StateError('native unload failed');
    await expectLater(f.pool.loadMix(TimelineModel(clips: [_clip('a')])),
        throwsA(same(failure)));
    expect(f.resolver.acquired, 1);
    expect(f.resolver.released, 0,
        reason: 'failed native unload must retain ownership of its bytes');
    await f.pool.dispose();
    expect(f.resolver.released, 1);
  });

  test('current load returns the original failure and ordinary retry recovers',
      () async {
    final f = _Fixture();
    await f.pool.start();
    final failure = StateError('original decoder rejection');
    f.voices.first.loadError = failure;
    await expectLater(
      f.pool.loadMix(TimelineModel(clips: [_clip('a')])),
      throwsA(same(failure)),
    );
    expect(f.pool.activeVoices, isEmpty);
    expect(f.resolver.released, f.resolver.acquired);
    expect(f.clock.isBufferingHeld, isFalse);
    await f.pool.syncAt(0, forceSeek: true);
    expect(f.pool.activeVoices['a']?.isReady, isTrue);
    await f.stopAndCheckLeases();
  });

  test('engine owner Future preserves the actual player load error', () async {
    final f = _Fixture();
    final engine = PlaybackEngine(clock: f.clock, voicePool: f.pool);
    addTearDown(engine.dispose);
    await engine.start();
    final failure =
        PlayerException(-11828, 'decoder rejected fixture audio', null);
    f.voices.first.loadError = failure;
    await expectLater(engine.loadMix(TimelineModel(clips: [_clip('a')])),
        throwsA(same(failure)));
    expect(f.resolver.released, f.resolver.acquired);
  });

  test('timed out current load retains terminal error without automatic retry',
      () async {
    final f = _Fixture();
    await f.pool.start();
    final loading = f.gate();
    f.voices.first
      ..loadGate = loading
      ..loadError = StateError('late current failure');
    final terminal = f.pool.voiceStatusStream.firstWhere((status) =>
        status['a'] == VoiceEventKind.error &&
        f.pool.activeVoices.isEmpty &&
        !f.clock.isBufferingHeld);
    await f.pool.loadMix(TimelineModel(clips: [_clip('a')]));
    expect(f.clock.isBufferingHeld, isTrue);
    final retirement = f.resolver.releaseEvents.stream.first;
    loading.open();
    await terminal.timeout(_deadline);
    await retirement.timeout(_deadline);
    expect(f.pool.activeVoices, isEmpty);
    expect(f.clock.isBufferingHeld, isFalse);
    expect(f.resolver.acquired, 1);
    await f.pool.syncAt(0);
    expect(f.pool.activeVoices['a']?.isReady, isTrue);
    await f.stopAndCheckLeases();
  });

  test('force seek survives load retirement during another active pause',
      () async {
    final f = _Fixture();
    await f.pool.start();
    final failedLoad = f.gate();
    f.voices[1]
      ..loadGate = failedLoad
      ..loadError = StateError('original decoder rejection');
    await f.pool.loadMix(TimelineModel(clips: [_clip('a'), _clip('b')]));
    await failedLoad.entered.future.timeout(_deadline);
    expect(f.pool.activeVoiceCount, 2);

    final paused = f.gate();
    final a = f.pool.activeVoices['a']! as _RaceVoice;
    a.pauseGate = paused;
    final seeking = f.pool.syncAt(0, forceSeek: true);
    final seekingResult = expectLater(seeking, completes);
    await paused.entered.future.timeout(_deadline);
    final retirement = f.resolver.releaseEvents.stream.first;
    failedLoad.open();
    await retirement.timeout(_deadline);
    expect(f.pool.activeVoices.containsKey('b'), isFalse);
    paused.open();
    await seekingResult;
    expect(f.pool.activeVoices['a'], same(a));
    expect(f.pool.activeVoiceCount, lessThanOrEqualTo(2));
    await f.stopAndCheckLeases();
  });
}
