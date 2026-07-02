import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
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
    await clock.play();
    await pool.syncAt(6000, forceSeek: true);

    final a = pool.activeVoices['a'] as FakeVoice;
    final b = pool.activeVoices['b'] as FakeVoice;
    expect(a.playOrder, isNotNull);
    expect(b.playOrder, isNotNull);
    expect(a.seekLog.last, 6000);
    expect(b.currentLocalPositionMs, 1000);
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

MixClip _clip(String id, int startMs,
    {int fadeInMs = 0, int fadeOutMs = 0, double gainDb = 0}) {
  return MixClip(
    placement: TimelineClip.clamped(
      id: id,
      trackId: id,
      sourceDurationMs: 20000,
      sourceStartMs: 0,
      sourceEndMs: 10000,
      timelineStartMs: startMs,
    ),
    audioSourceRef: 'https://example.com/$id.mp3',
    envelope: GainEnvelope(
        fadeInMs: fadeInMs, fadeOutMs: fadeOutMs, baseGainDb: gainDb),
  );
}

class FakeResolver implements EngineAudioSourceResolver {
  final delayByClip = <String, Duration>{};
  final failClipIds = <String>{};
  final permanentFailClipIds = <String>{};
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
    return ResolvedAudioSource.remote(Uri.parse(clip.audioSourceRef), null);
  }

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {
    warmed.add(audioSourceRef);
  }
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
  final _events = StreamController<VoiceEvent>.broadcast();
  int releaseCount = 0;
  int? playOrder;
  int? _positionMs;
  bool _loaded = false;
  bool _ready = false;
  bool _playing = false;

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
    _positionMs = localPositionMs;
  }

  @override
  Future<void> setVolume(double linearGain) async {
    volumeLog.add(linearGain);
  }

  @override
  Future<void> setSpeed(double rate) async {}

  @override
  Future<void> play() async {
    _playing = true;
    playOrder ??= ++_playCounter;
  }

  @override
  Future<void> pause() async {
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
