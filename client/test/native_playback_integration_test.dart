import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:dio/dio.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_music_player/core/engine/native_mix_renderer.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/native_playback_backend.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/prepared_stem_assets.dart';
import 'package:open_music_player/models/mix_plan.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:open_music_player/models/timeline_clip.dart';

import 'support/fake_voice.dart';
import 'prepared_stem_manifest_test.dart'
    show preparedStatus, preparedRoles, preparedModel, preparedSource;

class _FakeDevice {
  _FakeDevice(String path) : lib = ffi.DynamicLibrary.open(path);
  final ffi.DynamicLibrary lib;
  late final reset = lib.lookupFunction<ffi.Int32 Function(), int Function()>(
      'sq_ffi_test_reset');
  late final callback =
      lib.lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
          'sq_ffi_test_callback');
  late final sample =
      lib.lookupFunction<ffi.Float Function(ffi.Uint32), double Function(int)>(
          'sq_ffi_test_sample');
  late final setResult = lib.lookupFunction<
      ffi.Int32 Function(ffi.Uint32, ffi.Int32, ffi.Int32),
      int Function(int, int, int)>('sq_ffi_test_set_result');
}

class _FixtureHttpOverrides extends HttpOverrides {}

Future<void> _nativeAppTracer() async {
  final path = Platform.environment['SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY'];
  expect(path, isNotNull,
      reason: 'Compiled fake host is mandatory; never use OS audio.');
  final fake = _FakeDevice(path!);
  expect(fake.reset(), 0);
  final root = await Directory(Platform.environment['TMPDIR']!)
      .createTemp('app-native-');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final body = preparedStatus(objectOrigin: 'http://127.0.0.1:${server.port}');
  const fixtureSeconds = 8;
  body['publishedManifest']['duration_ms'] = fixtureSeconds * 1000;
  final artifacts = body['publishedManifest']['artifacts'];
  artifacts['energy']['frame_count'] = fixtureSeconds * 80;
  artifacts['energy']['channels'] = {
    for (final role in preparedRoles)
      role: base64Encode(List.filled(fixtureSeconds * 80, 0))
  };
  final objects = <String, List<int>>{};
  final oracle = <String, Float32List>{};
  for (var i = 0; i < preparedRoles.length; i++) {
    final role = preparedRoles[i];
    final file = File('${root.path}/$role.opus');
    final pcm = File('${root.path}/$role.f32');
    final encoded = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'aevalsrc=${.01 * (i + 1)}*sin(2*PI*${317 + i * 89}*t)|${.008 * (i + 1)}*sin(2*PI*${997 + i * 37}*t):s=48000:d=$fixtureSeconds',
      '-c:a',
      'libopus',
      file.path
    ]);
    expect(encoded.exitCode, 0, reason: '${encoded.stderr}');
    final decoded = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-c:a',
      'libopus',
      '-request_sample_fmt',
      'flt',
      '-i',
      file.path,
      '-f',
      'f32le',
      pcm.path
    ]);
    expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
    oracle[role] = (await pcm.readAsBytes()).buffer.asFloat32List();
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final key =
        'stems/42/$preparedModel/${'a' * 64}/g7/${role == 'melody' ? 'other' : role}/$digest.opus';
    final member = (body['publishedManifest']['artifacts']['objects'] as List)
        .firstWhere((o) => o['channel'] == role);
    final head = String.fromCharCodes(bytes).indexOf('OpusHead');
    member['key'] = key;
    member['sha256'] = digest;
    member['bytes'] = bytes.length;
    member['duration_ms'] = fixtureSeconds * 1000;
    member['sample_frames'] = fixtureSeconds * 48000;
    member['encoder_delay_frames'] = bytes[head + 10] | (bytes[head + 11] << 8);
    final download = (body['memberDownloads'] as List)
        .firstWhere((o) => o['channel'] == role);
    download['key'] = key;
    download['sha256'] = digest;
    download['bytes'] = bytes.length;
    download['url'] = 'http://127.0.0.1:${server.port}/$key';
    download['expiresAt'] =
        DateTime.now().add(const Duration(hours: 1)).toIso8601String();
    objects['/$key'] = bytes;
  }
  var manifestRequests = 0;
  final serving = server.listen((request) async {
    if (request.uri.path == '/api/v1/tracks/42/stems') {
      expect(request.uri.queryParameters['includeUrls'], '1');
      manifestRequests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    } else {
      expect(request.headers.value('authorization'), isNull);
      request.response.add(objects[request.uri.path]!);
    }
    await request.response.close();
  });
  final dio = Dio();
  final api = ApiClient(dio: dio);
  // Deterministic loopback API fixture, NOT production-server evidence.
  dio.interceptors.clear();
  dio.options.baseUrl = 'http://127.0.0.1:${server.port}/api/v1';
  final service = StemsService(api);
  final assets =
      PreparedStemAssets(rootDirectory: Directory('${root.path}/assets'));
  final voices = <FakeVoice>[];
  Completer<void>? manifestGate, manifestEntered;
  final engine = PlaybackEngine(
      voiceFactory: () {
        final v = FakeVoice('legacy');
        voices.add(v);
        return v;
      },
      nativeBackendFactory: () => createNativePlaybackBackend(
          libraryPath: path,
          loadManifest: (clip, hash, token) async {
            final gate = manifestGate;
            if (gate != null) {
              if (!manifestEntered!.isCompleted) manifestEntered.complete();
              await gate.future;
            }
            if (token.isCancelled) throw token.cancelError!;
            return service.getPreparedManifest(int.parse(clip.trackId),
                expectedSourceFileHash: hash, allowLoopbackHttp: true);
          },
          loadPreparedAsset: (manifest, token) =>
              assets.acquire(manifest, cancelToken: token)));
  var denyOriginalSigning = false;
  var deniedOriginalRequests = 0;
  final state = PlaybackState(engine,
      signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
    if (denyOriginalSigning) {
      deniedOriginalRequests++;
      throw StateError('Original signing must not gate prepared playback');
    }
    return {
      'urls': [
        {
          'trackId': 42,
          'url': 'https://unused.invalid/original',
          'expiresAt':
              DateTime.now().add(const Duration(hours: 1)).toIso8601String()
        }
      ],
      'unavailable': []
    };
  }));
  PlaybackState? restoredState;
  PlaybackEngine? restoredEngine;
  try {
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: preparedSource);
    final now = DateTime.utc(2026);
    final plan = MixPlan(
        id: 'native',
        schemaVersion: 1,
        name: 'Native fixture',
        clips: [
          MixPlanClip(
              clipId: 'a',
              queueItemId: 'qa',
              trackId: '42',
              sourceStartMs: 0,
              sourceEndMs: 1000,
              timelineStartMs: 0,
              stemEdits: edits)
        ],
        summary: const MixPlanSummary(
            clipCount: 1, trackIds: ['42'], durationMs: 1000),
        version: 1,
        createdAt: now,
        updatedAt: now);
    await state.playMixPlan([
      {'id': 42, 'title': 'Fixture', 'duration': 1}
    ], plan);
    expect(engine.usesNativeBackend, isTrue);
    expect(manifestRequests, 1);
    expect(voices.every((v) => !v.isPlaying), isTrue);
    expect(fake.callback(128), 0);
    for (var i = 0; i < 256; i++) {
      final sum = oracle.entries
          .where((e) => e.key != 'drums')
          .fold<double>(0, (v, e) => v + e.value[i]);
      expect(fake.sample(i), closeTo(sum, .00001));
    }
    expect(engine.positionMs, 2);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(engine.positionMs, 2,
        reason: 'No wall-clock advancement without native callback');
    final queueId = state.snapshot.cues.single.queueItemId;
    for (final gain in [double.nan, double.infinity, -.1, 1.1]) {
      await expectLater(
          state.setStemGain(queueId, 'vocals', gain), throwsArgumentError);
    }
    final pending = state.setStemGain(queueId, 'vocals', 0, rampMs: 1);
    await Future<void>.delayed(Duration.zero);
    expect(fake.callback(128), 0);
    final ack = await pending;
    expect(ack.sourcePositionMs, 5);
    expect(ack.queueItemId, queueId);
    for (var i = 96; i < 256; i++) {
      final sum = oracle.entries
          .where((e) => e.key != 'drums' && e.key != 'vocals')
          .fold<double>(0, (v, e) => v + e.value[256 + i]);
      expect(fake.sample(i), closeTo(sum, .00001));
    }
    await state.pause();
    expect(fake.callback(128), 0);
    expect(engine.positionMs, 5);
    await state.seek(const Duration(milliseconds: 400));
    expect(engine.positionMs, 400);
    await state.play();
    expect(fake.callback(128), 0);
    expect(engine.positionMs, 402);
    for (var i = 0;
        i < 100 && state.snapshot.globalPosition.inMilliseconds != 402;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(state.snapshot.activeVoiceCount, 1,
        reason: 'Native projection, not idle legacy pool');
    expect(state.snapshot.globalPosition.inMilliseconds, 402);

    // Move only future B through the existing controller, with A sounding.
    await state.pause();
    final twoPlan = MixPlan(
        id: 'two',
        schemaVersion: 1,
        name: 'Two occurrences',
        clips: [
          plan.clips.single,
          MixPlanClip(
              clipId: 'b',
              queueItemId: 'qb',
              trackId: '42',
              sourceStartMs: 0,
              sourceEndMs: 1000,
              timelineStartMs: 2000,
              stemEdits: edits)
        ],
        summary: const MixPlanSummary(
            clipCount: 2, trackIds: ['42', '42'], durationMs: 3000),
        version: 1,
        createdAt: now,
        updatedAt: now);
    await state.playMixPlan([
      {'id': 42, 'title': 'A', 'duration': 1},
      {'id': 42, 'title': 'B', 'duration': 1}
    ], twoPlan);
    expect(fake.callback(128), 0);
    final override = state.setStemGain('qa', 'vocals', 0, rampMs: 1);
    await Future<void>.delayed(Duration.zero);
    expect(fake.callback(128), 0);
    await override;
    final before = engine.positionMs;
    final edit = state.setQueueTimelineStartMsByQueueItemId('qb', 3000,
        snapToDownbeat: false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(state.snapshot.cues.last.timelineStart.inMilliseconds, 2000,
        reason: 'Candidate placement is not visible before native block ACK');
    expect(fake.callback(128), 0);
    await edit;
    expect(engine.positionMs, before + 3);
    expect(state.timelineClipForQueueIndex(1)!.timelineStartMs, 3000);
    for (var i = 0; i < 256; i++) {
      final sum = oracle.entries
          .where((e) => e.key != 'drums' && e.key != 'vocals')
          .fold<double>(0, (v, e) => v + e.value[512 + i]);
      expect(fake.sample(i), closeTo(sum, .00001));
    }
    final accepted = state.timelineModel;
    for (final model in [
      TimelineModel(clips: [
        for (final c in accepted.clips)
          MixClip(
              placement: c.placement,
              queueItemId: c.queueItemId,
              stemEdits: c.stemEdits,
              playbackRate: 1.1)
      ]),
      TimelineModel(clips: [
        for (final c in accepted.clips)
          MixClip(
              placement: c.placement,
              queueItemId: c.queueItemId,
              stemEdits: c.stemEdits,
              envelope: const GainEnvelope(baseGainDb: 1))
      ]),
      TimelineModel(clips: [
        for (final c in accepted.clips)
          MixClip(
              placement: c.placement,
              queueItemId: c.queueItemId,
              stemEdits: StemEdits(
                  channelSet: StemChannelSet.stems5Hybrid,
                  sourceFileHash: preparedSource,
                  unknownKeys: {'future': true}))
      ]),
      TimelineModel(clips: [
        for (final c in accepted.clips)
          MixClip(
              placement: c.placement,
              queueItemId: c.queueItemId,
              stemEdits: c.stemEdits,
              rateAutomation: const PlaybackRateAutomation(segments: [
                PlaybackRateSegment(
                    startMs: 0, endMs: 100, startRate: 1, endRate: 1)
              ]))
      ], autoTempoTransitions: false),
    ]) {
      await expectLater(
          engine.replacePreparedMix(model), throwsUnsupportedError);
      expect(identical(state.timelineModel, accepted), isTrue);
    }
    final beforeInvalidDuration = engine.durationMs;
    final invalidLong = TimelineModel(clips: [
      accepted.clips.first,
      MixClip(
          queueItemId: 'qb',
          envelope: const GainEnvelope(baseGainDb: 2),
          stemEdits: edits,
          placement: TimelineClip.clamped(
              id: accepted.clips.last.id,
              trackId: '42',
              sourceDurationMs: 8000,
              sourceStartMs: 0,
              sourceEndMs: 7000,
              timelineStartMs: 3000))
    ]);
    await expectLater(
        engine.replacePreparedMix(invalidLong), throwsUnsupportedError);
    expect(engine.durationMs, beforeInvalidDuration,
        reason: 'Rejected authored metadata cannot mutate the canonical clock');
    final recorded = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: preparedSource,
        events: [StemGainEvent(channel: 'kick', atMs: 0, gain: 0, rampMs: 1)]);
    final savedEdit = state.setQueueStemEditsByQueueItemId('qa', recorded,
        expectedSourceFileHash: preparedSource);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(identical(state.timelineModel, accepted), isTrue);
    expect(fake.callback(128), 0);
    await savedEdit;
    for (var i = 0; i < 256; i++) {
      final sum = oracle.entries
          .where((e) => !['drums', 'vocals', 'kick'].contains(e.key))
          .fold<double>(0, (v, e) => v + e.value[768 + i]);
      expect(fake.sample(i), closeTo(sum, .00001));
    }
    final withRecorded = state.timelineModel;
    await expectLater(
        state.setQueueTimelineStartMsByQueueItemId('qa', 100,
            snapToDownbeat: false),
        throwsStateError);
    expect(identical(state.timelineModel, withRecorded), isTrue);
    expect(state.timelineClipForQueueIndex(0)!.timelineStartMs, 0);
    // Persisted JSON is reloaded through the same app/controller/decoder path.
    await state.pause();
    final savedFile = File('${root.path}/saved-performance.json');
    await savedFile.writeAsString(jsonEncode({
      'id': 'saved-curves',
      'schemaVersion': 1,
      'name': 'Saved performance',
      'version': 1,
      'createdAt': now.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'summary': {
        'clipCount': 1,
        'trackIds': ['42'],
        'durationMs': 1000
      },
      'clips': [
        {
          'clipId': 'saved',
          'queueItemId': 'savedq',
          'trackId': '42',
          'sourceStartMs': 200,
          'sourceEndMs': 1200,
          'timelineStartMs': 0,
          'fadeInMs': 100,
          'fadeOutMs': 200,
          'gainDb': -6,
          'stemEdits': {
            ...edits.toJson(),
            'events': [
              {'channel': 'vocals', 'atMs': 0, 'gain': 0.0, 'rampMs': 1},
              {'channel': 'kick', 'atMs': 150, 'gain': 0.2, 'rampMs': 100},
              {'channel': 'kick', 'atMs': 200, 'gain': 0.8, 'rampMs': 100},
              {'channel': 'vocals', 'atMs': 600, 'gain': 1.0, 'rampMs': 100},
            ]
          }
        }
      ]
    }));
    final saved = MixPlan.fromJson(
        jsonDecode(await savedFile.readAsString()) as Map<String, dynamic>);
    final savedJson = jsonEncode(saved.clips.single.toJson());
    denyOriginalSigning = true;
    await state.playMixPlan([
      {'id': 42, 'title': 'Saved', 'duration': 8}
    ], saved);
    expect(deniedOriginalRequests, 0);
    denyOriginalSigning = false;
    expect(state.supportsNativePreparedPlayback, isTrue);
    expect(state.usesNativePreparedPlayback, isTrue);
    // Independent source-frame ramp/envelope oracle (no production evaluator).
    double authored(String role, int sourceFrame) {
      final sourceMs = sourceFrame / 48;
      if (role == 'vocals') {
        if (sourceMs < 1) return 1 - sourceMs;
        return ((sourceMs - 600) / 100).clamp(0.0, 1.0);
      }
      if (role == 'kick') {
        if (sourceMs < 150) return 1;
        if (sourceMs < 200) return 1 - .8 * (sourceMs - 150) / 100;
        return .6 + .2 * ((sourceMs - 200) / 100).clamp(0.0, 1.0);
      }
      return 1;
    }

    void checkSaved(int timelineFrame,
        {bool vocalOverride = false, int skipFrames = 0, int frames = 128}) {
      for (var f = skipFrames; f < frames; f++) {
        final local = timelineFrame + f;
        final source = 200 * 48 + local;
        final envelope = math.pow(10, -6 / 20) *
            (local < 4800 ? math.sin(local / 4800 * math.pi / 2) : 1) *
            (local > 38400
                ? math.sin((48000 - local) / 9600 * math.pi / 2)
                : 1);
        for (var ch = 0; ch < 2; ch++) {
          final sum = oracle.entries
              .where((e) => e.key != 'drums')
              .fold<double>(
                  0,
                  (v, e) =>
                      v +
                      e.value[source * 2 + ch] *
                          (vocalOverride && e.key == 'vocals'
                              ? 1
                              : authored(e.key, source)));
          expect(fake.sample(f * 2 + ch), closeTo(sum * envelope, .00003),
              reason: 'source=$source channel=$ch');
        }
      }
    }

    expect(fake.callback(128), 0);
    checkSaved(0);
    // Forward then backward seeks; native monotonic frames never rewind.
    for (final ms in [400, 50, 850, 998]) {
      await state.seek(Duration(milliseconds: ms));
      expect(fake.callback(128), 0);
      checkSaved(ms * 48, frames: ms == 998 ? 96 : 128);
      if (ms == 998) {
        for (var i = 192; i < 256; i++) {
          expect(fake.sample(i), 0, reason: 'Half-open selected EOF');
        }
      }
    }
    // Resume drains the accepted logical anchor even when no callback consumed
    // revisions while paused, including a seek backwards within a saved ramp.
    await state.pause();
    await state.seek(const Duration(milliseconds: 50));
    expect(fake.callback(128), 0); // paused callback cannot consume revision
    await state.play();
    expect(fake.callback(128), 0);
    checkSaved(50 * 48);
    // Authored vocals are zero; a record-off gain=1 must replace, not multiply.
    final capture = state.sourcePositionMsForQueueItemId('savedq');
    final live = state.setStemGain('savedq', 'vocals', 1, rampMs: 1);
    await Future<void>.delayed(Duration.zero);
    expect(state.liveStemOverrides.containsKey('savedq'), isFalse);
    expect(fake.callback(128), 0);
    final liveAck = await live;
    expect(liveAck.captureSourcePositionMs, capture);
    expect(
        liveAck.sourcePositionMs, greaterThan(liveAck.captureSourcePositionMs));
    expect(liveAck.sourceFileHash, preparedSource);
    expect(liveAck.stemModelVersion, preparedModel);
    expect(liveAck.queueItemId, 'savedq');
    expect(state.liveStemOverrides['savedq'], {'vocals': 1});
    expect(() => state.liveStemOverrides['savedq']!['vocals'] = .5,
        throwsUnsupportedError);
    checkSaved(50 * 48 + 128, vocalOverride: true, skipFrames: 48);
    expect(jsonEncode(state.timelineModel.clips.single.stemEdits!.toJson()),
        jsonEncode(saved.clips.single.stemEdits!.toJson()));
    final secondOverride = state.setStemGain('savedq', 'kick', .1, rampMs: 1);
    await Future<void>.delayed(Duration.zero);
    expect(fake.callback(128), 0);
    await secondOverride;
    expect(state.liveStemOverrides['savedq'], {'vocals': 1, 'kick': .1});
    final clearing = state.clearStemOverrides('savedq');
    var cleared = false;
    final clearCompleted = clearing.then((_) => cleared = true);
    await Future<void>.delayed(Duration.zero);
    expect(cleared, isFalse);
    expect(state.liveStemOverrides['savedq'], {'vocals': 1, 'kick': .1});
    expect(fake.callback(128), 0);
    await clearCompleted;
    expect(state.liveStemOverrides.containsKey('savedq'), isFalse);
    checkSaved(50 * 48 + 384);
    expect(jsonEncode(state.timelineModel.clips.single.stemEdits!.toJson()),
        jsonEncode(jsonDecode(savedJson)['stemEdits']));
    await state.pause();
    await expectLater(state.clearStemOverrides('savedq'), throwsStateError);

    // Long residency rolls independently of the UI clock, with four separate
    // cursors into the same immutable recording (not one deduplicated instance).
    await state.pause();
    final longClips = [
      for (var i = 0; i < 4; i++)
        MixPlanClip(
            clipId: 'long$i',
            queueItemId: 'longq$i',
            trackId: '42',
            sourceStartMs: 0,
            sourceEndMs: 8000,
            timelineStartMs: 0,
            fadeInMs: 0,
            fadeOutMs: 0,
            stemEdits: edits)
    ];
    final longPlan = MixPlan(
        id: 'long',
        schemaVersion: 1,
        name: 'Rolling',
        clips: longClips,
        summary: const MixPlanSummary(
            clipCount: 4, trackIds: ['42', '42', '42', '42'], durationMs: 8000),
        version: 1,
        createdAt: now,
        updatedAt: now);
    await state.playMixPlan([
      for (var i = 0; i < 4; i++)
        {'id': 42, 'title': 'Repeat $i', 'duration': 8}
    ], longPlan);
    expect(engine.nativeDecoderCount, lessThanOrEqualTo(6));
    expect(engine.preparedNativeBytes, lessThanOrEqualTo(64 * 1024 * 1024));
    // Deliberately outrun the preparation horizon: one native callback loop
    // advances without a producer wakeup. Only missing clips silence; no wall
    // clock stop/rewind is permitted and the error must become user-visible.
    for (var i = 0; i < 1500; i++) {
      expect(fake.callback(128), 0);
    }
    expect(engine.positionMs, 4000);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(engine.positionMs, 4000);
    // Permit replacement ACK after worker preparation, without driving UI time.
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(fake.callback(128), 0);
    }
    expect(engine.preparedNativeBytes, lessThanOrEqualTo(64 * 1024 * 1024));
    expect(engine.nativeDecoderCount, lessThanOrEqualTo(6));
    expect(state.playbackError, contains('arrived late'));
    final fourAccepted = state.timelineModel;

    // A complete engine candidate cannot admit a fifth cursor, even though all
    // recordings and decoded windows share immutable bytes.
    expect(
        () => TimelineModel(clips: [
              ...fourAccepted.clips,
              MixClip(
                  queueItemId: 'fifth',
                  stemEdits: edits,
                  placement: TimelineClip.clamped(
                      id: 'fifth',
                      trackId: '42',
                      sourceDurationMs: 8000,
                      sourceStartMs: 0,
                      sourceEndMs: 8000,
                      timelineStartMs: 0))
            ]),
        throwsStateError);
    expect(identical(state.timelineModel, fourAccepted), isTrue);
    await state.pause();
    await state.seek(const Duration(milliseconds: 6000));
    expect(engine.positionMs, 6000);
    await state.play();
    expect(fake.callback(128), 0);
    for (var i = 0; i < 256; i++) {
      final sum = oracle.entries
              .where((e) => e.key != 'drums')
              .fold<double>(0, (v, e) => v + e.value[6000 * 96 + i]) *
          4;
      expect(fake.sample(i), closeTo(sum, .001));
    }
    await state.pause();
    final retainedBytes = engine.preparedNativeBytes;
    expect(fake.setResult(3, 6, -706), 0);
    await expectLater(
        engine.selectLegacyBackend(), throwsA(isA<NativeMixDeviceException>()));
    expect(engine.usesNativeBackend, isTrue);
    expect(engine.preparedNativeBytes, retainedBytes);
    expect(engine.nativeDecoderCount, greaterThan(0));
    expect(fake.setResult(3, 0, 0), 0);
    await state.playQueue([
      {'id': 42, 'title': 'Original', 'duration': 1}
    ]);
    expect(engine.usesNativeBackend, isFalse);
    expect(voices.any((v) => v.isPlaying), isTrue);
    manifestGate = Completer<void>();
    manifestEntered = Completer<void>();
    final cancelledStart = state.playMixPlan([
      {'id': 42, 'title': 'Cancelled', 'duration': 1}
    ], plan);
    await manifestEntered.future;
    final pause = state.pause();
    manifestGate.complete();
    await cancelledStart;
    await pause;
    expect(engine.isPlaying, isFalse);
    expect(state.snapshot.playing, isFalse);
    expect(voices.every((v) => !v.isPlaying), isTrue);
    manifestGate = null;
    await engine.selectLegacyBackend();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = QueuePersistenceStore(prefs: Future.value(prefs));
    await store.save(QueueSnapshot(
        tracks: [
          {'id': 42, 'title': 'Restored', 'duration': 8}
        ],
        positionMs: 4400,
        session: MixSession.fromMixPlan(
            plan: MixPlan(
                id: 'restore',
                schemaVersion: 1,
                name: 'Restore',
                clips: [
                  MixPlanClip(
                      clipId: 'restore',
                      queueItemId: 'restoreq',
                      trackId: '42',
                      sourceStartMs: 0,
                      sourceEndMs: 8000,
                      timelineStartMs: 0,
                      stemEdits: edits)
                ],
                summary: const MixPlanSummary(
                    clipCount: 1, trackIds: ['42'], durationMs: 8000),
                version: 1,
                createdAt: now,
                updatedAt: now),
            queue: [
              const MediaItem(
                  id: '42', title: 'Restored', duration: Duration(seconds: 8))
            ])));
    restoredEngine = PlaybackEngine(
        voiceFactory: () => FakeVoice('restore'),
        nativeBackendFactory: () => createNativePlaybackBackend(
            libraryPath: path,
            loadManifest: (clip, hash, token) => service.getPreparedManifest(
                int.parse(clip.trackId),
                expectedSourceFileHash: hash,
                allowLoopbackHttp: true),
            loadPreparedAsset: (manifest, token) =>
                assets.acquire(manifest, cancelToken: token)));
    restoredState = PlaybackState(restoredEngine,
        signedAudioUrlService: SignedAudioUrlService.withRequester((_) async =>
            throw StateError('Restore prepared metadata without original URL')),
        persistence: store);
    await restoredState.restore();
    expect(restoredEngine.usesNativeBackend, isTrue);
    expect(restoredEngine.positionMs, 4400);
    expect(restoredEngine.isPlaying, isFalse);
    expect(fake.callback(128), 0);
    expect(restoredEngine.positionMs, 4400);
    await restoredState.play();
    expect(fake.callback(128), 0);
    for (var i = 0; i < 256; i++) {
      final sum = oracle.entries
          .where((e) => e.key != 'drums')
          .fold<double>(0, (v, e) => v + e.value[4400 * 96 + i]);
      expect(fake.sample(i), closeTo(sum, .001));
    }
    final resumePosition = restoredEngine.positionMs;
    await restoredState.stop();
    expect(restoredEngine.usesNativeBackend, isFalse);
    expect(restoredEngine.nativeDecoderCount, 0);
    expect(restoredEngine.positionMs, resumePosition);
    await restoredState.play();
    expect(restoredEngine.usesNativeBackend, isTrue);
    expect(restoredEngine.positionMs, resumePosition);
    expect(fake.callback(128), 0);
  } finally {
    await restoredEngine?.dispose();
    restoredState?.dispose();
    await engine.dispose();
    state.dispose();
    await serving.cancel();
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('main composes the optional backend into its existing playback owner',
      () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(
        RegExp(r'final playbackEngine = PlaybackEngine\(\s*nativeBackendFactory: applicationNativePlaybackFactory\(apiClient,\s*accountIdProvider: currentAccountId\)',
                multiLine: true)
            .hasMatch(source),
        isTrue);
    expect(source, contains('PlaybackState(\n    playbackEngine,'));
    final export =
        File('lib/core/engine/native_playback_backend.dart').readAsStringSync();
    expect(export,
        contains("if (dart.library.io) 'native_playback_backend_io.dart'"));
  });
  test(
      'actual app owner renders verified five-bus PCM and acknowledges live gains',
      () => HttpOverrides.runWithHttpOverrides(
          _nativeAppTracer, _FixtureHttpOverrides()));
  test(
      'saved stem documents never play original audio without native capability',
      () async {
    final clock =
        DefaultTimelineClock(uiTickInterval: const Duration(hours: 1));
    final voices = <FakeVoice>[];
    final engine = PlaybackEngine.withClock(
        clock: clock,
        voiceFactory: () {
          final voice = FakeVoice('legacy');
          voices.add(voice);
          return voice;
        });
    addTearDown(() async {
      await engine.dispose();
      await clock.dispose();
    });
    await engine.start();
    await engine.loadMix(TimelineModel(clips: [
      MixClip(
        placement: TimelineClip.clamped(
            id: 'clip',
            trackId: '42',
            sourceStartMs: 0,
            sourceEndMs: 1000,
            sourceDurationMs: 1000,
            timelineStartMs: 0),
        stemEdits: StemEdits(
            channelSet: StemChannelSet.stems5Hybrid,
            sourceFileHash: 'sha256:${'a' * 64}'),
      )
    ]));
    await expectLater(engine.play(), throwsUnsupportedError);
    expect(engine.isPlaying, isFalse);
    expect(voices.every((voice) => !voice.isPlaying), isTrue);
  });
}
