import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

Map<String, dynamic> track(int id) =>
    {'id': id, 'title': 'Track $id', 'duration': 10};
MixPlan plan(int n, {bool overlap = false}) => MixPlan(
    id: 'plan',
    schemaVersion: 1,
    name: 'mix',
    clips: [
      for (var i = 1; i <= n; i++)
        MixPlanClip(
            clipId: 'clip-$i',
            queueItemId: 'queue-$i',
            trackId: '$i',
            sourceStartMs: 0,
            sourceEndMs: 10000,
            timelineStartMs: overlap ? 0 : (i - 1) * 10000)
    ],
    summary: MixPlanSummary(
        clipCount: n,
        trackIds: [for (var i = 1; i <= n; i++) '$i'],
        durationMs: overlap ? 10000 : n * 10000),
    version: 1,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026));
Map<String, dynamic> descriptors(List<int> ids, {bool soon = false}) => {
      'urls': [
        for (final id in ids)
          {
            'trackId': id,
            'url': 'https://example.test/$id.mp3',
            'expiresAt': DateTime.now()
                .add(Duration(seconds: soon ? 30 : 1200))
                .toIso8601String()
          }
      ],
      'unavailable': []
    };
PlaybackState owner(Future<Map<String, dynamic>> Function(List<int>) request,
    {FakeVoice Function()? voiceFactory}) {
  SharedPreferences.setMockInitialValues({});
  final c = DefaultTimelineClock(
      now: () => DateTime.utc(2026), uiTickInterval: const Duration(hours: 1));
  final e = PlaybackEngine.withClock(
      clock: c, voiceFactory: voiceFactory ?? () => FakeVoice('voice'));
  final p = PlaybackState(e,
      signedAudioUrlService: SignedAudioUrlService.withRequester(
          (body) => request((body['trackIds'] as List).cast<int>())));
  addTearDown(() async {
    p.dispose();
    await c.dispose();
  });
  return p;
}

class _ExpiringVoice extends FakeVoice {
  _ExpiringVoice(this.expired, this.attempted) : super('voice');
  final bool Function() expired;
  final List<Uri> attempted;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    attempted.add(source);
    if (source.path == '/2.mp3' && expired() && source.query.isEmpty) {
      throw StateError('403 expired');
    }
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
  }
}

class _RejectingSeekVoice extends FakeVoice {
  _RejectingSeekVoice(this.reject) : super('voice');

  final bool Function() reject;

  @override
  Future<void> seekLocal(int localPositionMs) async {
    if (reject() && loads.last.path == '/2.mp3' && loads.last.query.isEmpty) {
      throw StateError('403 from noncurrent overlapping clip');
    }
    await super.seekLocal(localPositionMs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('late preview resume must not start the restored paused queue',
      () async {
    final held = Completer<Map<String, dynamic>>();
    addTearDown(() {
      if (!held.isCompleted) held.complete(descriptors([1, 2]));
    });
    final entered = Completer<List<int>>();
    int calls = 0;
    final p = owner((ids) async {
      calls++;
      if (calls == 3) {
        entered.complete(ids);
        return held.future;
      }
      return descriptors(ids, soon: calls == 2);
    });
    await p.playQueue([track(9)]);
    await p.pause();
    await p.previewMixSeam([track(1), track(2)], plan(2), seamIndex: 0);
    await p.pause();
    final stale = p.play();
    final requested = await entered.future.timeout(const Duration(seconds: 2));
    expect(requested, contains(1));
    await p.endMixSeamPreview();
    expect(p.queue.single.id, '9');
    expect(p.snapshot.playing, isFalse);
    held.complete(descriptors(requested));
    await stale;
    await Future<void>.delayed(Duration.zero);
    expect(p.queue.single.id, '9');
    expect(p.snapshot.playing, isFalse,
        reason: 'old Play must not start the restored paused queue');
  });
  test('resume retries rejected URLs for overlapping noncurrent clips',
      () async {
    var reject = false;
    final requests = <List<int>>[];
    final p = owner((ids) async {
      requests.add(ids);
      final response = descriptors(ids);
      if (requests.length > 1) {
        for (final row in response['urls']) {
          row['url'] = '${row['url']}?renewed=1';
        }
      }
      return response;
    }, voiceFactory: () => _RejectingSeekVoice(() => reject));
    await p.playMixPlan([track(1), track(2)], plan(2, overlap: true));
    await p.pause();
    expect(p.currentItem?.id, '1');
    reject = true;

    await p.play();

    expect(p.snapshot.playing, isTrue);
    expect(requests, [
      [1, 2],
      [1, 2]
    ]);
  });
  test(
      'paused opening clip can resume when separately requested later track is unavailable',
      () async {
    int calls = 0;
    final p = owner((ids) async {
      calls++;
      if (calls == 1) {
        return {
          'urls': [
            ...descriptors([1])['urls'],
            ...descriptors([2], soon: true)['urls']
          ],
          'unavailable': []
        };
      }
      expect(ids, [2]);
      return {
        'urls': [],
        'unavailable': [
          {'trackId': 2, 'code': 'AUDIO_UNAVAILABLE', 'message': 'file removed'}
        ]
      };
    });
    await p.playMixPlan([track(1), track(2)], plan(2));
    await p.pause();
    expect(p.currentItem?.id, '1');
    await p.play();
    expect(p.snapshot.playing, isTrue);
  });
  test('out-of-order completion keeps current row on the still-sounding clip',
      () async {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.utc(2026);
    final c = DefaultTimelineClock(
        now: () => now, uiTickInterval: const Duration(hours: 1));
    final e = PlaybackEngine.withClock(
        clock: c, voiceFactory: () => FakeVoice('voice'));
    final p = PlaybackState(e,
        signedAudioUrlService: SignedAudioUrlService.withRequester(
            (body) async =>
                descriptors((body['trackIds'] as List).cast<int>())));
    addTearDown(() async {
      p.dispose();
      await c.dispose();
    });
    final mix = MixPlan(
        id: 'nonlinear',
        schemaVersion: 1,
        name: 'nonlinear',
        clips: [
          for (final (id, start, end) in [
            (1, 0, 2000),
            (2, 0, 1000),
            (3, 0, 10000)
          ])
            MixPlanClip(
                clipId: 'clip-$id',
                queueItemId: 'queue-$id',
                trackId: '$id',
                sourceStartMs: 0,
                sourceEndMs: end,
                timelineStartMs: start),
        ],
        summary: const MixPlanSummary(
            clipCount: 3, trackIds: ['1', '2', '3'], durationMs: 10000),
        version: 1,
        createdAt: now,
        updatedAt: now);
    await p.playMixPlan([track(1), track(2), track(3)], mix);
    for (final ms in [1100, 1100, 300]) {
      now = now.add(Duration(milliseconds: ms));
      c.tickForTest();
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    expect(
        e.model.activeClipsAt(e.positionMs).map((clip) => clip.trackId), ['3']);
    expect(p.currentItem?.id, '3');
  });
  test('a saved mix plays around a clip with missing stored audio', () async {
    final voices = <FakeVoice>[];
    final p = owner((ids) async {
      return {
        ...descriptors(ids.where((id) => id != 2).toList()),
        'unavailable': [
          if (ids.contains(2))
            {
              'trackId': 2,
              'code': 'artifact_missing',
              'message': 'stored audio object is unavailable',
            },
        ],
      };
    }, voiceFactory: () {
      final voice = FakeVoice('voice');
      voices.add(voice);
      return voice;
    });

    await p.playMixPlan([track(1), track(2), track(3)], plan(3));
    expect(p.snapshot.playing, isTrue);
    expect(voices.where((voice) => voice.isPlaying).single.loads.last.path,
        '/1.mp3');
    expect(p.snapshot.cues, hasLength(3));

    await p.seekSessionTimeline(p.snapshot, 15000);
    expect(p.snapshot.globalPosition.inMilliseconds, 15000);
    for (var i = 0; i < 20 && voices.any((voice) => voice.isPlaying); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(p.snapshot.playing, isTrue);
    expect(voices.any((voice) => voice.isPlaying), isFalse);

    await p.seekSessionTimeline(p.snapshot, 22000);
    for (var i = 0; i < 20 && voices.every((voice) => !voice.isPlaying); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(voices.where((voice) => voice.isPlaying).single.loads.last.path,
        '/3.mp3');
  });

  test('resuming in an arrangement gap needs no future media link', () async {
    final requests = <List<int>>[];
    final p = owner((ids) async {
      requests.add(ids);
      if (requests.length == 1) {
        return {
          'urls': [
            ...descriptors([1])['urls'],
            ...descriptors([2], soon: true)['urls'],
          ],
        };
      }
      return {
        'urls': [],
        'unavailable': [
          {'trackId': 2, 'code': 'artifact_missing', 'message': 'file removed'},
        ],
      };
    });
    final original = plan(2);
    final mix = MixPlan(
        id: original.id,
        schemaVersion: 1,
        name: original.name,
        clips: [
          original.clips[1].withTimelineStartMs(20000),
          original.clips[0]
        ],
        summary: const MixPlanSummary(
            clipCount: 2, trackIds: ['2', '1'], durationMs: 30000),
        version: 1,
        createdAt: original.createdAt,
        updatedAt: original.updatedAt);
    await p.playMixPlan([track(2), track(1)], mix, startIndex: 1);
    await p.pause();
    await p.seekSessionTimeline(p.snapshot, 15000);

    await p.play();

    expect(p.snapshot.playing, isTrue);
    expect(p.snapshot.globalPosition.inMilliseconds, 15000);
    expect(requests, [
      [2, 1]
    ]);
  });

  test('natural handoff renews an expired later URL without explicit Play',
      () async {
    SharedPreferences.setMockInitialValues({});
    var now = DateTime.now();
    final initialExpiry = now.add(const Duration(minutes: 5));
    final requests = <List<int>>[];
    final attempted = <Uri>[];
    final c = DefaultTimelineClock(
        now: () => now, uiTickInterval: const Duration(hours: 1));
    final signer = SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      requests.add(ids);
      final issued = descriptors(ids);
      for (final row in issued['urls']) {
        if (requests.length == 1) {
          row['expiresAt'] = initialExpiry.toIso8601String();
        } else {
          row['url'] = '${row['url']}?renewed=1';
        }
      }
      return issued;
    });
    final e = PlaybackEngine.withClock(
        clock: c,
        voiceFactory: () =>
            _ExpiringVoice(() => !now.isBefore(initialExpiry), attempted),
        resolver: DirectEngineAudioSourceResolver(
          signedAudioUrlService: signer,
          now: () => now,
        ));
    final p = PlaybackState(e, signedAudioUrlService: signer);
    addTearDown(() async {
      p.dispose();
      await c.dispose();
    });
    final mix = MixPlan(
        id: 'long',
        schemaVersion: 1,
        name: 'long',
        clips: [
          MixPlanClip(
              clipId: 'clip-1',
              queueItemId: 'queue-1',
              trackId: '1',
              sourceStartMs: 0,
              sourceEndMs: 310000,
              timelineStartMs: 0),
          MixPlanClip(
              clipId: 'clip-2',
              queueItemId: 'queue-2',
              trackId: '2',
              sourceStartMs: 0,
              sourceEndMs: 10000,
              timelineStartMs: 310000),
        ],
        summary: const MixPlanSummary(
            clipCount: 2, trackIds: ['1', '2'], durationMs: 320000),
        version: 1,
        createdAt: now,
        updatedAt: now);
    await p.playMixPlan([
      {...track(1), 'duration': 310},
      track(2)
    ], mix);
    expect(attempted.map((uri) => uri.path), contains('/1.mp3'));
    now = now.add(const Duration(milliseconds: 310500));
    c.tickForTest();
    for (var i = 0;
        i < 20 && e.pool.activeVoices['clip-2']?.isPlaying != true;
        i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, [
      [1, 2],
      [2]
    ]);
    expect(attempted.last, Uri.parse('https://example.test/2.mp3?renewed=1'));
    expect(e.pool.activeVoices['clip-2']?.isPlaying, isTrue);
  });
  test('valid 51-clip arrangement fits playback URL request limit', () async {
    final requests = <int>[];
    final p = owner((ids) async {
      requests.add(ids.length);
      if (ids.length > 50) {
        throw const SignedAudioUrlException(
            code: 'INVALID_REQUEST', message: 'too many track IDs requested');
      }
      return descriptors(ids);
    });
    await p.playMixPlan([for (var i = 1; i <= 51; i++) track(i)], plan(51));
    expect(requests, [50, 1]);
    expect(p.queue.length, 51);
  });
}
