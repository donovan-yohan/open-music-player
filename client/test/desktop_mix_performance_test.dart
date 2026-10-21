import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/engine/native_playback_backend.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/stems/prepared_stem_manifest.dart';
import 'package:open_music_player/core/stems/prepared_stem_assets.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/features/playlists/mix/desktop_mix_editor_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/features/playlists/mix/mix_exchange_actions.dart';

import 'desktop_mix_editor_draft_test.dart' show planJson, clipJson;
import 'support/mock_dio_client.dart';
import 'prepared_stem_manifest_test.dart' show preparedStatus, preparedSource;
import 'support/fake_voice.dart';
import 'mix_exchange_service_test.dart' show portableMix;

final sourceHash = 'sha256:${'a' * 64}';

class _LargePlanApi extends ApiClient {
  _LargePlanApi(this.plan);
  final MixPlan plan;
  @override
  Future<MixPlan> getMixPlan(String id) async => plan;
}

class PerformanceOwner extends ChangeNotifier implements PlaybackState {
  PlaybackSnapshot _snapshot = PlaybackSnapshot.empty();
  MixPlan? accepted;
  bool native = true;
  int sourceMs = 2000;
  int commands = 0;
  int clears = 0;
  int starts = 0;
  int metadataWrites = 0;
  int generation = 0;
  int revision = 0;
  int captureOffset = 0;
  StemGainAcknowledgement Function(StemGainAcknowledgement)? rewriteAck;
  Completer<void>? metadataGate;
  final Map<String, Map<String, double>> overrides = {};
  @override
  Map<String, Map<String, double>> get liveStemOverrides => overrides;
  Completer<void>? controlGate;
  bool failControl = false;
  bool failMetadata = false;
  Completer<void>? preparationGate;
  final gains = <double>[];
  @override
  PlaybackSnapshot get snapshot => _snapshot;
  @override
  bool get supportsNativePreparedPlayback => native;
  @override
  bool get usesNativePreparedPlayback => native && accepted != null;
  @override
  int get transportCommandGeneration => generation;
  @override
  int? sourcePositionMsForQueueItemId(String id) {
    final cue = snapshot.cues.where((cue) => cue.queueItemId == id).firstOrNull;
    return snapshot.playing &&
            cue != null &&
            sourceMs >= cue.sourceStart.inMilliseconds &&
            sourceMs < cue.sourceEnd.inMilliseconds
        ? sourceMs
        : null;
  }

  void publish({bool playing = true, String? session}) {
    final plan = accepted;
    final items = [
      for (final clip in plan?.clips ?? <MixPlanClip>[])
        MediaItem(
            id: clip.trackId,
            title: 'Fixture',
            duration: const Duration(seconds: 11),
            extras: const {'preparedAudio': true})
    ];
    final cues = plan == null
        ? <PlaybackCue>[]
        : CueTimeline.fromSession(
            session: MixSession.fromMixPlan(plan: plan, queue: items),
            queue: items,
            playOrder: [for (var i = 0; i < items.length; i++) i]).cues;
    _snapshot = PlaybackSnapshot(
        sessionId: session ?? 'mix_plan_${plan?.id}_v${plan?.version}',
        cues: cues,
        currentCueId: cues.firstOrNull?.cueId,
        currentQueueIndex: cues.isEmpty ? null : 0,
        currentMediaItem: items.firstOrNull,
        localPosition: Duration(milliseconds: sourceMs - 1000),
        localDuration: const Duration(seconds: 10),
        globalPosition: Duration(milliseconds: sourceMs - 1000),
        globalDuration: const Duration(seconds: 10),
        playing: playing,
        processingState: ProcessingState.ready,
        activeVoiceCount: playing ? cues.length : 0);
    notifyListeners();
  }

  @override
  Future<void> playMixPlan(List<Map<String, dynamic>> tracks, MixPlan plan,
      {int startIndex = 0, PlaybackContext? context}) async {
    starts++;
    generation++;
    final requestGeneration = generation;
    expect(tracks.length, plan.clips.length);
    for (var i = 0; i < tracks.length; i++) {
      expect(tracks[i]['id'].toString(), plan.clips[i].trackId);
      expect(tracks[i].containsKey('url'), isFalse);
    }
    await preparationGate?.future;
    if (generation != requestGeneration) return;
    accepted = plan;
    publish();
  }

  @override
  Future<void> play() async {
    generation++;
    publish();
  }

  @override
  Future<void> pause() async {
    generation++;
    publish(playing: false);
  }

  @override
  Future<void> stop() async {
    generation++;
    publish(playing: false);
  }

  @override
  Future<StemGainAcknowledgement> setStemGain(
      String queueItemId, String channel, double gain,
      {int rampMs = 8}) async {
    commands++;
    gains.add(gain);
    final captureSourceMs = sourceMs + captureOffset;
    await controlGate?.future;
    if (failControl) throw StateError('Control rejected');
    overrides.putIfAbsent(queueItemId, () => {})[channel] = gain;
    final ack = StemGainAcknowledgement(
        queueItemId: queueItemId,
        sourceFileHash: sourceHash,
        stemModelVersion: StemChannelSet.stems5Hybrid.stemModelVersion,
        captureSourcePositionMs: captureSourceMs,
        channel: channel,
        gain: gain,
        sourcePositionMs: sourceMs + 3,
        revision: ++revision);
    return rewriteAck?.call(ack) ?? ack;
  }

  @override
  Future<void> setQueueStemEditsByQueueItemId(
      String queueItemId, StemEdits? edits,
      {required String expectedSourceFileHash}) async {
    if (failMetadata) throw StateError('Revision rejected');
    await metadataGate?.future;
    metadataWrites++;
    final p = accepted!;
    accepted = MixPlan(
        id: p.id,
        schemaVersion: p.schemaVersion,
        name: p.name,
        clips: [
          for (final c in p.clips)
            if (c.queueItemId == queueItemId) c.withStemEdits(edits) else c
        ],
        summary: p.summary,
        version: p.version,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt);
    publish(playing: snapshot.playing);
  }

  @override
  Future<void> clearStemOverrides(String queueItemId) async {
    clears++;
    overrides.remove(queueItemId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PerformanceFixture {
  PerformanceFixture(this.owner);
  final PerformanceOwner owner;
  Map<String, dynamic> server = planJson(clips: [
    {
      ...clipJson(),
      'stemEdits': StemEdits(
              channelSet: StemChannelSet.stems5Hybrid,
              sourceFileHash: sourceHash)
          .toJson()
    }
  ]);
  final requests = <String>[];
  Completer<void>? verificationGate;
  late final ApiClient api = mockQueueApiClient((request) async {
    requests.add(request.method);
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body);
      expect(body['version'], server['version']);
      server = {
        ...server,
        'version': (server['version'] as int) + 1,
        'clips': body['clips']
      };
    } else if (request.method == 'GET' && requests.contains('PUT')) {
      await verificationGate?.future;
    }
    return http.Response(jsonEncode(server), 200);
  });
  Future<void> mount(WidgetTester tester, {ApiClient? apiOverride}) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: apiOverride ?? api),
          ChangeNotifierProvider<PlaybackState>.value(value: owner),
        ],
        child:
            const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final mismatch in [
    'queue',
    'hash',
    'model',
    'channel',
    'gain',
    'revision',
    'capture-start',
    'capture-end'
  ]) {
    testWidgets('EOF acknowledgement rejects mismatched $mismatch',
        (tester) async {
      final owner = PerformanceOwner()
        ..sourceMs = 1998
        ..controlGate = Completer<void>()
        ..rewriteAck = (ack) => StemGainAcknowledgement(
            queueItemId: mismatch == 'queue' ? 'other' : ack.queueItemId,
            sourceFileHash:
                mismatch == 'hash' ? 'sha256:${'b' * 64}' : ack.sourceFileHash,
            stemModelVersion:
                mismatch == 'model' ? 'other-model' : ack.stemModelVersion,
            channel: mismatch == 'channel' ? 'bass' : ack.channel,
            gain: mismatch == 'gain' ? .8 : ack.gain,
            revision: mismatch == 'revision' ? 0 : ack.revision,
            captureSourcePositionMs: mismatch == 'capture-start'
                ? 999
                : mismatch == 'capture-end'
                    ? 2000
                    : ack.captureSourcePositionMs,
            sourcePositionMs: ack.sourcePositionMs);
      final fixture = PerformanceFixture(owner);
      fixture.server['clips'][0]['sourceEndMs'] = 2000;
      await fixture.mount(tester);
      await tester.tap(find.byKey(const ValueKey('mix-play')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mix-record')));
      await tester.pump();
      final slider =
          tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
      slider.onChangeStart!(1);
      slider.onChanged!(.37);
      slider.onChangeEnd!(.37);
      await tester.pump();
      expect(owner.commands, 1);
      owner.sourceMs = 2000;
      owner.publish();
      owner.controlGate!.complete();
      await tester.pumpAndSettle();
      expect(owner.metadataWrites, 0);
      expect(owner.accepted!.clips.single.stemEdits!.events, isEmpty);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.textContaining('Live change not recorded'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  for (final cancellation in [
    'pause',
    'session',
    'track',
    'source',
    'model',
    'authored',
    'document',
    'route'
  ]) {
    testWidgets('pending recording rejects $cancellation cancellation',
        (tester) async {
      final owner = PerformanceOwner()..controlGate = Completer<void>();
      final fixture = PerformanceFixture(owner);
      await fixture.mount(tester);
      await tester.tap(find.byKey(const ValueKey('mix-play')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mix-record')));
      await tester.pump();
      final slider =
          tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
      slider.onChangeStart!(1);
      slider.onChanged!(.37);
      slider.onChangeEnd!(.37);
      await tester.pump();
      expect(owner.commands, 1);
      switch (cancellation) {
        case 'pause':
          await owner.pause();
        case 'session':
          owner.publish(session: 'unrelated');
        case 'track':
          final plan = owner.accepted!;
          owner.accepted = MixPlan.fromJson({
            ...planJson(version: plan.version),
            'clips': [
              {...plan.clips.single.toJson(), 'trackId': 43}
            ]
          });
          owner.publish();
        case 'source':
        case 'model':
        case 'authored':
          final plan = owner.accepted!;
          final clip = plan.clips.single.toJson();
          final edits = Map<String, dynamic>.from(clip['stemEdits']);
          if (cancellation == 'source') {
            edits['sourceFileHash'] = 'sha256:${'b' * 64}';
          } else if (cancellation == 'model') {
            edits['stemModelVersion'] = 'other-model';
          } else {
            edits['events'] = [
              StemGainEvent(channel: 'bass', atMs: 1500, gain: .4).toJson()
            ];
          }
          owner.accepted = MixPlan.fromJson({
            ...planJson(version: plan.version),
            'clips': [
              {...clip, 'stemEdits': edits}
            ]
          });
          owner.publish();
        case 'document':
          await tester.enterText(
              find.byKey(const ValueKey('mix-field-placement')), '100');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pump();
        case 'route':
          await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      }
      owner.controlGate!.complete();
      await tester.pumpAndSettle();
      expect(owner.metadataWrites, 0);
      expect(
          owner.accepted!.clips.single.stemEdits!.events
              .where((event) => event.channel == 'vocals'),
          isEmpty);
      expect(fixture.requests, ['GET']);
      if (cancellation != 'route') {
        expect(
            find.text(cancellation == 'document' ? 'Unsaved changes' : 'Saved'),
            findsOneWidget);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets(
      'valid pre-submit capture records after the selected clip reaches EOF',
      (tester) async {
    final owner = PerformanceOwner()
      ..sourceMs = 998
      ..controlGate = Completer<void>()
      ..metadataGate = Completer<void>();
    final fixture = PerformanceFixture(owner);
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid, sourceFileHash: sourceHash);
    fixture.server = planJson(clips: [
      {
        ...clipJson(),
        'sourceStartMs': 0,
        'sourceEndMs': 1000,
        'stemEdits': edits.toJson()
      },
      {
        ...clipJson(id: 'b'),
        'sourceStartMs': 0,
        'sourceEndMs': 2000,
        'stemEdits': edits.toJson()
      }
    ]);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pump();
    expect(owner.commands, 1);
    owner.sourceMs = 1000;
    owner.publish();
    await tester.pump();
    expect(owner.snapshot.playing, isTrue);
    expect(owner.sourcePositionMsForQueueItemId('q-a'), isNull);
    expect(owner.sourcePositionMsForQueueItemId('q-b'), 1000);
    owner.controlGate!.complete();
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 0);
    expect(find.text('Saved'), findsOneWidget,
        reason: 'The metadata revision must also be acknowledged first.');
    owner.metadataGate!.complete();
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 1,
        reason: 'Accepted capture is inside the half-open selected range.');
    final events = owner.accepted!.clips.first.stemEdits!.events;
    expect(events.single.atMs, 998);
    expect(events.single.gain, .37);
    expect(owner.accepted!.clips.last.stemEdits!.events, isEmpty);
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(fixture.server['clips'][0]['stemEdits']['events'][0]['atMs'], 998);
    expect(find.text('Saved'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('natural arrangement completion retains a pending accepted take',
      (tester) async {
    final owner = PerformanceOwner()
      ..sourceMs = 10998
      ..controlGate = Completer<void>();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pump();
    expect(owner.commands, 1);
    owner.sourceMs = 11000;
    owner.publish(playing: false);
    await tester.pump();
    owner.controlGate!.complete();
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 1);
    expect(owner.accepted!.clips.single.stemEdits!.events.single.atMs, 10998);
    expect(find.text('Unsaved changes'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'save readback preserves an armed movement whose gain acknowledgement is pending',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final finder = find.byKey(const ValueKey('mix-stem-vocals'));
    var slider = tester.widget<Slider>(finder);
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 1);

    fixture.verificationGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    for (var i = 0; i < 10 && fixture.requests.length < 3; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(fixture.requests, ['GET', 'PUT', 'GET']);
    expect(find.text('Saving…'), findsOneWidget);
    owner.sourceMs = 3000;
    owner.controlGate = Completer<void>();
    slider = tester.widget<Slider>(finder);
    expect(slider.onChanged, isNotNull,
        reason: 'Recording remains available during save verification.');
    slider.onChangeStart!(.37);
    slider.onChanged!(.62);
    slider.onChangeEnd!(.62);
    await tester.pump();
    expect(owner.commands, 2);
    expect(owner.metadataWrites, 1);

    fixture.verificationGate!.complete();
    await tester.pumpAndSettle();
    expect(fixture.server['clips'][0]['stemEdits']['events'].length, 1);
    owner.controlGate!.complete();
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 2,
        reason: 'Save readback cannot invalidate a value-identical draft.');
    expect(owner.accepted!.clips.single.stemEdits!.events.map((e) => e.atMs),
        [2000, 3000]);
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.textContaining('Live change not recorded'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    final points = fixture.server['clips'][0]['stemEdits']['events'] as List;
    expect(points.map((e) => e['atMs']), [2000, 3000]);
    expect(points.map((e) => e['gain']), [.37, .62]);
    expect(find.text('Saved'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'missing stems require explicit refresh and never attach an invented identity',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];
    final api = mockQueueApiClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.url.path.endsWith('/stems')) {
        if (request.method == 'POST') {
          return http.Response(
              jsonEncode({
                'trackId': 42,
                'channelSet': defaultStemChannelSet,
                'status': 'pending',
                'queued': true
              }),
              202);
        }
        return http.Response('{"code":"STEMS_NOT_FOUND"}', 404);
      }
      return http.Response(jsonEncode(planJson()), 200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child:
            const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    await tester.ensureVisible(find.text('Prepare stems'));
    await tester.tap(find.text('Prepare stems'));
    await tester.pumpAndSettle();
    expect(find.text('Preparing stems'), findsOneWidget);
    expect(find.text('Refresh stems'), findsOneWidget);
    expect(find.byKey(const ValueKey('mix-stem-vocals')), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
    final before = calls.length;
    await tester.pump(const Duration(seconds: 30));
    expect(calls.length, before,
        reason: 'No polling timer or automatic separation loop');
    expect(calls, [
      'GET /api/v1/mix-plans/plan-1',
      'GET /api/v1/tracks/42/stems',
      'POST /api/v1/tracks/42/stems',
      'GET /api/v1/tracks/42/stems'
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'aggregate event budget is admitted before any native slider command',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    fixture.server = planJson(clips: [
      for (var i = 0; i < 3; i++)
        {
          ...clipJson(id: i == 0 ? 'a' : '$i'),
          'stemEdits': StemEdits(
              channelSet: StemChannelSet.stems5Hybrid,
              sourceFileHash: sourceHash,
              events: [
                for (var j = 0; j < (i == 2 ? 1096 : 1500); j++)
                  StemGainEvent(channel: 'bass', atMs: j, gain: 1)
              ]).toJson()
        }
    ]);
    await fixture.mount(tester,
        apiOverride: _LargePlanApi(MixPlan.fromJson(fixture.server)));
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pumpAndSettle();
    expect(owner.commands, 0);
    expect(find.textContaining('4096'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'picker import uses real exchange dialog and verified document navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];
    final api = mockQueueApiClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/v1/mix-plans' && request.method == 'GET') {
        return http.Response(jsonEncode([planJson()]), 200);
      }
      return http.Response(
          jsonEncode(planJson()), request.method == 'POST' ? 201 : 200);
    });
    final router = GoRouter(initialLocation: '/mixes', routes: [
      GoRoute(
          path: '/mixes', builder: (_, __) => const DesktopMixEditorPicker()),
      GoRoute(
          path: '/mixes/:id',
          builder: (_, state) =>
              DesktopMixEditorScreen(planId: state.pathParameters['id']!)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api, child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Mix import and export'));
    await tester.pumpAndSettle();
    expect(find.text('Export mix'), findsNothing);
    await tester.tap(find.text('Import mix'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('mix-import-json')),
        jsonEncode(portableMix()));
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(find.text('Night drive'), findsOneWidget);
    expect(
        calls,
        containsAllInOrder(
            ['POST /api/v1/mix-plans/import', 'GET /api/v1/mix-plans/plan-1']));
    expect(tester.widget<MixExchangeMenu>(find.byType(MixExchangeMenu)).planId,
        'plan-1');
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('mix-field-placement')), '100');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.widget<MixExchangeMenu>(find.byType(MixExchangeMenu)).enabled,
        isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'acknowledged capture is capacity checked again before metadata admission',
      (tester) async {
    final owner = PerformanceOwner()..captureOffset = 19;
    final fixture = PerformanceFixture(owner);
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: sourceHash,
        events: [
          for (var i = 0; i < 2048; i++)
            StemGainEvent(channel: 'vocals', atMs: 2000 + i * 100, gain: 1)
        ]);
    fixture.server = planJson(clips: [
      {...clipJson(), 'stemEdits': edits.toJson()}
    ]);
    await fixture.mount(tester,
        apiOverride: _LargePlanApi(MixPlan.fromJson(fixture.server)));
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pumpAndSettle();
    expect(owner.commands, 1);
    expect(owner.metadataWrites, 0);
    expect(find.textContaining('Live change not recorded'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'disposing during preparation cancels only the owning transport request',
      (tester) async {
    final owner = PerformanceOwner()..preparationGate = Completer<void>();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pump();
    expect(owner.starts, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    owner.preparationGate!.complete();
    await tester.pumpAndSettle();
    expect(owner.accepted, isNull);
    expect(owner.snapshot.playing, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'bounded controls expose overflow and never persist a pending gesture',
      (tester) async {
    final owner = PerformanceOwner()..controlGate = Completer<void>();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      slider.onChanged!(.5);
    }
    owner.controlGate!.complete();
    slider.onChangeEnd!(.5);
    await tester.pumpAndSettle();
    expect(owner.commands, 1);
    expect(owner.metadataWrites, 0);
    expect(find.textContaining('controls are busy'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'recording uses acknowledged pre-submit source capture, not pointer or block end',
      (tester) async {
    final owner = PerformanceOwner()..captureOffset = 19;
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pumpAndSettle();
    expect(owner.accepted!.clips.single.stemEdits!.events.single.atMs, 2019);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets('per-clip event budget rejects recording before native control',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: sourceHash,
        events: [
          for (var i = 0; i < 2048; i++)
            StemGainEvent(channel: 'bass', atMs: i, gain: 1)
        ]);
    fixture.server = planJson(clips: [
      {...clipJson(), 'stemEdits': edits.toJson()}
    ]);
    await fixture.mount(tester,
        apiOverride: _LargePlanApi(MixPlan.fromJson(fixture.server)));
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pumpAndSettle();
    expect(owner.commands, 0);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.textContaining('budget'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('forward source jump keeps skipped edits and one gesture undo',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: sourceHash,
        events: [StemGainEvent(channel: 'vocals', atMs: 3000, gain: .8)]);
    fixture.server = planJson(clips: [
      {...clipJson(), 'stemEdits': edits.toJson()}
    ]);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final finder = find.byKey(const ValueKey('mix-stem-vocals'));
    tester.widget<Slider>(finder).onChangeStart!(1);
    tester.widget<Slider>(finder).onChanged!(.37);
    await tester.pumpAndSettle();
    owner.sourceMs = 5000;
    tester.widget<Slider>(finder).onChanged!(0);
    await tester.pumpAndSettle();
    tester.widget<Slider>(finder).onChangeEnd!(0);
    await tester.pumpAndSettle();
    expect(owner.accepted!.clips.single.stemEdits!.events.map((e) => e.atMs),
        [2000, 3000, 5000]);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(fixture.server['clips'][0]['stemEdits']['events'].length, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  for (final scenario in [
    'record',
    'eof',
    'seek',
    'local-scrub',
    'timeline-scrub'
  ]) {
    final crossesEof = scenario == 'eof';
    final cancelsRecording = scenario != 'record' && !crossesEof;
    testWidgets(
        cancelsRecording
            ? 'real playback owner cancels pending recording on $scenario intent'
            : crossesEof
                ? 'real playback owner records pre-submit capture across clip EOF'
                : 'real playback owner accepts desktop recorded controls through compiled native callbacks',
        (tester) async {
      await tester.runAsync(() async {
        final library =
            Platform.environment['SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY'];
        expect(library, isNotNull,
            reason:
                'Compiled deterministic host required; never opens OS audio.');
        final lib = ffi.DynamicLibrary.open(library!);
        final reset = lib.lookupFunction<ffi.Int32 Function(), int Function()>(
            'sq_ffi_test_reset');
        final callback = lib.lookupFunction<ffi.Int32 Function(ffi.Uint32),
            int Function(int)>('sq_ffi_test_callback');
        expect(reset(), 0);
        final temp = await Directory(Platform.environment['TMPDIR']!)
            .createTemp('desktop-recording-');
        final file = File('${temp.path}/fixture.opus');
        final result = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-f',
          'lavfi',
          '-i',
          'aevalsrc=0.01*sin(2*PI*317*t)|0.01*sin(2*PI*997*t):s=48000:d=1',
          '-c:a',
          'libopus',
          file.path
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final bytes = await file.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        final body = preparedStatus();
        final head = String.fromCharCodes(bytes).indexOf('OpusHead');
        final members =
            body['publishedManifest']['artifacts']['objects'] as List;
        for (final member in members) {
          final role = member['channel'];
          member['bytes'] = bytes.length;
          member['sha256'] = digest;
          member['key'] =
              'stems/42/${body['stemModelVersion']}/${preparedSource.substring(7)}/g7/${role == 'melody' ? 'other' : role}/$digest.opus';
          member['encoder_delay_frames'] =
              bytes[head + 10] | bytes[head + 11] << 8;
          final download = (body['memberDownloads'] as List)
              .singleWhere((d) => d['channel'] == role);
          download['bytes'] = bytes.length;
          download['sha256'] = digest;
          download['key'] = member['key'];
          download['url'] = 'https://fixture.invalid/${member['key']}';
          download['expiresAt'] =
              DateTime.now().add(const Duration(hours: 1)).toIso8601String();
        }
        final manifest = PreparedStemManifest.fromStatusJson(body,
            expectedTrackId: 42,
            channelSet: StemChannelSet.stems5Hybrid.id,
            expectedSourceFileHash: preparedSource);
        final assets = PreparedStemAssets(
            rootDirectory: Directory('${temp.path}/assets'),
            downloader: (url, path, {cancelToken, onProgress}) async =>
                File(path).writeAsBytes(bytes).then((_) {}));
        final engine = PlaybackEngine(
            voiceFactory: () => FakeVoice('unused'),
            nativeBackendFactory: () => createNativePlaybackBackend(
                libraryPath: library,
                loadManifest: (clip, hash, token) async => manifest,
                loadPreparedAsset: (manifest, token) =>
                    assets.acquire(manifest, cancelToken: token)));
        final owner = PlaybackState(engine,
            signedAudioUrlService: SignedAudioUrlService.withRequester(
                (_) async =>
                    throw StateError('Prepared path must not fetch original')));
        var server = planJson(clips: [
          {
            ...clipJson(),
            'sourceStartMs': 0,
            'sourceEndMs': 1000,
            'stemEdits': StemEdits(
                    channelSet: StemChannelSet.stems5Hybrid,
                    sourceFileHash: preparedSource)
                .toJson()
          }
        ]);
        if (crossesEof) {
          server = {
            ...server,
            'clips': [
              ...server['clips'],
              {
                ...server['clips'][0],
                'clipId': 'b',
                'queueItemId': 'q-b',
                'timelineStartMs': 500
              }
            ]
          };
        }
        final api = mockQueueApiClient((request) async {
          if (request.method == 'PUT') {
            server = {
              ...server,
              'version': 4,
              'clips': jsonDecode(request.body)['clips']
            };
          }
          return http.Response(jsonEncode(server), 200);
        });
        tester.view.physicalSize = const Size(1440, 1400);
        tester.view.devicePixelRatio = 1;
        try {
          await tester.pumpWidget(MultiProvider(
              providers: [
                Provider<ApiClient>.value(value: api),
                ChangeNotifierProvider<PlaybackState>.value(value: owner)
              ],
              child: const MaterialApp(
                  home: DesktopMixEditorScreen(planId: 'plan-1'))));
          for (var i = 0; i < 30; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            await tester.pump();
          }
          await tester.tap(find.byKey(const ValueKey('mix-play')));
          for (var i = 0; i < 300 && !owner.snapshot.playing; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await tester.pump();
          }
          expect(owner.usesNativePreparedPlayback, isTrue);
          expect(owner.snapshot.playing, isTrue);
          if (crossesEof) {
            await owner.seek(const Duration(milliseconds: 998));
            expect(owner.sourcePositionMsForQueueItemId('q-a'), 998);
          } else {
            expect(callback(128), 0);
            expect(owner.sourcePositionMsForQueueItemId('q-a'), 2);
          }
          await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
          await tester.pump();
          expect(
              tester
                  .widget<IconButton>(find.byKey(const ValueKey('mix-record')))
                  .onPressed,
              isNotNull);
          await tester.tap(find.byKey(const ValueKey('mix-record')));
          await tester.pump();
          final slider = tester
              .widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
          slider.onChangeStart!(1);
          slider.onChanged!(.37);
          slider.onChangeEnd!(.37);
          if (cancelsRecording) {
            // Submit a gain, but deliberately hold its native callback ACK.
            await Future<void>.delayed(const Duration(milliseconds: 5));
            await tester.pump();
            Future<void> transport;
            switch (scenario) {
              case 'seek':
                transport = owner.seek(const Duration(milliseconds: 100));
              case 'local-scrub':
                owner.beginLocalScrub();
                owner.updateLocalScrub(const Duration(milliseconds: 100));
                transport =
                    owner.endLocalScrub(const Duration(milliseconds: 100));
              case 'timeline-scrub':
                owner.beginTimelineScrub();
                owner.updateTimelineScrub(100);
                transport = owner.endTimelineScrub(100);
              default:
                throw StateError('Unexpected transport fixture');
            }
            var complete = false;
            Object? failure;
            final observed = transport.then<void>((_) => complete = true,
                onError: (Object e) {
              failure = e;
              complete = true;
            });
            for (var i = 0; i < 150; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
              expect(callback(128), 0);
              await tester.pump();
            }
            expect(complete, isTrue);
            await observed;
            expect(failure, isNull);
            expect(owner.snapshot.cues.first.stemEdits!.events, isEmpty,
                reason:
                    'Explicit transport intent revokes the submitted recording lease.');
            expect(find.text('Saved'), findsOneWidget);
            return;
          }
          for (var i = 0;
              i < 100 && owner.snapshot.cues.first.stemEdits!.events.isEmpty;
              i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            expect(callback(128), 0);
            await tester.pump();
          }
          expect(owner.snapshot.cues.first.stemEdits!.events.single.gain, .37);
          if (crossesEof) {
            expect(owner.sourcePositionMsForQueueItemId('q-a'), isNull);
            expect(owner.sourcePositionMsForQueueItemId('q-b'), isNotNull);
            expect(owner.snapshot.playing, isTrue);
            expect(owner.snapshot.cues.last.stemEdits!.events, isEmpty);
          }
          for (var i = 0; i < 10; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            await tester.pump();
          }
          expect(find.text('Unsaved changes'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('mix-save')));
          for (var i = 0; i < 30; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            await tester.pump();
          }
          final event = server['clips'][0]['stemEdits']['events'][0];
          expect(event['atMs'], crossesEof ? 998 : 2,
              reason: 'Pre-submit capture source time, not post-ACK block end');
          expect(event['gain'], .37);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          owner.dispose();
          await engine.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          temp.deleteSync(recursive: true);
        }
      });
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
  testWidgets(
      'pending acknowledgement after clip change cannot attach automation',
      (tester) async {
    final owner = PerformanceOwner()..controlGate = Completer<void>();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(0);
    await tester.pump();
    expect(owner.commands, 1);
    await tester.tap(find.byKey(const ValueKey('mix-pause')));
    await tester.pump();
    slider.onChangeEnd!(0);
    owner.controlGate!.complete();
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 0);
    expect(find.text('Saved'), findsOneWidget);
    expect(fixture.requests, ['GET']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'metadata rejection retains a visible live-only change, not saved automation',
      (tester) async {
    final owner = PerformanceOwner()..failMetadata = true;
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final slider =
        tester.widget<Slider>(find.byKey(const ValueKey('mix-stem-vocals')));
    slider.onChangeStart!(1);
    slider.onChanged!(0);
    slider.onChangeEnd!(0);
    await tester.pumpAndSettle();
    expect(owner.commands, 1);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.textContaining('Live change not recorded'), findsOneWidget);
    final restore = find.byKey(const ValueKey('mix-restore-recorded'));
    await tester.ensureVisible(restore);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(owner.clears, 1);
    expect(fixture.requests, ['GET']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'unrelated playing session never enables recording or on-air status',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    owner.publish(session: 'unrelated');
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    expect(find.text('On air'), findsNothing);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('mix-record')))
            .onPressed,
        isNull);
    expect(owner.starts, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  test('stem status rejects malformed source identity and generations', () {
    final body = preparedStatus();
    expect(TrackStems.fromJson(body).sourceFileHash, preparedSource);
    expect(TrackStems.fromJson(body).generation, 7);
    for (final hash in ['invalid', null, 'sha256:${'A' * 64}']) {
      expect(() => TrackStems.fromJson({...body, 'sourceFileHash': hash}),
          throwsFormatException);
    }
    for (final generation in [-1, 1.5, null, '7']) {
      expect(() => TrackStems.fromJson({...body, 'generation': generation}),
          throwsFormatException);
    }
  });

  testWidgets('prepare stems attaches only a matching typed ready manifest',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var server = planJson();
    final ready = preparedStatus();
    ready['publishedManifest']['duration_ms'] = 11000;
    ready['publishedManifest']['artifacts']['energy']['frame_count'] = 880;
    ready['publishedManifest']['artifacts']['energy']['channels'] = {
      for (final role in ['vocals', 'melody', 'bass', 'kick', 'perc', 'drums'])
        role: base64Encode(List.filled(880, 0))
    };
    for (final member in ready['publishedManifest']['artifacts']['objects']) {
      member['duration_ms'] = 11000;
      member['sample_frames'] = 528000;
    }
    for (final download in ready['memberDownloads']) {
      download['expiresAt'] =
          DateTime.now().add(const Duration(hours: 1)).toIso8601String();
    }
    final api = mockQueueApiClient((request) async {
      if (request.url.path.endsWith('/stems')) {
        return http.Response(jsonEncode(ready), 200);
      }
      if (request.method == 'PUT') {
        server = {
          ...server,
          'version': 4,
          'clips': jsonDecode(request.body)['clips']
        };
      }
      return http.Response(jsonEncode(server), 200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child:
            const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    final prepare = find.text('Prepare stems');
    await tester.ensureVisible(prepare);
    await tester.tap(prepare);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mix-stem-vocals')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(server['clips'][0]['stemEdits']['sourceFileHash'], preparedSource);
    expect(server['clips'][0]['stemEdits']['events'], isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'record off changes only live gain; recording saves acknowledged source samples and one undo',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    final finder = find.byKey(const ValueKey('mix-stem-vocals'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    var slider = tester.widget<Slider>(finder);
    slider.onChangeStart!(1);
    slider.onChanged!(.37);
    slider.onChangeEnd!(.37);
    await tester.pumpAndSettle();
    expect(owner.gains, [.37]);
    expect(owner.metadataWrites, 0);
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    slider = tester.widget<Slider>(finder);
    slider.onChangeStart!(.37);
    for (final entry in [(2200, 0.0), (2300, .37), (2400, 1.0)]) {
      owner.sourceMs = entry.$1;
      tester.widget<Slider>(finder).onChanged!(entry.$2);
      await tester.pumpAndSettle();
    }
    tester.widget<Slider>(finder).onChangeEnd!(1);
    await tester.pumpAndSettle();
    expect(owner.metadataWrites, 3);
    expect(fixture.requests, ['GET']);
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    final points = fixture.server['clips'][0]['stemEdits']['events'] as List;
    expect(points.map((e) => e['atMs']), [2200, 2300, 2400]);
    expect(points.map((e) => e['gain']), [0, .37, 1]);
    expect(fixture.requests, ['GET', 'PUT', 'GET']);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(fixture.server['clips'][0]['stemEdits']['events'], isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('failed native gain leaves document and history unchanged',
      (tester) async {
    final owner = PerformanceOwner()..failControl = true;
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-record')));
    await tester.pump();
    final finder = find.byKey(const ValueKey('mix-stem-vocals'));
    final slider = tester.widget<Slider>(finder);
    slider.onChangeStart!(1);
    slider.onChanged!(0);
    slider.onChangeEnd!(0);
    await tester.pumpAndSettle();
    expect(owner.commands, 1);
    expect(owner.metadataWrites, 0);
    expect(find.text('Saved'), findsOneWidget);
    expect(
        tester
            .widgetList<IconButton>(find.byType(IconButton))
            .singleWhere((b) => b.tooltip == 'Undo')
            .onPressed,
        isNull);
    expect(find.textContaining('Control rejected'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'explicit transport uses existing owner; mount never starts audio',
      (tester) async {
    final owner = PerformanceOwner();
    final fixture = PerformanceFixture(owner);
    await fixture.mount(tester);
    expect(owner.starts, 0);
    expect(find.text('On air'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mix-play')));
    await tester.pumpAndSettle();
    expect(owner.starts, 1);
    expect(find.text('On air'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mix-pause')));
    await tester.pumpAndSettle();
    expect(owner.snapshot.playing, isFalse);
    expect(find.text('On air'), findsNothing);
    expect(fixture.requests, ['GET']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
