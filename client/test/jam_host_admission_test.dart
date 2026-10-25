import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/jam/jam_playback_admission.dart';
import 'package:open_music_player/core/jam/jam_models.dart';
import 'package:open_music_player/core/jam/jam_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'connect_auth_scope_test.dart' as support;
import 'support/fake_voice.dart';
import 'jam_host_service_test.dart' show jamId, requestId, catalogId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final revoke in [false, true]) {
    test(
        'actual canonical admission ${revoke ? 'rejects held revoked account' : 'returns queue occurrence without autoplay'}',
        () async {
      final storage = SecureStorage(tokenStorage: support.MemoryTokens());
      final wire = support.Wire((o) => support.reply({
            'tracks': [
              {
                'id': 7,
                'title': 'Song',
                'artist': 'Artist',
                'duration_ms': 10000,
                'added_at': '2026-10-21T10:00:00Z'
              }
            ],
            'total': 1
          }));
      final api = support.client(storage, wire),
          scope = api.captureAuthSession();
      final clock = DefaultTimelineClock(
          now: () => DateTime.utc(2026),
          uiTickInterval: const Duration(hours: 1));
      final engine =
          _Engine(clock: clock, voiceFactory: () => FakeVoice('host'));
      final gate = Completer<void>(), entered = Completer<void>();
      final playback = PlaybackState(engine, signedAudioUrlService:
          SignedAudioUrlService.withRequester((body) async {
        if (!entered.isCompleted) entered.complete();
        if (revoke) await gate.future;
        return {
          'urls': [
            {
              'trackId': 7,
              'url': 'https://example.invalid/7.mp3',
              'expiresAt': DateTime.utc(2099).toIso8601String()
            }
          ],
          'unavailable': []
        };
      }));
      final admit =
          canonicalJamAdmission(playback: playback, service: JamService(api));
      const request = JamRequest(
          requestId: requestId,
          catalogItemId: catalogId,
          displayName: 'Guest',
          status: 'pending',
          trackId: 7);
      final future = admit(jamId, request, playback.snapshot.sessionId,
          () => api.acceptsAuthSession(scope));
      if (revoke) {
        final assertion = expectLater(future, throwsStateError);
        await entered.future;
        storage.beginAuthIntent();
        gate.complete();
        await assertion;
        expect(playback.queue, isEmpty);
      } else {
        final receipt = await future;
        expect(receipt.occurrenceId, playback.snapshot.cues.single.queueItemId);
        expect(receipt.requestId, requestId);
        expect(playback.isPlaying, isFalse);
        expect(playback.queue.single.id, '7');
      }
      playback.dispose();
      await engine.retired.future;
      await clock.dispose();
    });
  }
}

class _Engine extends PlaybackEngine {
  _Engine({required super.clock, required super.voiceFactory})
      : super.withClock();
  final retired = Completer<void>();
  @override
  Future<void> dispose() async {
    await super.dispose();
    retired.complete();
  }
}
