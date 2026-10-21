import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/main.dart' show bindPlaybackAccountRetirement;
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_auth_scope_test.dart' as support;
import 'support/fake_voice.dart';

Map<String, dynamic> track(int id) =>
    {'id': id, 'title': 'private $id', 'duration': 30};

class Harness {
  Harness({this.store}) {
    engine = PlaybackEngine.withClock(
        clock: clock,
        voiceFactory: () {
          final v = HeldVoice();
          voices.add(v);
          return v;
        });
    playback = PlaybackState(engine,
        persistence: store,
        persistenceDebounce: Duration.zero, signedAudioUrlService:
            SignedAudioUrlService.withRequester((body) async {
      final ids = List<int>.from(body['trackIds'] as List);
      resolved?.complete();
      resolved = null;
      await resolutionGate?.future;
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://example.test/$id.mp3',
              'expiresAt': DateTime.utc(2027).toIso8601String()
            }
        ],
        'unavailable': <Map<String, dynamic>>[]
      };
    }));
    final api = support.client(storage, support.Wire((o) {
      if (o.path == '/auth/login') {
        if (o.data['email'] == 'refused') {
          return support.reply({'error': 'invalid credentials'}, 401);
        }
        return support
            .reply({'accessToken': o.data['email'], 'refreshToken': 'r'});
      }
      return support.reply({}, 204);
    }));
    auth = AuthState(
        authService: AuthService(
            api: api,
            storage: storage,
            biometricUnlockService: support.NoBiometrics()));
    unbind =
        bindPlaybackAccountRetirement(authState: auth, playbackState: playback);
  }
  final QueuePersistenceStore? store;
  final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026), uiTickInterval: const Duration(hours: 1));
  final storage = SecureStorage(tokenStorage: support.MemoryTokens());
  final voices = <HeldVoice>[];
  late final PlaybackEngine engine;
  late final PlaybackState playback;
  late final AuthState auth;
  late final void Function() unbind;
  Completer<void>? resolutionGate, resolved;
  Future<void> signIn(String account) async {
    expect(await auth.login(email: account, password: 'fixture'), isTrue);
    await playback.accountRetirement;
  }

  Future<void> dispose() async {
    unbind();
    auth.dispose();
    final done = Future.wait([
      engine.positionMsStream.drain<void>(),
      engine.isPlayingStream.drain<void>(),
      engine.completedStream.drain<void>(),
      engine.playbackErrors.drain<void>()
    ]);
    playback.dispose();
    await done;
    await clock.dispose();
  }
}

class HeldVoice extends FakeVoice {
  HeldVoice() : super('hardware-free');
  Completer<void>? gate;
  @override
  Future<void> pause() async {
    await gate?.future;
    await super.pause();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed replacement login still retires A and cancels pending source',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.signIn('A');
    await h.playback.playQueue([track(1)]);
    h.resolutionGate = Completer<void>();
    h.resolved = Completer<void>();
    final started = h.resolved!.future;
    final oldPlay = h.playback.playQueue([track(2)]);
    await started;
    expect(await h.auth.login(email: 'refused', password: 'fixture'), isFalse);
    await h.playback.accountRetirement;
    h.resolutionGate!.complete();
    await oldPlay;
    expect(h.playback.queue, isEmpty);
    expect(h.playback.snapshot.currentMediaItem, isNull);
    expect(h.playback.playbackContext, isNull);
  });

  test('retirement revokes a held Jam admission independently of caller guard',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.signIn('A');
    await h.playback.playQueue([track(1)]);
    h.resolutionGate = Completer<void>();
    h.resolved = Completer<void>();
    final started = h.resolved!.future;
    final admission = h.playback.admitJamRequest(
        jamId: 'old-jam',
        requestId: 'held',
        track: track(2),
        expectedSessionId: h.playback.snapshot.sessionId,
        stillCurrent: () => true);
    final rejected = expectLater(admission, throwsStateError);
    await started;
    await h.signIn('B');
    h.resolutionGate!.complete();
    await rejected;
    expect(h.playback.queue, isEmpty);
  });

  test('rapid retirement serializes B intent behind A and C cancels B',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.signIn('A');
    await h.playback.playQueue([track(1)]);
    final gate = Completer<void>();
    for (final v in h.voices) {
      v.gate = gate;
    }
    final bLogin = h.auth.login(email: 'B', password: 'fixture');
    expect(await bLogin, isTrue);
    final bPlay = h.playback.playQueue([track(2)]);
    await Future<void>.delayed(Duration.zero);
    expect(h.playback.currentItem!.id, '1');
    final cLogin = h.auth.login(email: 'C', password: 'fixture');
    expect(await cLogin, isTrue);
    final cPlay = h.playback.playQueue([track(3)]);
    gate.complete();
    await Future.wait([bPlay, cPlay]);
    await h.playback.accountRetirement;
    expect(h.playback.queue.map((i) => i.id), ['3']);
    expect(h.playback.currentItem!.id, '3');
  });

  test('retirement does not erase persisted A or write an empty reset for B',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var account = 'A';
    final store = QueuePersistenceStore(
        prefs: Future.value(prefs), accountIdProvider: () async => account);
    final h = Harness(store: store);
    addTearDown(h.dispose);
    await h.signIn('A');
    await h.playback.restore();
    await h.playback.playQueue([track(1)]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final savedA = prefs.getString(QueuePersistenceStore.storageKey);
    expect(QueueSnapshot.decode(savedA).tracks.single['id'], 1);
    account = 'B';
    store.invalidateAccountId();
    await h.signIn('B');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(prefs.getString(QueuePersistenceStore.storageKey), savedA);
    expect(h.playback.queue, isEmpty);
    await h.playback.playQueue([track(2)]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final savedB =
        QueueSnapshot.decode(prefs.getString(QueuePersistenceStore.storageKey));
    expect(savedB.accountId, 'B');
    expect(savedB.tracks.single['id'], 2);
  });

  test('held direct resolution cannot override B selection after retirement',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.signIn('A');
    h.resolutionGate = Completer<void>();
    h.resolved = Completer<void>();
    final gate = h.resolutionGate!;
    final started = h.resolved!.future;
    final aPlay = h.playback.playQueue([track(1)]);
    await started;
    await h.signIn('B');
    h.resolutionGate = null;
    await h.playback.playQueue([track(2)]);
    gate.complete();
    await aPlay;
    expect(h.playback.currentItem!.id, '2');
    expect(h.playback.queue.map((i) => i.id), ['2']);
  });

  test('held restore cannot republish retired account metadata', () async {
    SharedPreferences.setMockInitialValues({
      QueuePersistenceStore.storageKey:
          QueueSnapshot(tracks: [track(1)]).encode()
    });
    final h = Harness(store: QueuePersistenceStore());
    addTearDown(h.dispose);
    h.resolutionGate = Completer<void>();
    h.resolved = Completer<void>();
    final started = h.resolved!.future;
    final restore = h.playback.restore();
    await started;
    await h.signIn('B');
    h.resolutionGate!.complete();
    await restore;
    expect(h.playback.queue, isEmpty);
    expect(h.playback.snapshot.currentMediaItem, isNull);
  });

  test('held manual resolution cannot reintroduce A after real auth retirement',
      () async {
    final h = Harness();
    addTearDown(h.dispose);
    await h.signIn('A');
    await h.playback.playQueue([track(1)]);
    h.resolutionGate = Completer<void>();
    h.resolved = Completer<void>();
    final started = h.resolved!.future;
    final enqueue = h.playback.enqueue(track(2));
    await started;
    await h.signIn('B');
    h.resolutionGate!.complete();
    await enqueue;
    expect(h.playback.queue, isEmpty);
    expect(h.playback.snapshot.currentMediaItem, isNull);
  });
}
