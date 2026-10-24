import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/native_mix_renderer.dart';
import 'package:open_music_player/core/engine/native_mix_schedule.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/stems/prepared_stem_manifest.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'dart:convert';

void main() {
  final library = Platform.environment['SOUNDQ_NATIVE_MIX_LIBRARY'];
  test(
      'persisted timeline compiles source identity trims seeks and all five buses',
      () {
    if (library == null) fail('Real native library required');
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 1024,
        maxAssetFrames: 96000,
        maxPreparedBytes: 3840000);
    addTearDown(engine.close);
    final manifest = automationManifest();
    final pcm = engine.preparePcm(buses: [
      for (var b = 0; b < 5; b++)
        Float32List.fromList(List.filled(192000, (b + 1) / 128))
    ]);
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: manifest.sourceFileHash,
        events: [
          for (final channel in manifest.channels) ...[
            StemGainEvent(channel: channel, atMs: 100, gain: 0, rampMs: 200),
            StemGainEvent(channel: channel, atMs: 200, gain: 1, rampMs: 100),
          ]
        ]);
    final saved = jsonDecode(jsonEncode({
      'id': 'saved',
      'schemaVersion': 1,
      'name': 'Authored performance',
      'version': 1,
      'createdAt': '2026-10-21T00:00:00Z',
      'updatedAt': '2026-10-21T00:00:00Z',
      'summary': {
        'clipCount': 1,
        'trackIds': [42],
        'durationMs': 1100
      },
      'clips': [
        {
          'clipId': 'clip',
          'queueItemId': 'queue',
          'trackId': 42,
          'sourceStartMs': 150,
          'sourceEndMs': 1150,
          'timelineStartMs': 100,
          'gainDb': -6,
          'fadeInMs': 100,
          'fadeOutMs': 100,
          'tempoPolicy': 'volumeOnly',
          'stemEdits': edits.toJson()
        }
      ],
    })) as Map<String, dynamic>;
    final timeline = TimelineModel.fromMixPlan(MixPlan.fromJson(saved),
        sourceDurationMsFor: (_) => 2000);
    final input = NativeArrangementClipInput(
        instanceId: 9,
        assetId: 22,
        sourceFrameCount: 96000,
        sourceFileHash: manifest.sourceFileHash,
        stemManifest: manifest,
        busChannels: manifest.channels,
        buses: List.filled(5, const NativeMixBus()),
        windows: [NativeArrangementWindow(assetId: 22, pcm: pcm)]);
    NativeArrangementPlan compile(int revision, int logical) =>
        NativeMixSchedule.compileArrangement(
            timeline: timeline,
            inputs: {'clip': input},
            sampleRate: 48000,
            revision: revision,
            clock: NativeMixClockAnchor(
                nativeFrame: engine.renderedFrames, timelineFrame: logical));
    for (final logical in [4800, 9600, 7200, 19200, 48000, 52800]) {
      // includes fade end and half-open EOF
      final plan = compile(engine.appliedRevision + 1, logical);
      expect(engine.submitArrangement(plan), NativeMixSubmitResult.accepted);
      final actual = engine.renderOffline(1024);
      for (var f = 0; f < 1024; f++) {
        final local = (logical - 4800 + f) / 48;
        final source = 150 + local;
        final stem = source < 200
            ? 1 - (source - 100) / 200
            : source < 300
                ? .5 + .5 * (source - 200) / 100
                : 1;
        final fade = local < 100
            ? math.sin(local / 100 * math.pi / 2)
            : local >= 900
                ? math.sin((1000 - local) / 100 * math.pi / 2)
                : 1;
        final expected =
            local >= 1000 ? 0 : 15 / 128 * math.pow(10, -6 / 20) * stem * fade;
        expect(actual[f * 2], closeTo(expected, 2e-8));
      }
    }
  });
  test('live override resumes authored replay without modifying saved points',
      () {
    if (library == null) fail('Real library required');
    final e = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 8,
        maxAssetFrames: 64,
        maxPreparedBytes: 512);
    addTearDown(e.close);
    final pcm =
        e.preparePcm(buses: [Float32List.fromList(List.filled(128, .25))]);
    const events = [
      NativeStemGainEvent(sourceFrame: 0, bus: 0, gain: 0, rampFrames: 8)
    ];
    NativeArrangementPlan p(int revision, int mask, double gain) =>
        NativeArrangementPlan(revision: revision, clips: [
          NativeArrangementClip(
              instanceId: 1,
              assetId: 1,
              startFrame: 0,
              endFrame: 64,
              sourceFrameCount: 64,
              buses: [NativeMixBus(gain: gain)],
              stemEvents: events,
              stemOverrideMask: mask)
        ], windows: [
          NativeArrangementWindow(assetId: 1, pcm: pcm)
        ]);
    expect(e.submitArrangement(p(1, 0, 1)), NativeMixSubmitResult.accepted);
    expect(e.renderOffline(2), orderedEquals([.25, .25, .21875, .21875]));
    expect(e.submitArrangement(p(2, 1, .5)), NativeMixSubmitResult.accepted);
    expect(e.renderOffline(2), everyElement(.125));
    expect(e.submitArrangement(p(3, 0, 1)), NativeMixSubmitResult.accepted);
    expect(e.renderOffline(2), orderedEquals([.125, .125, .09375, .09375]));
    expect(events.single.gain, 0);
    e.releasePcm(pcm);
    expect(pcm.isReleased, isFalse);
    e.submit(NativeMixPlan(revision: 4, decks: []));
    e.renderOffline(1);
    e.pollAppliedRevision();
    expect(pcm.isReleased, isTrue);
  });
  test(
      'unsupported source model channels fields and actual rates preserve accepted revision',
      () {
    if (library == null) fail('Real library required');
    final e = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 8,
        maxAssetFrames: 8,
        maxPreparedBytes: 64);
    addTearDown(e.close);
    final pcm =
        e.preparePcm(buses: [Float32List.fromList(List.filled(16, .25))]);
    e.submitArrangement(NativeArrangementPlan(revision: 1, clips: [
      NativeArrangementClip(
          instanceId: 1,
          assetId: 1,
          startFrame: 0,
          endFrame: 8,
          sourceFrameCount: 8,
          buses: [const NativeMixBus()])
    ], windows: [
      NativeArrangementWindow(assetId: 1, pcm: pcm)
    ]));
    e.renderOffline(1);
    final manifest = automationManifest();
    final placement = TimelineClip.clamped(
        id: 'clip',
        trackId: '42',
        sourceDurationMs: 2000,
        sourceStartMs: 0,
        sourceEndMs: 2000,
        timelineStartMs: 0);
    NativeArrangementClipInput input(
            {String? hash,
            List<String>? channels,
            PreparedStemManifest? publication}) =>
        NativeArrangementClipInput(
            instanceId: 9,
            assetId: 22,
            sourceFrameCount: 96000,
            sourceFileHash: hash ?? manifest.sourceFileHash,
            stemManifest: publication ?? manifest,
            busChannels: channels ?? manifest.channels,
            buses: List.filled(5, const NativeMixBus()),
            windows: []);
    StemEdits edits(
            {String? hash,
            String? model,
            Map<String, dynamic> unknown = const {},
            List<StemGainEvent> events = const []}) =>
        StemEdits(
            channelSet: StemChannelSet.stems5Hybrid,
            sourceFileHash: hash ?? manifest.sourceFileHash,
            stemModelVersion: model,
            unknownKeys: unknown,
            events: events);
    void reject(MixClip clip, NativeArrangementClipInput input) {
      expect(
          () => NativeMixSchedule.compileArrangement(
              timeline:
                  TimelineModel(autoTempoTransitions: false, clips: [clip]),
              inputs: {'clip': input},
              sampleRate: 48000,
              revision: 2),
          throwsA(anyOf(isA<ArgumentError>(), isA<UnsupportedError>())));
      expect(e.appliedRevision, 1);
    }

    reject(
        MixClip(
            placement: placement, stemEdits: edits(hash: 'sha256:${'c' * 64}')),
        input());
    reject(MixClip(placement: placement, stemEdits: edits(model: 'new-model')),
        input());
    reject(
        MixClip(
            placement: placement, stemEdits: edits(unknown: {'future': true})),
        input());
    reject(
        MixClip(
            placement: placement,
            stemEdits: edits(events: [
              StemGainEvent(
                  channel: 'vocals',
                  atMs: 0,
                  gain: 0,
                  unknownKeys: {'shape': 'future'})
            ])),
        input());
    reject(MixClip(placement: placement, stemEdits: edits()),
        input(channels: ['vocals', 'drums', 'bass', 'kick', 'perc']));
    reject(MixClip(placement: placement), input(hash: 'sha256:invalid'));
    reject(MixClip(placement: placement, playbackRate: 1.1), input());
    reject(
        MixClip(
            placement: placement, envelope: const GainEnvelope(baseGainDb: 1)),
        input());
    expect(e.renderOffline(1), everyElement(.25));
  });
  test('registered four buses and known empty saved document compile safely',
      () {
    final manifest = automationManifest(set: StemChannelSet.stems4Demucs);
    final timeline = TimelineModel(autoTempoTransitions: false, clips: [
      MixClip(
          placement: TimelineClip.clamped(
              id: 'clip',
              trackId: '42',
              sourceDurationMs: 2000,
              sourceStartMs: 0,
              sourceEndMs: 2000,
              timelineStartMs: 0),
          stemEdits: StemEdits(
              channelSet: StemChannelSet.stems4Demucs,
              sourceFileHash: manifest.sourceFileHash))
    ]);
    final p = NativeMixSchedule.compileArrangement(
        timeline: timeline,
        inputs: {
          'clip': NativeArrangementClipInput(
              instanceId: 1,
              assetId: 1,
              sourceFrameCount: 96000,
              sourceFileHash: manifest.sourceFileHash,
              stemManifest: manifest,
              busChannels: manifest.channels,
              buses: List.filled(4, const NativeMixBus()),
              windows: [])
        },
        sampleRate: 48000,
        revision: 1);
    expect(p.clips.single.buses.length, 4);
    expect(p.clips.single.stemEvents, isEmpty);
  });
  test('editing future authored curve reuses PCM and leaves other deck exact',
      () {
    if (library == null) fail('Real library required');
    final e = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 8,
        maxAssetFrames: 64,
        maxPreparedBytes: 512);
    addTearDown(e.close);
    final pcm = e.preparePcm(buses: [
      Float32List.fromList([
        for (var f = 0; f < 64; f++) ...[f / 256, 0]
      ])
    ]);
    NativeArrangementPlan p(int revision, double futureGain) =>
        NativeArrangementPlan(revision: revision, clips: [
          NativeArrangementClip(
              instanceId: 1,
              assetId: 1,
              startFrame: 0,
              endFrame: 32,
              sourceFrameCount: 64,
              buses: [
                const NativeMixBus()
              ],
              stemEvents: [
                NativeStemGainEvent(
                    sourceFrame: 8, bus: 0, gain: futureGain, rampFrames: 4)
              ]),
          NativeArrangementClip(
              instanceId: 2,
              assetId: 1,
              startFrame: 0,
              endFrame: 32,
              sourceFrameCount: 64,
              sourceStartFrame: 16,
              buses: [const NativeMixBus()]),
        ], windows: [
          NativeArrangementWindow(assetId: 1, pcm: pcm)
        ]);
    e.submitArrangement(p(1, 0));
    e.renderOffline(4);
    e.submitArrangement(p(2, .5));
    final out = [...e.renderOffline(8), ...e.renderOffline(4)];
    for (var f = 4; f < 16; f++) {
      final gain = f < 8
          ? 1
          : f < 12
              ? 1 - .5 * (f - 8) / 4
              : .5;
      expect(out[(f - 4) * 2], (f * gain + f + 16) / 256);
    }
    expect(e.preparedBytes, 512,
        reason: 'No re-decode or new PCM allocation for curve edit');
  });
  test(
      'overlapping authored fades match GainEnvelope rescaling and finite negative base gain',
      () {
    if (library == null) fail('Real library required');
    final e = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 1000,
        maxBlockFrames: 250,
        maxAssetFrames: 1000,
        maxPreparedBytes: 8000);
    addTearDown(e.close);
    final pcm =
        e.preparePcm(buses: [Float32List.fromList(List.filled(2000, .5))]);
    for (final curve in FadeCurve.values) {
      final envelope = GainEnvelope(
          baseGainDb: -12, fadeInMs: 800, fadeOutMs: 800, curve: curve);
      final timeline = TimelineModel(autoTempoTransitions: false, clips: [
        MixClip(
            placement: TimelineClip.clamped(
                id: 'clip',
                trackId: '42',
                sourceDurationMs: 1000,
                sourceStartMs: 0,
                sourceEndMs: 1000,
                timelineStartMs: 0),
            envelope: envelope)
      ]);
      final plan = NativeMixSchedule.compileArrangement(
          timeline: timeline,
          inputs: {
            'clip': NativeArrangementClipInput(
                instanceId: 1,
                assetId: 1,
                sourceFrameCount: 1000,
                sourceFileHash: 'sha256:${'a' * 64}',
                buses: [const NativeMixBus(gain: .5)],
                windows: [NativeArrangementWindow(assetId: 1, pcm: pcm)])
          },
          sampleRate: 1000,
          revision: curve.index + 1,
          clock: NativeMixClockAnchor(nativeFrame: e.renderedFrames),
          masterGain: .5);
      expect(e.submitArrangement(plan), NativeMixSubmitResult.accepted);
      final actual = [for (var b = 0; b < 4; b++) ...e.renderOffline(250)];
      for (var f = 0; f < 1000; f++) {
        expect(actual[2 * f], closeTo(.125 * envelope.gainAt(f, 1000), 1e-8));
      }
    }
  });
  test(
      'full compiler rejects excessive callback event density before native submit',
      () {
    final manifest = automationManifest();
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: manifest.sourceFileHash,
        events: [
          for (var i = 0; i < 65; i++)
            StemGainEvent(channel: 'vocals', atMs: i, gain: 0)
        ]);
    final timeline = TimelineModel(autoTempoTransitions: false, clips: [
      MixClip(
          placement: TimelineClip.clamped(
              id: 'clip',
              trackId: '42',
              sourceDurationMs: 2000,
              sourceStartMs: 0,
              sourceEndMs: 2000,
              timelineStartMs: 0),
          stemEdits: edits)
    ]);
    // At 48 kHz all 65 events fit a configured maximum 4096-frame block.
    expect(
        () => NativeMixSchedule.compileArrangement(
                timeline: timeline,
                sampleRate: 48000,
                revision: 1,
                maxBlockFrames: 4096,
                inputs: {
                  'clip': NativeArrangementClipInput(
                      instanceId: 1,
                      assetId: 1,
                      sourceFrameCount: 96000,
                      sourceFileHash: manifest.sourceFileHash,
                      stemManifest: manifest,
                      busChannels: manifest.channels,
                      buses: List.filled(5, const NativeMixBus()),
                      windows: [])
                }),
        throwsUnsupportedError);
  });
  test(
      'automation metadata caps reject atomically and allow exact 2048/4096 limits',
      () {
    if (library == null) fail('Real library required');
    final e = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 8,
        maxAssetFrames: 1,
        maxPreparedBytes: 8);
    addTearDown(e.close);
    List<NativeStemGainEvent> points(int count) => [
          for (var i = 0; i < count; i++)
            NativeStemGainEvent(
                sourceFrame: i * 8, bus: 0, gain: 0, rampFrames: 4)
        ];
    NativeArrangementClip c(int id, int count) => NativeArrangementClip(
        instanceId: id,
        assetId: 1,
        startFrame: (id - 1) * 20000,
        endFrame: id * 20000,
        sourceFrameCount: 20000,
        buses: [const NativeMixBus()],
        stemEvents: points(count));
    expect(
        () => e.submitArrangement(NativeArrangementPlan(
            revision: 1, clips: [c(1, 2049)], windows: [])),
        throwsArgumentError);
    expect(
        () => e.submitArrangement(NativeArrangementPlan(
            revision: 1,
            clips: [c(1, 2048), c(2, 2048), c(3, 1)],
            windows: [])),
        throwsArgumentError);
    expect(
        e.submitArrangement(NativeArrangementPlan(
            revision: 1, clips: [c(1, 2048), c(2, 2048)], windows: [])),
        NativeMixSubmitResult.accepted);
    e.renderOffline(1);
    expect(e.appliedRevision, 1);
  });
  test(
      'source anchored interrupted ramps and exact equal power fades render PCM',
      () {
    if (library == null || library.isEmpty) {
      fail('Real native library required');
    }
    final engine = NativeMixRenderer.open(
        libraryPath: library,
        sampleRate: 48000,
        maxBlockFrames: 64,
        maxAssetFrames: 64,
        maxPreparedBytes: 512);
    addTearDown(engine.close);
    final pcm =
        engine.preparePcm(buses: [Float32List.fromList(List.filled(128, .25))]);
    final events = [
      const NativeStemGainEvent(sourceFrame: 2, bus: 0, gain: 0, rampFrames: 8),
      const NativeStemGainEvent(sourceFrame: 6, bus: 0, gain: 1, rampFrames: 4),
    ];
    final clip = NativeArrangementClip(
        instanceId: 1,
        assetId: 10,
        startFrame: 2,
        endFrame: 18,
        sourceStartFrame: 4,
        sourceFrameCount: 64,
        buses: [const NativeMixBus()],
        baseGain: .5,
        envelopeSourceStartFrame: 4,
        envelopeFrameCount: 16,
        fadeInFrames: 4,
        fadeOutFrames: 4,
        stemEvents: events);
    events.clear();
    expect(clip.stemEvents.length, 2);
    expect(() => clip.stemEvents.clear(), throwsUnsupportedError);
    expect(
        engine.submitArrangement(NativeArrangementPlan(
            revision: 1,
            clips: [clip],
            windows: [NativeArrangementWindow(assetId: 10, pcm: pcm)])),
        NativeMixSubmitResult.accepted);
    final out = engine.renderOffline(20);
    for (var t = 0; t < 20; t++) {
      var expected = 0.0;
      if (t >= 2 && t < 18) {
        final source = 4 + t - 2;
        final stem = source < 6
            ? 1 - (source - 2) / 8
            : source < 10
                ? .5 + .5 * (source - 6) / 4
                : 1;
        var fade = 1.0;
        if (t < 6) fade = math.sin((t - 2) / 4 * math.pi / 2);
        if (t >= 14) fade = math.sin((18 - t) / 4 * math.pi / 2);
        expected = .25 * .5 * stem * fade;
      }
      expect(out[t * 2], closeTo(expected, 1e-7));
      expect(out[t * 2 + 1], out[t * 2]);
    }
  });
}

// Format-valid test publication, not a claim of verified music bytes.
PreparedStemManifest automationManifest(
    {StemChannelSet set = StemChannelSet.stems5Hybrid}) {
  final hash = 'sha256:${'a' * 64}';
  final roles = [
    ...set.channelIds,
    if (set.id == StemChannelSet.stems5Hybrid.id) 'drums'
  ];
  final now = DateTime.utc(2026, 10, 21);
  final objects = [
    for (final role in roles)
      <String, dynamic>{
        'channel': role,
        'sha256': 'b' * 64,
        'bytes': 100,
        'key':
            'stems/42/${set.stemModelVersion}/${'a' * 64}/g1/${role == 'melody' ? 'other' : role}/${'b' * 64}.opus',
        'duration_ms': 2000,
        'derivation': ['kick', 'perc'].contains(role)
            ? 'dsp-crossover-lr4-180'
            : 'separator',
        'sample_frames': 96000,
        'sample_rate_hz': 48000,
        'channels': 2,
        'origin_frame': 0,
        'delay_frames': 0,
        'encoder_delay_frames': 312,
        'delay_provenance': 'ffmpeg-ogg-opus-preskip-end-trim-v1',
      }
  ];
  final artifacts = {
    'objects': objects,
    'codec': {'name': 'libopus', 'sample_rate_hz': 48000, 'channels': 2},
    'null_sum': {
      'pair': ['kick', 'perc'],
      'against': 'drums',
      'passed': true,
      'residual_db': -120,
      'threshold_db': -80
    },
    'energy': {
      'frame_hz': 80,
      'frame_count': 160,
      'encoding': 'uint8-linear',
      'channels': {
        for (final role in roles) role: base64Encode(List.filled(160, 0))
      }
    },
  };
  return PreparedStemManifest.fromStatusJson({
    'schemaVersion': 1,
    'trackId': 42,
    'channelSet': set.id,
    'stemModelVersion': set.stemModelVersion,
    'sourceFileHash': hash,
    'generation': 1,
    'status': 'ready',
    'publishedManifest': {
      'schema_version': 1,
      'track_id': 42,
      'channel_set': set.id,
      'stem_model_version': set.stemModelVersion,
      'source_file_hash': hash,
      'generation': 1,
      'duration_ms': 2000,
      'source_storage_key': 'track/canonical',
      'provenance': {
        'worker': 'stemsep-worker',
        'worker_version': '2026-08-30-1'
      },
      'artifacts': artifacts
    },
    'memberDownloads': [
      for (final o in objects)
        {
          'channel': o['channel'],
          'key': o['key'],
          'sha256': o['sha256'],
          'bytes': o['bytes'],
          'url': 'https://objects.invalid/${o['key']}',
          'expiresAt': now.add(const Duration(hours: 1)).toIso8601String()
        }
    ],
  },
      expectedTrackId: 42,
      channelSet: set.id,
      expectedSourceFileHash: hash,
      now: now);
}
