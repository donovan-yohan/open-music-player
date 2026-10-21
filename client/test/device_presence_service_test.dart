import 'dart:async';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/connect/device_presence_service.dart';
import 'package:open_music_player/core/connect/connect_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:rxdart/rxdart.dart';
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;

PlaybackSnapshot snapshot(
        {int position = 0,
        bool playing = true,
        String id = 'local_/private/music.flac'}) =>
    PlaybackSnapshot(
        sessionId: 'session_1',
        cues: const [],
        currentCueId: null,
        currentQueueIndex: 0,
        currentMediaItem: MediaItem(
            id: id,
            title: 'Local song',
            artist: 'Artist',
            artUri: Uri.parse('file:///secret/cover'),
            extras: const {'uri': 'file:///secret/song', 'token': 'secret'}),
        localPosition: Duration(milliseconds: position),
        localDuration: const Duration(minutes: 3),
        globalPosition: Duration.zero,
        globalDuration: Duration.zero,
        playing: playing,
        processingState: ProcessingState.ready,
        activeVoiceCount: 2);
Future<void> flush(WidgetTester tester,
    [Duration duration = Duration.zero]) async {
  await tester.pump(duration);
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('resume never overlaps a cancelled but unsettled transport',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final held = Completer<void>();
    var active = 0, peak = 0;
    final wire = support.Wire((o) async {
      active++;
      if (active > peak) peak = active;
      if (o.method == 'PUT') await held.future;
      active--;
      return support.reply({
        'device': {
          ...deviceJson(),
          'deviceId': (o.data as Map)['deviceId'] ?? deviceJson()['deviceId']
        }
      }, o.method == 'POST' ? 201 : 200);
    });
    final api = support.client(storage, wire),
        source = BehaviorSubject<PlaybackSnapshot>.seeded(snapshot());
    final observer = DevicePresenceService(ConnectService(api),
        label: 'Laptop', platform: 'macos');
    observer.attach(source, api.captureAuthSession());
    await flush(tester);
    observer.setActive(false);
    observer.setActive(true);
    await flush(tester);
    expect(peak, 1);
    expect(wire.requests, hasLength(2));
    held.complete();
    await flush(tester);
    observer.dispose();
    await flush(tester);
    await source.close();
  });
  testWidgets('offline retries back off and disabled service probes slowly',
      (tester) async {
    for (final disabled in [false, true]) {
      final storage = SecureStorage(tokenStorage: support.MemoryTokens());
      final requestTimes = <DateTime>[];
      final wire = support.Wire((o) {
        requestTimes.add(tester.binding.clock.now());
        return support.reply({
          'error': {'code': disabled ? 'SERVICE_DISABLED' : 'UNAVAILABLE'}
        }, 503);
      });
      final api = support.client(storage, wire);
      final source = BehaviorSubject<PlaybackSnapshot>.seeded(snapshot());
      final observer = DevicePresenceService(ConnectService(api),
          label: 'Laptop', platform: 'macos');
      observer.attach(source, api.captureAuthSession());
      await flush(tester);
      expect(wire.requests, hasLength(1));
      await flush(tester, const Duration(seconds: 1));
      expect(wire.requests, hasLength(1));
      for (var i = 0; i < 7; i++) {
        await flush(tester, const Duration(seconds: 30));
      }
      if (disabled) {
        expect(wire.requests, hasLength(8));
        for (var i = 1; i < requestTimes.length; i++) {
          expect(requestTimes[i].difference(requestTimes[i - 1]).inSeconds,
              inInclusiveRange(30, 31));
        }
      } else {
        expect(wire.requests.length, greaterThan(5));
        for (var i = 1; i < requestTimes.length; i++) {
          expect(requestTimes[i].difference(requestTimes[i - 1]).inSeconds,
              inInclusiveRange(2, 30));
        }
        expect(
            requestTimes.last
                .difference(requestTimes[requestTimes.length - 2])
                .inSeconds,
            30);
      }
      observer.dispose();
      await flush(tester);
      await source.close();
    }
  });
  testWidgets(
      'late registration after account switch cannot report or resurrect identity',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final gate = Completer<void>();
    final wire = support.Wire((o) async {
      await gate.future;
      return support.reply({
        'device': {...deviceJson(), 'deviceId': (o.data as Map)['deviceId']}
      }, 201);
    });
    final api = support.client(storage, wire);
    final source = BehaviorSubject<PlaybackSnapshot>.seeded(snapshot());
    final observer = DevicePresenceService(ConnectService(api),
        label: 'Laptop', platform: 'macos');
    observer.attach(source, api.captureAuthSession());
    await flush(tester);
    expect(wire.requests, hasLength(1));
    storage.beginAuthIntent();
    expect(observer.deviceId, isNull);
    expect(observer.isAttached, isFalse);
    gate.complete();
    await flush(tester, const Duration(seconds: 30));
    expect(wire.requests, hasLength(1));
    expect(observer.deviceId, isNull);
    observer.dispose();
    await source.close();
  });
  testWidgets(
      'observer reads atomic source, coalesces semantics and heartbeats without position backlog',
      (tester) async {
    final backend = support.MemoryTokens();
    final storage = SecureStorage(tokenStorage: backend);
    final reports = <Map>[];
    final wire = support.Wire((o) {
      if (o.method == 'POST') {
        return support.reply({
          'device': {...deviceJson(), 'deviceId': (o.data as Map)['deviceId']}
        }, 201);
      }
      if (o.method == 'PUT') reports.add(Map.from(o.data as Map));
      return support.reply({'device': deviceJson()});
    });
    final api = support.client(storage, wire);
    final source =
        BehaviorSubject<PlaybackSnapshot>.seeded(snapshot(position: 1200));
    final observer = DevicePresenceService(ConnectService(api),
        label: 'Laptop', platform: 'macos');
    observer.attach(source, api.captureAuthSession());
    await flush(
      tester,
    );
    expect(reports, hasLength(1));
    final payload = reports.single['playback'] as Map;
    expect(payload['positionMs'], 1200);
    expect((payload['track'] as Map)['trackId'], isNull);
    expect(payload.toString(), isNot(contains('file:')));
    expect(payload.toString(), isNot(contains('secret')));
    for (var i = 0; i < 10; i++) {
      source.add(snapshot(position: 1300 + i, playing: false));
    }
    await flush(tester, const Duration(milliseconds: 999));
    expect(reports, hasLength(1));
    await flush(tester, const Duration(milliseconds: 1));
    expect(reports, hasLength(2));
    expect((reports.last['playback'] as Map)['positionMs'], 1309);
    source.add(snapshot(position: 5000, playing: false));
    await flush(tester, const Duration(seconds: 5));
    expect(reports, hasLength(3));
    expect((reports.last['playback'] as Map)['positionMs'], 5000);
    storage.beginAuthIntent();
    expect(observer.deviceId, isNull);
    expect(observer.isAttached, isFalse);
    await flush(tester, const Duration(seconds: 30));
    expect(reports, hasLength(3));
    observer.dispose();
    await source.close();
  });
  testWidgets(
      'one report in flight retains only latest snapshot; suspend resets identity',
      (tester) async {
    final storage = SecureStorage(tokenStorage: support.MemoryTokens());
    final gate = Completer<void>();
    var reports = 0;
    final wire = support.Wire((o) async {
      if (o.method == 'POST') {
        return support.reply({
          'device': {...deviceJson(), 'deviceId': (o.data as Map)['deviceId']}
        }, 201);
      }
      if (o.method == 'PUT') {
        reports++;
        if (reports == 1) await gate.future;
      }
      return support.reply({'device': deviceJson()});
    });
    final api = support.client(storage, wire),
        source = BehaviorSubject<PlaybackSnapshot>.seeded(snapshot());
    final observer = DevicePresenceService(ConnectService(api),
        label: 'Laptop', platform: 'macos');
    observer.attach(source, api.captureAuthSession());
    await flush(
      tester,
    );
    final identity = observer.deviceId;
    expect(identity, matches(RegExp(r'^[a-f0-9-]{36}$')));
    for (var i = 0; i < 20; i++) {
      source.add(snapshot(position: i, playing: i.isEven));
      await flush(tester, const Duration(seconds: 1));
    }
    expect(reports, 1);
    gate.complete();
    await flush(
      tester,
    );
    await flush(tester, const Duration(seconds: 1));
    expect(reports, 2);
    observer.setActive(false);
    expect(observer.deviceId, isNull);
    await flush(
      tester,
    );
    observer.setActive(true);
    await flush(
      tester,
    );
    expect(observer.deviceId, isNot(identity));
    observer.dispose();
    await flush(
      tester,
    );
    await source.close();
  });
}
