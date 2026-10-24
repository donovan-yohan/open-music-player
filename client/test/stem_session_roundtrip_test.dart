import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/queue_timeline_controller.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('serialized reorder and metadata refresh retain occurrence edits',
      () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.controller.setQueue([_item(), _item()]);
    final id = harness.controller.session.clips[0].queueItemId;
    final reorder = harness.controller.reorderQueue(0, 1);
    final edit = harness.controller.setStemEditsByQueueItemId(
      id,
      _edits(0.25),
      expectedSourceFileHash: _hash,
    );
    await Future.wait([reorder, edit]);
    expect(harness.controller.session.clips[0].stemEdits, isNull);
    expect(harness.controller.session.clips[1].queueItemId, id);
    expect(harness.controller.session.clips[1].stemEdits, _edits(0.25));
    await harness.controller.setQueue([
      _item().copyWith(title: 'Updated'),
      _item().copyWith(title: 'Updated'),
    ], preserveTimelineEdits: true, preserveCurrentTransport: true);
    expect(harness.controller.session.clips[1].stemEdits, _edits(0.25));
    expect(harness.controller.snapshot.cues[1].stemEdits, _edits(0.25));
    expect(
        harness.engine.model.clips
            .singleWhere((clip) => clip.queueItemId == id)
            .stemEdits,
        _edits(0.25));
  });

  test('nested future extension data remains lossless through JSON and payload',
      () {
    final edits = StemEdits.fromJson({
      ..._edits(0.25).toJson(),
      'futureDocument': {
        'nested': [
          1,
          null,
          true,
          {'v': 'preserve'}
        ]
      },
      'beatGridRef': {
        ..._edits(0.25).beatGridRef!.toJson(),
        'futureGrid': ['a', 'b'],
      },
      'events': [
        {
          ..._edits(0.25).events.single.toJson(),
          'futureEvent': {
            'curve': [0.1, 0.3]
          },
        }
      ],
    });
    final session =
        MixSession.fromMixPlan(plan: _plan([edits]), queue: [_item()]);
    final restored = QueueSnapshot.decode(QueueSnapshot(
      tracks: [mediaItemToPlaybackJson(_item())],
      session: session,
    ).encode())
        .session!;
    final payload = CueTimeline.fromSession(
        session: restored,
        queue: [_item()],
        playOrder: [0]).toTimelineModel().toMixPlanPayload();
    expect((payload['clips'] as List).single['stemEdits'], edits.toJson());
  });

  test('a malformed document on an invalid clip is not silently dropped', () {
    final json =
        MixSession.fromMixPlan(plan: _plan([_edits(0.25)]), queue: [_item()])
            .toJson();
    (json['clips'] as List)[0]['clipId'] = '';
    (json['clips'] as List)[0]['stemEdits'] = 'corrupt';
    expect(() => MixSession.fromJson(json),
        throwsA(isA<StemEditsFormatException>()));
  });

  test(
      'invalid owner identity commands leave session snapshot and model unchanged',
      () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.controller.setQueue([_item()]);
    final before = harness.controller.session;
    final snapshot = harness.controller.snapshot;
    final model = harness.engine.model;
    final id = before.clips.single.queueItemId;
    final otherHash = 'sha256:${List.filled(64, 'b').join()}';
    await expectLater(
        harness.controller.setStemEditsByQueueItemId(
          'missing',
          _edits(0.25),
          expectedSourceFileHash: _hash,
        ),
        throwsArgumentError);
    await expectLater(
        harness.controller.setStemEditsByQueueItemId(
          id,
          _edits(0.25),
          expectedSourceFileHash: otherHash,
        ),
        throwsStateError);
    await expectLater(
        harness.controller.setStemEditsByQueueItemId(
          id,
          StemEdits(
              channelSet: StemChannelSet.stems5Hybrid,
              sourceFileHash: otherHash),
          expectedSourceFileHash: _hash,
        ),
        throwsStateError);
    expect(harness.controller.session, same(before));
    expect(harness.controller.snapshot, same(snapshot));
    expect(harness.engine.model, same(model));
    await harness.controller.setQueue([
      _item().copyWith(extras: {'url': 'https://example.test/1'})
    ]);
    final missingIdentity = harness.controller.session;
    await expectLater(
        harness.controller.setStemEditsByQueueItemId(
          missingIdentity.clips.single.queueItemId,
          _edits(0.25),
          expectedSourceFileHash: _hash,
        ),
        throwsStateError);
    expect(harness.controller.session, same(missingIdentity));
  });

  test('moves trims pitch copies reorder and reanalysis keep source anchors',
      () {
    final documents = [_edits(0.25), _edits(0.75)];
    final queue = [_item(), _item()];
    var session = MixSession.fromMixPlan(plan: _plan(documents), queue: queue);
    session = session.withPlacementAt(
        0,
        session.clips[0].placement
            .withTimelineStartMs(17000)
            .withSourceRange(sourceStartMs: 4000, sourceEndMs: 7000));
    session = session
        .withPitchModeAt(0, 'resample')
        .reorder(0, 1)
        .reflowedByOrder([1, 0]);
    final refreshed = _item().copyWith(title: 'Refreshed', extras: {
      'url': 'https://example.test/refreshed',
      'sourceFileHash': 'sha256:${List.filled(64, 'b').join()}',
      'analysisRef': 'new-analysis',
      'analysisVersion': 'new-grid',
      'analysisStatus': 'completed',
      'analysisSummary': {'bpm': 123},
    });
    session = session.normalizedForQueue([refreshed, refreshed]);
    for (final clip in session.clips) {
      final index = clip.queueItemId == 'item-0' ? 0 : 1;
      expect(clip.stemEdits!.toJson(), documents[index].toJson());
      expect(clip.stemEdits!.events.single.atMs, 2500);
      expect(clip.stemEdits!.sourceFileHash, _hash);
      expect(clip.analysisVersion, 'new-grid');
      expect(clip.shiftedBy(1500).stemEdits, clip.stemEdits);
    }
    final model = CueTimeline.fromSession(
        session: session,
        queue: [refreshed, refreshed],
        playOrder: [0, 1]).toTimelineModel();
    for (final clip in model.clips) {
      expect(
          clip
              .withEnvelope(clip.envelope)
              .withRateAutomation(clip.rateAutomation),
          clip);
      expect(clip.stemEdits!.beatGridRef!.analysisVersion, 'old-grid');
    }
  });

  test(
      'direct and occurrence-matched queue plan projections retain distinct edits',
      () {
    final documents = [_edits(0.25), _edits(0.75)];
    final plan = _plan(documents);
    for (final model in [
      TimelineModel.fromMixPlan(plan),
      TimelineModel.fromQueuePlan(plan, trackOrder: ['1', '1'])
    ]) {
      for (var index = 0; index < documents.length; index++) {
        expect(model.toMixPlanClips()[index].stemEdits!.toJson(),
            documents[index].toJson());
        expect(model.clips[index].queueItemId, 'item-$index');
      }
    }
  });

  test(
      'queue persistence store reads back known-empty document and explicit clear',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = QueuePersistenceStore(prefs: SharedPreferences.getInstance());
    final empty = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid, sourceFileHash: _hash);
    final session =
        MixSession.fromMixPlan(plan: _plan([empty]), queue: [_item()]);
    await store.save(QueueSnapshot(
        tracks: [mediaItemToPlaybackJson(_item())], session: session));
    expect((await store.load()).session!.clips.single.stemEdits!.toJson(),
        empty.toJson());
    await store.save(QueueSnapshot(
        tracks: [mediaItemToPlaybackJson(_item())],
        session: session.withStemEditsAt(0, null)));
    final restored = (await store.load()).session!;
    expect(restored.clips.single.stemEdits, isNull);
    expect(restored.clips.single.toJson().containsKey('stemEdits'), isFalse);
    expect(
        CueTimeline.fromSession(
                session: restored, queue: [_item()], playOrder: [0])
            .toTimelineModel()
            .toMixPlanClips()
            .single
            .toJson()
            .containsKey('stemEdits'),
        isFalse);
  });

  test('owner rejects malformed channel without mutating accepted state',
      () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.controller.setQueue([_item()]);
    final before = harness.controller.session;
    final model = harness.engine.model;
    await expectLater(
        harness.controller.setStemEditsByQueueItemId(
          before.clips.single.queueItemId,
          StemEdits(
              channelSet: StemChannelSet.stems5Hybrid,
              sourceFileHash: _hash,
              events: [StemGainEvent(channel: 'unknown', atMs: 5, gain: 0.5)]),
          expectedSourceFileHash: _hash,
        ),
        throwsA(isA<StemEditsFormatException>()));
    expect(harness.controller.session, same(before));
    expect(harness.engine.model, same(model));
  });

  test('session and cue value equality includes the saved document', () {
    final queue = [_item()];
    final session =
        MixSession.fromMixPlan(plan: _plan([_edits(0.25)]), queue: queue);
    final restored = MixSession.fromJson(session.toJson());
    expect(restored.clips.single, session.clips.single);
    expect(restored.clips.single.hashCode, session.clips.single.hashCode);
    expect(restored.clips.single.withStemEdits(_edits(0.75)),
        isNot(session.clips.single));
    final first =
        CueTimeline.fromSession(session: session, queue: queue, playOrder: [0])
            .cues
            .single;
    final second =
        CueTimeline.fromSession(session: restored, queue: queue, playOrder: [0])
            .cues
            .single;
    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(first.toMixClip(), second.toMixClip());
    expect(first.toMixClip().hashCode, second.toMixClip().hashCode);
  });

  test('malformed saved stem edits reject rather than normalizing values', () {
    final session =
        MixSession.fromMixPlan(plan: _plan([_edits(0.25)]), queue: [_item()]);
    for (final invalid in <Object?>[
      null,
      'not an object',
      {..._edits(0.25).toJson(), 'schemaVersion': 1.5},
      {..._edits(0.25).toJson(), 'sourceFileHash': 123},
      {..._edits(0.25).toJson(), 'events': null},
      {
        ..._edits(0.25).toJson(),
        'events': [
          _edits(0.25).events.single.toJson(),
          _edits(0.25).events.single.toJson(),
        ]
      },
      {
        ..._edits(0.25).toJson(),
        'events': [
          {'channel': 'vocals', 'atMs': -1, 'gain': 1.1, 'rampMs': 0},
        ]
      },
    ]) {
      final json = session.toJson();
      (json['clips'] as List)[0]['stemEdits'] = invalid;
      expect(() => MixSession.fromJson(json),
          throwsA(isA<StemEditsFormatException>()));
    }
  });

  test('owner saves one occurrence as metadata without interrupting transport',
      () async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await harness.controller.setQueue([_item(), _item()]);
    await harness.controller.play();
    await harness.controller.seek(const Duration(milliseconds: 750));
    final ids =
        harness.controller.session.clips.map((c) => c.queueItemId).toList();
    final pauses = harness.voices.map((voice) => voice.pauses).toList();
    final seeks = harness.voices.map((voice) => voice.seeks.length).toList();
    await harness.controller.setStemEditsByQueueItemId(
      ids[1],
      _edits(0.25),
      expectedSourceFileHash: _hash,
    );
    expect(harness.controller.session.clips[0].stemEdits, isNull);
    expect(harness.controller.session.clips[1].stemEdits, _edits(0.25));
    expect(harness.controller.snapshot.cues[1].stemEdits, _edits(0.25));
    expect(harness.engine.model.clips[1].stemEdits, _edits(0.25));
    expect(harness.engine.isPlaying, isTrue);
    expect(harness.engine.positionMs, 750);
    expect(harness.voices.map((voice) => voice.pauses), pauses);
    expect(harness.voices.map((voice) => voice.seeks.length), seeks);
    expect(harness.controller.hasUnsupportedStemEdits, isTrue);
    await harness.controller.setStemEditsByQueueItemId(
      ids[1],
      null,
      expectedSourceFileHash: _hash,
    );
    expect(harness.controller.session.clips[1].stemEdits, isNull);
    expect(harness.controller.hasUnsupportedStemEdits, isFalse);
    expect(harness.engine.model.clips[1].stemEdits, isNull);
  });

  test('saved stem documents survive session queue JSON cue and payload', () {
    final documents = [_edits(0.25), _edits(0.75)];
    final plan = _plan(documents);
    final queue = [_item(), _item()];
    final session = MixSession.fromMixPlan(plan: plan, queue: queue);
    final snapshot = QueueSnapshot.decode(QueueSnapshot(
      tracks: queue.map(mediaItemToPlaybackJson).toList(),
      session: session,
    ).encode());
    final restored = snapshot.session!;
    // Read the persisted shape first: baseline must fail on loss, not on a
    // not-yet-added getter or a test harness compile error.
    expect(restored.clips[0].toJson()['stemEdits'], documents[0].toJson());
    expect(restored.clips[1].toJson()['stemEdits'], documents[1].toJson());
    final cues = CueTimeline.fromSession(
      session: restored,
      queue: queue,
      playOrder: [0, 1],
    );
    expect(cues.cues[0].stemEdits!.toJson(), documents[0].toJson());
    expect(cues.cues[1].stemEdits!.toJson(), documents[1].toJson());
    final payload = cues.toTimelineModel().toMixPlanPayload();
    final clips = payload['clips'] as List;
    for (var index = 0; index < clips.length; index++) {
      expect(clips[index]['stemEdits'], documents[index].toJson());
      expect(clips[index]['queueItemId'], 'item-$index');
    }
  });
}

StemEdits _edits(double gain) => StemEdits(
      channelSet: StemChannelSet.stems5Hybrid,
      sourceFileHash: _hash,
      stemModelVersion: 'saved-model-version-not-current',
      beatGridRef: StemBeatGridRef(
        analysisRef: 'saved-analysis',
        analysisVersion: 'old-grid',
        unknownKeys: const {'gridExtension': 'keep'},
      ),
      events: [
        StemGainEvent(
          channel: 'vocals',
          atMs: 2500,
          gain: gain,
          beatIndex: 5,
          unknownKeys: const {'eventExtension': 'keep'},
        ),
      ],
      unknownKeys: const {'documentExtension': 'keep'},
    );

final _hash = 'sha256:${List.filled(64, 'a').join()}';

class _Harness {
  _Harness() {
    clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    engine = PlaybackEngine.withClock(
        clock: clock,
        voiceFactory: () {
          final voice = _RecordingVoice('v${voices.length}');
          voices.add(voice);
          return voice;
        });
    controller = QueueTimelineController(engine);
  }
  final voices = <_RecordingVoice>[];
  late final DefaultTimelineClock clock;
  late final PlaybackEngine engine;
  late final QueueTimelineController controller;
  Future<void> dispose() async {
    await controller.dispose();
    await clock.dispose();
  }
}

class _RecordingVoice extends FakeVoice {
  _RecordingVoice(super.debugId);
  int pauses = 0;
  @override
  Future<void> pause() async {
    pauses++;
    await super.pause();
  }
}

MediaItem _item() => MediaItem(
      id: '1',
      title: 'Same recording',
      duration: const Duration(seconds: 10),
      extras: {'url': 'https://example.test/1', 'sourceFileHash': _hash},
    );

MixPlan _plan(List<StemEdits?> documents) => MixPlan(
      id: 'saved',
      schemaVersion: 1,
      name: 'saved performance',
      clips: [
        for (var index = 0; index < documents.length; index++)
          MixPlanClip(
            clipId: 'clip-$index',
            queueItemId: 'item-$index',
            trackId: '1',
            sourceStartMs: 1000,
            sourceEndMs: 8000,
            timelineStartMs: index * 7000,
            stemEdits: documents[index],
          ),
      ],
      summary: MixPlanSummary(
        clipCount: documents.length,
        trackIds: const ['1'],
        durationMs: documents.length * 7000,
      ),
      version: 1,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
