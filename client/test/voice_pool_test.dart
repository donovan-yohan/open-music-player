import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  late DefaultTimelineClock clock;
  late List<FakeVoice> voices;
  late FakeResolver resolver;
  late Set<String> capacityFailures;
  late VoicePool pool;

  setUp(() async {
    clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026, 1, 1),
      uiTickInterval: const Duration(hours: 1),
    );
    voices = [];
    resolver = FakeResolver();
    capacityFailures = {};
    pool = VoicePool(
      clock: clock,
      maxVoices: 4,
      warmSpareVoices: 1,
      prepareTimeout: const Duration(milliseconds: 30),
      voiceFactory: () {
        final voice = FakeVoice('v${voices.length}', capacityFailures);
        voices.add(voice);
        return voice;
      },
      resolver: resolver,
    );
    await pool.start();
  });

  tearDown(() async {
    await pool.dispose();
    await clock.dispose();
  });

  test(
      'diffs active clips, reuses stable voices, and releases before acquiring',
      () async {
    await pool.loadMix(_model(['a', 'b']));
    expect(pool.activeVoices.keys, ['a']);
    final voiceForA = pool.activeVoices['a'];

    await pool.syncAt(6000, forceSeek: true);
    final voiceForB = pool.activeVoices['b'];
    expect(pool.activeVoices['a'], same(voiceForA));
    expect(voiceForB, isNotNull);
    expect(voices.where((voice) => voice.loadedSources.isNotEmpty).length, 2);

    await pool.syncAt(7000);
    expect(pool.activeVoices['a'], same(voiceForA));
    expect(pool.activeVoices['b'], same(voiceForB));
    expect((voiceForA as FakeVoice).loadedSources.length, 1);

    await pool.syncAt(11000, forceSeek: true);
    expect(pool.activeVoices.keys, ['b']);
    expect(voiceForA.releaseCount, 1);
    expect(pool.activeVoices['b'], same(voiceForB));
  });

  test('enforces a four active voice cap while keeping a warm spare idle',
      () async {
    await pool.loadMix(_fourAtZero());
    expect(pool.activeVoices.length, 4);
    expect(voices.length, 5);
    expect(pool.activeVoices.length,
        lessThanOrEqualTo(TimelineModel.maxConcurrentVoices));
  });

  test('scrub commit starts all ready active layers together', () async {
    await pool.loadMix(_model(['a', 'b']));
    await _play(clock, pool);
    await pool.syncAt(6000, forceSeek: true);
    await _waitUntil(() => pool.activeVoices.containsKey('b'));

    final a = pool.activeVoices['a'] as FakeVoice;
    final b = pool.activeVoices['b'] as FakeVoice;
    expect(a.playOrder, isNotNull);
    expect(b.playOrder, isNotNull);
    expect(a.seekLog.last, 6000);
    expect(b.currentLocalPositionMs, 1000);
  });

  test('scrub updates do not delay the final committed seek', () async {
    resolver.delayByClip['b'] = const Duration(milliseconds: 80);
    await pool.loadMix(_model(['a', 'b']));
    await _play(clock, pool);

    final a = pool.activeVoices['a'] as FakeVoice;
    clock.beginScrub();
    clock.updateScrub(6000);
    await clock.endScrub(1000);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(pool.activeVoices.keys, ['a']);
    expect(a.seekLog, contains(1000));
  });

  test('force scrub commit holds clock until active voices seek', () async {
    await pool.loadMix(_model(['a']));
    await _play(clock, pool);

    final a = pool.activeVoices['a'] as FakeVoice;
    final gate = Completer<void>();
    final seekStarted = a.blockNextSeek(gate);

    clock.beginScrub();
    await clock.endScrub(2000);
    await seekStarted;

    expect(clock.isBufferingHeld, isTrue);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(a.seekLog, contains(2000));
    expect(clock.isBufferingHeld, isFalse);
  });

  test('play realigns ready voices to the clock before resuming', () async {
    await pool.loadMix(_model(['a']));
    await clock.seek(4000);
    await Future<void>.delayed(Duration.zero);

    final a = pool.activeVoices['a'] as FakeVoice;
    await a.seekLocal(0);
    expect(a.currentLocalPositionMs, 0);

    await _play(clock, pool);
    await _waitUntil(() => a.isPlaying && a.currentLocalPositionMs == 4000);

    expect(a.seekLog, contains(4000));
  });

  test('preserved mix update keeps the active voice playing', () async {
    await pool.loadMix(TimelineModel(clips: [_clip('a', 0)]));
    await _play(clock, pool);

    final a = pool.activeVoices['a'] as FakeVoice;
    await _waitUntil(() => a.isPlaying);
    a.seekLog.clear();
    a.volumeLog.clear();
    final pauseCount = a.pauseCount;

    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0), _clip('b', 10000)]),
      preserveActivePlayback: true,
    );

    expect(pool.activeVoices['a'], same(a));
    expect(a.isPlaying, isTrue);
    expect(a.pauseCount, pauseCount);
    expect(a.seekLog, isEmpty);
    expect(a.releaseCount, 0);
    expect(pool.model.clips.map((clip) => clip.id), ['a', 'b']);
  });

  test('unchanged tempo tuning is not resent on steady sync ticks', () async {
    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip(
            'a',
            0,
            rateAutomation: const PlaybackRateAutomation(baseRate: 1.25),
          ),
        ],
      ),
    );

    final a = pool.activeVoices['a'] as FakeVoice;
    final speedCalls = a.speedLog.length;
    final pitchCalls = a.pitchLog.length;

    await pool.syncAt(0);
    await pool.syncAt(0);

    expect(a.speedLog.length, speedCalls);
    expect(a.pitchLog.length, pitchCalls);
  });

  test('small tempo ramp changes accumulate against the last applied rate',
      () async {
    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip(
            'a',
            0,
            rateAutomation: const PlaybackRateAutomation(
              segments: [
                PlaybackRateSegment(
                  startMs: 0,
                  endMs: 4000,
                  startRate: 1,
                  endRate: 1.004,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final a = pool.activeVoices['a'] as FakeVoice;
    final speedCalls = a.speedLog.length;

    await pool.syncAt(500);
    expect(a.speedLog.length, speedCalls);

    await pool.syncAt(1500);
    expect(a.speedLog.length, speedCalls + 1);
    expect(a.speedLog.last, closeTo(1.0015, 0.0001));
  });

  test('applies per-voice BPM transition rates during an overlap', () async {
    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip('a', 0, fadeOutMs: 5000, nativeBpm: 100),
          _clip('b', 5000, fadeInMs: 5000, nativeBpm: 125),
        ],
      ),
    );

    await pool.syncAt(7500, forceSeek: true);

    final a = pool.activeVoices['a'] as FakeVoice;
    final b = pool.activeVoices['b'] as FakeVoice;
    final aClip = pool.model.clips.firstWhere((clip) => clip.id == 'a');
    final bClip = pool.model.clips.firstWhere((clip) => clip.id == 'b');
    expect(a.speedLog.last, closeTo(aClip.playbackRateAt(7500), 0.0001));
    expect(a.pitchLog.last, closeTo(1, 0.0001));
    expect(b.speedLog.last, closeTo(bClip.playbackRateAt(7500), 0.0001));
    expect(b.pitchLog.last, closeTo(1, 0.0001));
    expect(
      b.currentLocalPositionMs,
      closeTo(bClip.sourcePositionAt(7500), 1),
    );
  });

  test('prepares both BPM-matched decks concurrently before resume', () async {
    await clock.seek(7500);
    final speedGate = Completer<void>();
    final firstSpeedStarted = voices.first.blockNextSetSpeed(speedGate);
    final load = pool.loadMix(
      TimelineModel(
        clips: [
          _clip('a', 0, fadeOutMs: 5000, nativeBpm: 100),
          _clip('b', 5000, fadeInMs: 5000, nativeBpm: 125),
        ],
      ),
    );

    await firstSpeedStarted;
    await Future<void>.delayed(Duration.zero);
    expect(
      voices[1].speedLog,
      isNotEmpty,
      reason: 'one slow deck must not hold back the peer tempo update',
    );
    speedGate.complete();
    await load;

    final a = pool.activeVoices['a'] as FakeVoice;
    final b = pool.activeVoices['b'] as FakeVoice;
    final seekGate = Completer<void>();
    final firstSeekStarted = a.blockNextSeek(seekGate);
    final play = _play(clock, pool);

    await firstSeekStarted;
    await Future<void>.delayed(Duration.zero);
    final bClip = pool.model.clips.firstWhere((clip) => clip.id == 'b');
    expect(b.seekLog.last, closeTo(bClip.sourcePositionAt(7500), 1));
    expect(a.isPlaying, isFalse);
    expect(b.isPlaying, isFalse);

    seekGate.complete();
    await play;
    await _waitUntil(() => a.isPlaying && b.isPlaying);
  });

  test('follow-tempo pitch mode shifts pitch with playback rate', () async {
    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip(
            'a',
            0,
            pitchMode: pitchModeFollowTempo,
            rateAutomation: const PlaybackRateAutomation(
              baseRate: 1.25,
              pitchMode: pitchModeFollowTempo,
            ),
          ),
        ],
      ),
    );

    final a = pool.activeVoices['a'] as FakeVoice;
    expect(a.speedLog.last, closeTo(1.25, 0.0001));
    expect(a.pitchLog.last, closeTo(1.25, 0.0001));
  });

  test('reports pitch fallback when key lock is unavailable', () async {
    for (final voice in voices) {
      voice.pitchSupported = false;
    }
    final fallbackEvents = <Set<String>>[];
    final fallbackSub =
        pool.pitchFallbackClipIdsStream.listen(fallbackEvents.add);

    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip(
            'a',
            0,
            rateAutomation: const PlaybackRateAutomation(baseRate: 1.25),
          ),
        ],
      ),
    );

    expect(pool.hasPitchFallback, isTrue);
    expect(pool.pitchFallbackClipIds, {'a'});
    expect(fallbackEvents.last, {'a'});

    await pool.syncAt(12000, forceSeek: true);

    expect(pool.hasPitchFallback, isFalse);
    expect(fallbackEvents.last, isEmpty);

    await fallbackSub.cancel();
  });

  test('release resets playback speed and pitch before voice reuse', () async {
    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip(
            'a',
            0,
            pitchMode: pitchModeFollowTempo,
            rateAutomation: const PlaybackRateAutomation(
              baseRate: 1.25,
              pitchMode: pitchModeFollowTempo,
            ),
          ),
        ],
      ),
    );

    final a = pool.activeVoices['a'] as FakeVoice;
    expect(a.pitchLog.last, closeTo(1.25, 0.0001));

    await pool.syncAt(12000, forceSeek: true);

    expect(a.releaseCount, 1);
    expect(a.speedLog.last, closeTo(1, 0.0001));
    expect(a.pitchLog.last, closeTo(1, 0.0001));
  });

  test('stop releases all teardown state after a level update fails', () async {
    for (final voice in voices) {
      voice.pitchSupported = false;
    }
    await pool.loadMix(
      TimelineModel(
        clips: [
          _clip(
            'a',
            0,
            rateAutomation: const PlaybackRateAutomation(baseRate: 1.25),
          ),
        ],
      ),
    );
    final voice = pool.activeVoices['a'] as FakeVoice;
    expect(pool.hasPitchFallback, isTrue);
    final gate = Completer<void>();
    final levelUpdateStarted = voice.blockNextSetVolume(gate);
    voice.nextSetVolumeError = StateError('level update failed');
    await levelUpdateStarted.timeout(const Duration(milliseconds: 500));
    clock.holdForBuffering();

    final stop = pool.stop();
    gate.complete();

    await expectLater(stop, throwsA(isA<StateError>()));
    expect(voice.releaseCount, 1);
    expect(pool.activeVoices, isEmpty);
    expect(pool.pitchFallbackClipIds, isEmpty);
    expect(clock.isBufferingHeld, isFalse);
  });

  test('prepare timeout starts ready voices and late-joins slow layer muted',
      () async {
    resolver.delayByClip['b'] = const Duration(milliseconds: 80);
    await pool.loadMix(_model(['a', 'b']));
    await pool.syncAt(6000, forceSeek: true);

    expect(pool.activeVoices.containsKey('a'), isTrue);
    expect(pool.activeVoices['b']?.isReady ?? false, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(pool.activeVoices.containsKey('b'), isTrue);
    final b = pool.activeVoices['b'] as FakeVoice;
    expect(b.volumeLog.first, 0);
  });

  test('stale generation load completion cannot mutate newer assignment',
      () async {
    resolver.delayByClip['b'] = const Duration(milliseconds: 80);
    await pool.loadMix(_model(['a', 'b']));
    unawaited(pool.syncAt(6000, forceSeek: true));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await pool.syncAt(0, forceSeek: true);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(pool.activeVoices.keys, ['a']);
    expect(pool.activeVoices.containsKey('b'), isFalse);
  });

  test('late join stops if voice is released after mute yield', () async {
    resolver.delayByClip['b'] = const Duration(milliseconds: 80);
    await pool.loadMix(_model(['a', 'b']));
    await _play(clock, pool);
    await pool.syncAt(6000, forceSeek: true);
    await _waitUntil(() => pool.activeVoices.containsKey('b'));

    final b = pool.activeVoices['b'] as FakeVoice;
    final muteGate = Completer<void>();
    final muteStarted = b.blockNextSetVolume(muteGate);
    await muteStarted;

    final release = pool.syncAt(0, forceSeek: true);
    await Future<void>.delayed(Duration.zero);
    muteGate.complete();
    await release;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(pool.activeVoices.keys, ['a']);
    expect(b.seekLog, isEmpty);
    expect(b.playOrder, isNull);
  });

  test('starvation hold releases when any active voice becomes ready',
      () async {
    resolver.delayByClip['a'] = const Duration(milliseconds: 80);
    unawaited(pool.loadMix(_model(['a'])));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(clock.isBufferingHeld, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 240));
    expect(clock.isBufferingHeld, isFalse);
  });

  test('decoder exhaustion drops the lowest-gain active voice fallback',
      () async {
    final quiet = _clip('quiet', 0, gainDb: -24);
    final loud = _clip('loud', 0);
    final mid = _clip('mid', 0, gainDb: -6);
    await pool.loadMix(TimelineModel(clips: [quiet, loud, mid]));
    final quietVoice = pool.activeVoices['quiet'] as FakeVoice;
    capacityFailures.add('enter');
    await pool
        .loadMix(TimelineModel(clips: [quiet, loud, mid, _clip('enter', 0)]));

    expect(pool.activeVoices.containsKey('enter'), isTrue);
    expect(pool.activeVoices.containsKey('quiet'), isFalse);
    expect(quietVoice.releaseCount, 1);
    expect(pool.activeVoices.length, lessThanOrEqualTo(4));
  });

  test('permanent entering source failure does not evict active voices',
      () async {
    final quiet = _clip('quiet', 0, gainDb: -24);
    final loud = _clip('loud', 0);
    final mid = _clip('mid', 0, gainDb: -6);
    await pool.loadMix(TimelineModel(clips: [quiet, loud, mid]));
    final quietVoice = pool.activeVoices['quiet'] as FakeVoice;
    resolver.permanentFailClipIds.add('enter');

    await pool
        .loadMix(TimelineModel(clips: [quiet, loud, mid, _clip('enter', 0)]));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(pool.activeVoices.keys, containsAll(['quiet', 'loud', 'mid']));
    expect(pool.activeVoices.containsKey('enter'), isFalse);
    expect(quietVoice.releaseCount, 0);
  });

  test('same clip id reloads when audio source changes', () async {
    const first = 'https://example.com/first.mp3';
    const second = 'https://example.com/second.mp3';
    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0, audioSourceRef: first)]),
    );
    final voice = pool.activeVoices['a'] as FakeVoice;
    expect(voice.loadedSources.map((uri) => uri.toString()), [first]);

    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0, audioSourceRef: second)]),
    );

    final newVoice = pool.activeVoices['a'] as FakeVoice;
    expect(voice.releaseCount, 1);
    expect(newVoice.loadedSources.map((uri) => uri.toString()), [second]);
  });

  test('same clip id reloads when resolved source identity changes', () async {
    const ref = 'track-a';
    final first = Uri.parse('https://example.com/first.mp3');
    final second = Uri.parse('https://example.com/second.mp3');
    final firstClip = _clip('a', 0, audioSourceRef: ref);
    final secondClip = _clip('a', 0, audioSourceRef: ref);
    expect(secondClip, firstClip);

    resolver.sourceByClipId['a'] = first;

    await pool.loadMix(
      TimelineModel(clips: [firstClip]),
    );
    final voice = pool.activeVoices['a'] as FakeVoice;
    expect(voice.loadedSources, [first]);

    resolver.sourceByClipId['a'] = second;
    await pool.loadMix(
      TimelineModel(clips: [secondClip]),
    );

    final newVoice = pool.activeVoices['a'] as FakeVoice;
    expect(voice.releaseCount, 1);
    expect(newVoice.loadedSources, [second]);
  });

  test('same descriptor-backed signed URL refresh keeps active voice',
      () async {
    const ref = '1';
    final first = Uri.parse('https://cdn.example/audio/1.mp3?sig=old#old');
    final refreshed = Uri.parse('https://cdn.example/audio/1.mp3?sig=new#new');

    resolver.sourceByClipId['a'] = first;
    resolver.descriptorByClipId['a'] = _descriptor(url: first.toString());
    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0, audioSourceRef: ref)]),
    );

    final voice = pool.activeVoices['a'] as FakeVoice;
    expect(voice.loadedSources, [first]);

    resolver.sourceByClipId['a'] = refreshed;
    resolver.descriptorByClipId['a'] = _descriptor(url: refreshed.toString());
    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0, audioSourceRef: ref)]),
    );

    expect(pool.activeVoices['a'], same(voice));
    expect(voice.releaseCount, 0);
    expect(voice.loadedSources, [first]);
  });

  test(
      'same descriptor-backed URL path reloads when descriptor metadata changes',
      () async {
    const ref = '1';
    final first = Uri.parse('https://cdn.example/audio/1.mp3?sig=old#old');
    final changed = Uri.parse('https://cdn.example/audio/1.mp3?sig=new#new');

    resolver.sourceByClipId['a'] = first;
    resolver.descriptorByClipId['a'] = _descriptor(url: first.toString());
    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0, audioSourceRef: ref)]),
    );

    final voice = pool.activeVoices['a'] as FakeVoice;

    resolver.sourceByClipId['a'] = changed;
    resolver.descriptorByClipId['a'] = _descriptor(
      url: changed.toString(),
      etag: 'etag-2',
    );
    await pool.loadMix(
      TimelineModel(clips: [_clip('a', 0, audioSourceRef: ref)]),
    );

    final newVoice = pool.activeVoices['a'] as FakeVoice;
    expect(voice.releaseCount, 1);
    expect(newVoice, isNot(same(voice)));
    expect(newVoice.loadedSources, [changed]);
  });

  test('drift monitor ignores small player jitter before hard resyncing',
      () async {
    await pool.dispose();
    await clock.dispose();

    var now = DateTime.utc(2026, 1, 1);
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    voices = [];
    resolver = FakeResolver();
    capacityFailures = {};
    pool = VoicePool(
      clock: clock,
      maxVoices: 4,
      warmSpareVoices: 0,
      prepareTimeout: const Duration(milliseconds: 30),
      driftCheckInterval: const Duration(milliseconds: 10),
      driftCorrectionThreshold: const Duration(milliseconds: 500),
      driftCorrectionCooldown: const Duration(seconds: 8),
      voiceFactory: () {
        final voice = FakeVoice('v${voices.length}', capacityFailures);
        voices.add(voice);
        return voice;
      },
      resolver: resolver,
    );
    await pool.start();
    final corrections = <DriftCorrectionEvent>[];
    final correctionSub = pool.driftCorrectionStream.listen(corrections.add);
    await pool.loadMix(TimelineModel(clips: [_clip('a', 0), _clip('b', 0)]));
    await _play(clock, pool);

    final voice = pool.activeVoices['a'] as FakeVoice;
    await _waitUntil(() => voice.seekLog.isNotEmpty);
    voice.seekLog.clear();
    now = now.add(const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(voice.seekLog, isEmpty);
    expect(voice.speedLog, contains(1.02));
    expect(
      corrections.map((event) => event.kind),
      contains(DriftCorrectionKind.speedNudge),
    );

    now = now.add(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(voice.seekLog, isNotEmpty);
    expect(
      corrections.map((event) => event.kind),
      contains(DriftCorrectionKind.hardSeek),
    );
    await correctionSub.cancel();
  });

  test('drift monitor resyncs a single active clip', () async {
    await pool.dispose();
    await clock.dispose();

    var now = DateTime.utc(2026, 1, 1);
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    voices = [];
    resolver = FakeResolver();
    capacityFailures = {};
    pool = VoicePool(
      clock: clock,
      maxVoices: 4,
      warmSpareVoices: 0,
      prepareTimeout: const Duration(milliseconds: 30),
      driftCheckInterval: const Duration(milliseconds: 10),
      driftCorrectionThreshold: const Duration(milliseconds: 50),
      driftCorrectionCooldown: const Duration(seconds: 8),
      gainUpdateInterval: const Duration(hours: 1),
      voiceFactory: () {
        final voice = FakeVoice('v${voices.length}', capacityFailures);
        voices.add(voice);
        return voice;
      },
      resolver: resolver,
    );
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [_clip('a', 0)]));
    await _play(clock, pool);

    final voice = pool.activeVoices['a'] as FakeVoice;
    await _waitUntil(() => voice.seekLog.isNotEmpty);
    voice.seekLog.clear();
    now = now.add(const Duration(milliseconds: 1000));
    await _waitUntil(() => voice.seekLog.contains(1000));

    expect(voice.seekLog.last, 1000);
  });

  test('drift correction stops if voice is released after mute yield',
      () async {
    await pool.dispose();
    await clock.dispose();

    var now = DateTime.utc(2026, 1, 1);
    clock = DefaultTimelineClock(
      now: () => now,
      uiTickInterval: const Duration(hours: 1),
    );
    voices = [];
    resolver = FakeResolver();
    capacityFailures = {};
    pool = VoicePool(
      clock: clock,
      maxVoices: 4,
      warmSpareVoices: 0,
      prepareTimeout: const Duration(milliseconds: 30),
      driftCheckInterval: const Duration(milliseconds: 10),
      driftCorrectionThreshold: const Duration(milliseconds: 50),
      driftCorrectionCooldown: const Duration(seconds: 8),
      gainUpdateInterval: const Duration(hours: 1),
      voiceFactory: () {
        final voice = FakeVoice('v${voices.length}', capacityFailures);
        voices.add(voice);
        return voice;
      },
      resolver: resolver,
    );
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [_clip('a', 0), _clip('b', 0)]));
    await _play(clock, pool);
    await pool.syncAt(0);

    final a = pool.activeVoices['a'] as FakeVoice;
    await _waitUntil(() => a.seekLog.isNotEmpty);
    a.seekLog.clear();
    final muteGate = Completer<void>();
    final muteStarted = a.blockNextSetVolume(muteGate);
    now = now.add(const Duration(milliseconds: 1000));
    await muteStarted;

    final release = pool.syncAt(20000, forceSeek: true);
    await Future<void>.delayed(Duration.zero);
    muteGate.complete();
    await release;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(pool.activeVoices.containsKey('a'), isFalse);
    expect(a.seekLog, isEmpty);
  });
}

TimelineModel _model(List<String> ids) => TimelineModel(
      clips: [
        if (ids.contains('a')) _clip('a', 0, fadeOutMs: 6000),
        if (ids.contains('b')) _clip('b', 5000, fadeInMs: 6000),
      ],
    );

TimelineModel _fourAtZero() => TimelineModel(
      clips: [
        for (final id in ['a', 'b', 'c', 'd']) _clip(id, 0)
      ],
    );

MixClip _clip(
  String id,
  int startMs, {
  int fadeInMs = 0,
  int fadeOutMs = 0,
  double gainDb = 0,
  String? audioSourceRef,
  double? nativeBpm,
  String pitchMode = pitchModePreserve,
  PlaybackRateAutomation? rateAutomation,
}) {
  return MixClip(
    placement: TimelineClip.clamped(
      id: id,
      trackId: id,
      sourceDurationMs: 20000,
      sourceStartMs: 0,
      sourceEndMs: 10000,
      timelineStartMs: startMs,
    ),
    audioSourceRef: audioSourceRef ?? 'https://example.com/$id.mp3',
    pitchMode: pitchMode,
    rateAutomation: rateAutomation,
    envelope: GainEnvelope(
        fadeInMs: fadeInMs, fadeOutMs: fadeOutMs, baseGainDb: gainDb),
    tempo: ClipTempoMetadata(
      nativeBpm: nativeBpm,
      bpmConfidence: nativeBpm == null ? null : 0.95,
    ),
  );
}

class FakeResolver implements EngineAudioSourceResolver {
  final delayByClip = <String, Duration>{};
  final failClipIds = <String>{};
  final permanentFailClipIds = <String>{};
  final sourceByClipId = <String, Uri>{};
  final descriptorByClipId = <String, SignedAudioDescriptor>{};
  final warmed = <String>[];

  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async {
    final delay = delayByClip[clip.id];
    if (delay != null) await Future<void>.delayed(delay);
    if (permanentFailClipIds.contains(clip.id)) {
      throw StateError('source unavailable for ${clip.id}');
    }
    if (failClipIds.remove(clip.id)) {
      throw StateError('decoder exhausted for ${clip.id}');
    }
    return ResolvedAudioSource.remote(
      sourceByClipId[clip.id] ?? Uri.parse(clip.audioSourceRef),
      descriptorByClipId[clip.id],
    );
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {
    warmed.add(audioSourceRef);
  }
}

SignedAudioDescriptor _descriptor({
  required String url,
  String etag = 'etag-1',
}) {
  return SignedAudioDescriptor(
    trackId: 1,
    url: url,
    expiresAt: DateTime.utc(2026, 1, 1, 0, 5),
    contentType: 'audio/mpeg',
    sizeBytes: 1024,
    etag: etag,
    storageKeyVersion: 'v1',
  );
}

class FakeVoice implements Voice {
  FakeVoice(this.debugId, this.capacityFailures);

  static int _playCounter = 0;

  @override
  final String debugId;
  final Set<String> capacityFailures;
  final loadedSources = <Uri>[];
  final seekLog = <int>[];
  final volumeLog = <double>[];
  final speedLog = <double>[];
  final pitchLog = <double>[];
  final _events = StreamController<VoiceEvent>.broadcast();
  int releaseCount = 0;
  int pauseCount = 0;
  int? playOrder;
  int? _positionMs;
  bool _loaded = false;
  bool _ready = false;
  bool _playing = false;
  Completer<void>? _setVolumeGate;
  Completer<void>? _setVolumeStarted;
  Completer<void>? _seekGate;
  Completer<void>? _seekStarted;
  Completer<void>? _setSpeedGate;
  Completer<void>? _setSpeedStarted;
  Object? nextSetVolumeError;

  Future<void> blockNextSetVolume(Completer<void> gate) {
    _setVolumeGate = gate;
    final started = Completer<void>();
    _setVolumeStarted = started;
    return started.future;
  }

  Future<void> blockNextSeek(Completer<void> gate) {
    _seekGate = gate;
    final started = Completer<void>();
    _seekStarted = started;
    return started.future;
  }

  Future<void> blockNextSetSpeed(Completer<void> gate) {
    _setSpeedGate = gate;
    final started = Completer<void>();
    _setSpeedStarted = started;
    return started.future;
  }

  @override
  bool get isLoaded => _loaded;
  @override
  bool get isReady => _ready;
  @override
  bool get isPlaying => _playing;
  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    String? exhaustedClipId;
    for (final clipId in capacityFailures) {
      if (source.toString().contains('/$clipId.mp3')) {
        exhaustedClipId = clipId;
        break;
      }
    }
    if (exhaustedClipId != null) {
      capacityFailures.remove(exhaustedClipId);
      throw VoiceCapacityException('decoder exhausted for $exhaustedClipId');
    }
    loadedSources.add(source);
    _positionMs = initialLocalPositionMs;
    _loaded = true;
    _ready = true;
    _events.add(const VoiceEvent(VoiceEventKind.ready));
  }

  @override
  Future<void> seekLocal(int localPositionMs) async {
    seekLog.add(localPositionMs);
    final gate = _seekGate;
    if (gate != null) {
      _seekGate = null;
      _seekStarted?.complete();
      await gate.future;
    }
    _positionMs = localPositionMs;
  }

  @override
  Future<void> setVolume(double linearGain) async {
    volumeLog.add(linearGain);
    final gate = _setVolumeGate;
    if (gate != null) {
      _setVolumeGate = null;
      _setVolumeStarted?.complete();
      await gate.future;
    }
    final error = nextSetVolumeError;
    nextSetVolumeError = null;
    if (error != null) throw error;
  }

  @override
  Future<void> setSpeed(double rate) async {
    speedLog.add(rate);
    final gate = _setSpeedGate;
    if (gate != null) {
      _setSpeedGate = null;
      _setSpeedStarted?.complete();
      await gate.future;
    }
  }

  bool pitchSupported = true;

  @override
  Future<bool> setPitch(double factor) async {
    pitchLog.add(factor);
    return pitchSupported;
  }

  @override
  Future<void> play() async {
    _playing = true;
    playOrder ??= ++_playCounter;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing = false;
    playOrder = null;
  }

  @override
  Future<void> release() async {
    releaseCount++;
    _loaded = false;
    _ready = false;
    _playing = false;
    playOrder = null;
  }

  @override
  Future<void> dispose() async => _events.close();

  @override
  int? get currentLocalPositionMs => _positionMs;

  @override
  int? driftMs(int expectedLocalPositionMs) {
    final position = _positionMs;
    if (position == null) return null;
    return position - expectedLocalPositionMs;
  }

  @override
  Future<void> resync(int expectedLocalPositionMs) =>
      seekLocal(expectedLocalPositionMs);
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not met within $timeout');
}

Future<void> _play(DefaultTimelineClock clock, VoicePool pool) async {
  pool.beginCoordinatedResume();
  try {
    await clock.play();
    await pool.playActiveFromClock();
  } finally {
    pool.endCoordinatedResume();
  }
}
