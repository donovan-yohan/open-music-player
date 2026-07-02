import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';

void main() {
  late DefaultTimelineClock clock;
  late List<FakeVoice> voices;
  late VoicePool pool;

  setUp(() async {
    clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026, 1, 1),
      uiTickInterval: const Duration(hours: 1),
    );
    voices = [];
    pool = VoicePool(
      clock: clock,
      maxVoices: 2,
      voiceFactory: () {
        final voice = FakeVoice('v${voices.length}');
        voices.add(voice);
        return voice;
      },
    );
    await pool.start();
    await pool.loadClips(_overlapClips());
  });

  tearDown(() async {
    await pool.dispose();
    await clock.dispose();
  });

  test('diffs active clips without reloading stable voices', () async {
    expect(pool.activeVoices.keys, ['a']);
    expect(voices[0].loadedSources, [Uri.parse('https://example.com/a.mp3')]);

    await pool.syncAt(6000, forceSeek: true);
    final voiceForA = pool.activeVoices['a'];
    final voiceForB = pool.activeVoices['b'];

    expect(voiceForA, isNotNull);
    expect(voiceForB, isNotNull);
    expect(voiceForA, isNot(same(voiceForB)));
    expect(voices[0].loadedSources.length, 1);
    expect(voices[1].loadedSources, [Uri.parse('https://example.com/b.mp3')]);

    await pool.syncAt(7000);

    expect(pool.activeVoices['a'], same(voiceForA));
    expect(pool.activeVoices['b'], same(voiceForB));
    expect(voices[0].loadedSources.length, 1);
    expect(voices[1].loadedSources.length, 1);

    await pool.syncAt(11000);

    expect(pool.activeVoices.keys, ['b']);
    expect(voices[0].releaseCount, 1);
    expect(pool.activeVoices['b'], same(voiceForB));
  });

  test(
    'force sync after scrub seeks both active voices to global position',
    () async {
      await pool.syncAt(6000, forceSeek: true);
      final voiceForA = pool.activeVoices['a'] as FakeVoice;
      final voiceForB = pool.activeVoices['b'] as FakeVoice;

      await pool.syncAt(8000, forceSeek: true);

      expect(voiceForA.seekLog.last, 8000);
      expect(voiceForB.seekLog.last, 3000);
    },
  );

  test('pauses and resumes active voices from clock play state', () async {
    await clock.seek(6000);
    await pool.syncAt(6000, forceSeek: true);

    await clock.play();
    await Future<void>.delayed(Duration.zero);
    expect(voices[0].isPlaying, isTrue);
    expect(voices[1].isPlaying, isTrue);

    await clock.pause();
    await Future<void>.delayed(Duration.zero);
    expect(voices[0].isPlaying, isFalse);
    expect(voices[1].isPlaying, isFalse);
  });
}

List<MixVoiceClip> _overlapClips() => [
      MixVoiceClip(
        id: 'a',
        source: Uri.parse('https://example.com/a.mp3'),
        timelineStartMs: 0,
        durationMs: 10000,
        envelope: const GainEnvelope(fadeOutMs: 6000),
      ),
      MixVoiceClip(
        id: 'b',
        source: Uri.parse('https://example.com/b.mp3'),
        timelineStartMs: 5000,
        durationMs: 10000,
        envelope: const GainEnvelope(fadeInMs: 6000),
      ),
    ];

class FakeVoice implements Voice {
  FakeVoice(this.debugId);

  @override
  final String debugId;

  final loadedSources = <Uri>[];
  final seekLog = <int>[];
  final volumeLog = <double>[];
  final _events = StreamController<VoiceEvent>.broadcast();
  int releaseCount = 0;
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
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> release() async {
    releaseCount++;
    _loaded = false;
    _ready = false;
    _playing = false;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }

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
