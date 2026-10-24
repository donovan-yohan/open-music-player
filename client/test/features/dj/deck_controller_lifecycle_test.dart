import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';

import '../../support/fake_voice.dart';

DjDeckLoad seed(String id) => DjDeckLoad(
      trackRef: id,
      localUri: Uri.file('/$id.wav'),
      durationMs: 10000,
    );

class LifetimeVoice extends FakeVoice {
  LifetimeVoice() : super('dj-lifetime');
  final lifetimes = <Completer<void>>[];

  @override
  Future<void> play() {
    unawaited(super.play());
    final lifetime = Completer<void>();
    lifetimes.add(lifetime);
    return lifetime.future;
  }

  void finish() {
    for (final lifetime in lifetimes) {
      if (!lifetime.isCompleted) lifetime.complete();
    }
  }

  @override
  Future<void> pause() async {
    await super.pause();
    finish();
  }

  @override
  Future<void> release() async {
    await super.release();
    finish();
  }
}

class GatedResolver implements EngineAudioSourceResolver {
  final pending = <String, Completer<ResolvedAudioSource>>{};

  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) =>
      (pending[clip.audioSourceRef] = Completer<ResolvedAudioSource>()).future;

  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class GatedNativeVoice extends FakeVoice {
  GatedNativeVoice() : super('gated-native');
  final loadEntered = Completer<void>();
  final loadGate = Completer<void>();
  int releases = 0;
  int disposals = 0;
  int playCalls = 0;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    if (!loadEntered.isCompleted) {
      loadEntered.complete();
      await loadGate.future;
    }
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
  }

  @override
  Future<void> play() {
    playCalls++;
    return super.play();
  }

  @override
  Future<void> release() async {
    releases++;
    await super.release();
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await super.dispose();
  }
}

void main() {
  test('a newer source waits for an already-dispatched native load', () async {
    final voice = GatedNativeVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const DirectEngineAudioSourceResolver());
    final first = deck.load(seed('old'));
    await voice.loadEntered.future;
    final next = deck.load(seed('new'));
    await Future<void>.delayed(Duration.zero);
    expect(voice.loads, isEmpty);
    voice.loadGate.complete();
    await Future.wait([first, next]);
    expect(voice.loads, [Uri.file('/old.wav'), Uri.file('/new.wav')]);
    expect(voice.speeds, [1]);
    expect(voice.pitches, [1]);
    expect(deck.state.trackRef, 'new');
    await deck.dispose();
  });

  test('obsolete resolver failure never releases a newer source', () async {
    final resolver = GatedResolver();
    final voice = FakeVoice('stale-refusal');
    final deck =
        DeckController(deckId: DjDeckId.a, voice: voice, resolver: resolver);
    final first = deck.load(const DjDeckLoad(trackRef: 'old'));
    await deck.load(seed('new'));
    resolver.pending['old']!.completeError(StateError('obsolete resolution'));
    await first;
    expect(voice.isLoaded, isTrue);
    expect(deck.state.trackRef, 'new');
    expect(deck.state.loadFailure, isNull);
    await deck.dispose();
  });

  test('late active play failure is reported instead of escaping the zone',
      () async {
    final voice = LifetimeVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const DirectEngineAudioSourceResolver());
    final errors = <FlutterErrorDetails>[];
    final prior = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await deck.play();
      voice.lifetimes.single.completeError(StateError('playback failed'));
      await Future<void>.delayed(Duration.zero);
      expect(errors.single.exception.toString(), contains('playback failed'));
      expect(deck.state.playing, isFalse);
    } finally {
      FlutterError.onError = prior;
      await deck.dispose();
    }
  });

  test('obsolete play failure cannot alter a newly loaded track', () async {
    final voice = LifetimeVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const DirectEngineAudioSourceResolver());
    await deck.load(seed('old'));
    await deck.play();
    final old = voice.lifetimes.single;
    await deck.load(seed('new'));
    await deck.play();
    old.completeError(StateError('obsolete player error'));
    await Future<void>.delayed(Duration.zero);
    expect(deck.state.trackRef, 'new');
    expect(deck.state.playing, isTrue);
    await deck.dispose();
  });

  test('callbacks after disposal do not restart the native voice', () async {
    final voice = GatedNativeVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const DirectEngineAudioSourceResolver());
    await deck.dispose();
    await deck.play();
    expect(voice.playCalls, 0);
    expect(deck.state.playing, isFalse);
  });

  test('stopAll cancels a session load before its first async continuation',
      () async {
    final voices = <FakeVoice>[];
    final session = DjSessionProvider.prototype(voiceFactory: () {
      final voice = FakeVoice('stopped');
      voices.add(voice);
      return voice;
    });
    final loading = session.load(DjDeckId.a, seed('cancelled'));
    await session.stopAll();
    await loading;
    expect(voices.first.loads, isEmpty);
    session.dispose();
  });

  test('native load drains before teardown and never writes stale tuning',
      () async {
    final voice = GatedNativeVoice();
    final deck = DeckController(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const DirectEngineAudioSourceResolver());
    final loading = deck.load(seed('old'));
    await voice.loadEntered.future;
    final disposing = deck.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(voice.releases, 0);
    expect(voice.disposals, 0);
    voice.loadGate.complete();
    await loading;
    await disposing;
    expect(voice.speeds, isEmpty);
    expect(voice.pitches, isEmpty);
    expect(voice.releases, 1);
    expect(voice.disposals, 1);
    await deck.dispose();
    expect(voice.disposals, 1);
  });

  test('late resolver cannot replace a newer native source', () async {
    final resolver = GatedResolver();
    final voice = FakeVoice('load');
    final deck =
        DeckController(deckId: DjDeckId.a, voice: voice, resolver: resolver);
    final old = deck.load(const DjDeckLoad(trackRef: 'old'));
    await deck.load(seed('new'));
    resolver.pending['old']!
        .complete(ResolvedAudioSource.local(Uri.file('/old.wav')));
    await old;
    expect(voice.loads, [Uri.file('/new.wav')]);
    expect(deck.state.trackRef, 'new');
    await deck.dispose();
  });

  test('resolver completing after disposal never loads a released voice',
      () async {
    final resolver = GatedResolver();
    final voice = FakeVoice('dispose');
    final deck =
        DeckController(deckId: DjDeckId.a, voice: voice, resolver: resolver);
    final loading = deck.load(const DjDeckLoad(trackRef: 'old'));
    await deck.dispose();
    resolver.pending['old']!
        .complete(ResolvedAudioSource.local(Uri.file('/old.wav')));
    await loading;
    expect(voice.loads, isEmpty);
    expect(deck.state.isLoaded, isFalse);
  });

  test('session PLAY completes on dispatch while voice lifetime stays pending',
      () async {
    final voice = LifetimeVoice();
    final voices = <FakeVoice>[voice, FakeVoice('b')].iterator;
    final session = DjSessionProvider.prototype(
      voiceFactory: () {
        voices.moveNext();
        return voices.current;
      },
      resolver: const DirectEngineAudioSourceResolver(),
    );
    await session.load(DjDeckId.a, seed('a'));
    try {
      await session.togglePlay(DjDeckId.a).timeout(
            const Duration(milliseconds: 100),
          );
      expect(voice.lifetimes.single.isCompleted, isFalse);
      expect(session.deckA.playing, isTrue);
      await session.togglePlay(DjDeckId.a);
      expect(session.deckA.playing, isFalse);
    } finally {
      voice.finish();
      session.dispose();
    }
  });
}
