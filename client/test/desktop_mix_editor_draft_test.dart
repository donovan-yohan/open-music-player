import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/features/playlists/mix/desktop_mix_editor_draft.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/stem_edits.dart';

import 'support/mock_dio_client.dart';

Map<String, dynamic> planJson(
        {int version = 3, List<Map<String, dynamic>>? clips}) =>
    {
      'id': 'plan-1',
      'schemaVersion': 1,
      'name': 'Night drive',
      'version': version,
      'createdAt': '2026-06-04T00:00:00Z',
      'updatedAt': '2026-06-04T00:05:00Z',
      'summary': {
        'clipCount': 1,
        'trackIds': [42],
        'durationMs': 10000
      },
      'clips': clips ?? [clipJson()],
    };
Map<String, dynamic> clipJson({String id = 'a', int start = 0}) => {
      'clipId': id,
      'queueItemId': 'q-$id',
      'trackId': 42,
      'sourceStartMs': 1000,
      'sourceEndMs': 11000,
      'timelineStartMs': start,
      'gainDb': 0.0,
    };

void main() {
  test('open refuses a response for another saved document', () async {
    final draft = DesktopMixEditorDraft(mockQueueApiClient((_) async =>
        http.Response(jsonEncode({...planJson(), 'id': 'other-plan'}), 200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(draft.base, isNull);
    expect(draft.clips, isEmpty);
    expect(draft.error, isNotNull);
  });

  test('save cannot certify a response that lost submitted stem movements',
      () async {
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: 'sha256:${List.filled(64, 'a').join()}');
    final initial = planJson(clips: [
      {...clipJson(), 'stemEdits': edits.toJson()}
    ]);
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        // An older server acknowledges the revision but erases automation.
        return http.Response(jsonEncode(planJson(version: 4)), 200);
      }
      return http.Response(jsonEncode(initial), 200);
    }));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(draft.setStemPoint('a', 'vocals', 2000, .37), isTrue);
    await draft.save();
    expect(draft.base!.version, 3);
    expect(draft.clips.single.stemEdits!.events.single.gain, .37);
    expect(draft.dirty, isTrue);
    expect(draft.conflict, isTrue);
    expect(draft.error, isNotNull);
  });

  test('reload failure retains same-document dirty draft', () async {
    var reads = 0;
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async =>
        ++reads == 1
            ? http.Response(jsonEncode(planJson()), 200)
            : http.Response('{}', 503)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.replaceClip(draft.clips.single.withTimelineStartMs(500));
    await draft.open('plan-1');
    expect(draft.clips.single.timelineStartMs, 500);
    expect(draft.dirty, isTrue);
  });

  test('failed open of different document cannot expose or save old document',
      () async {
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.url.path.endsWith('missing')) return http.Response('{}', 404);
      return http.Response(jsonEncode(planJson()), 200);
    }));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.replaceClip(draft.clips.single.withTimelineStartMs(500));
    await draft.open('missing');
    expect(draft.base, isNull);
    expect(draft.clips, isEmpty);
    expect(draft.error, isNotNull);
  });

  test('failed save verification keeps edits dirty and undo available',
      () async {
    var reads = 0;
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        final payload = jsonDecode(request.body);
        return http.Response(
            jsonEncode({...planJson(version: 4), 'clips': payload['clips']}),
            200);
      }
      if (++reads > 1) return http.Response('{"message":"offline"}', 503);
      return http.Response(jsonEncode(planJson()), 200);
    }));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.replaceClip(draft.clips.single.withTimelineStartMs(999));
    await draft.save();
    expect(draft.clips.single.timelineStartMs, 999);
    expect(draft.dirty, isTrue);
    expect(draft.canUndo, isTrue);
    expect(draft.error, isNotNull);
  });

  test('source points survive trim and illegal fade geometry is rejected',
      () async {
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: 'sha256:${List.filled(64, 'a').join()}',
        events: [StemGainEvent(channel: 'vocals', atMs: 2000, gain: .4)]);
    final draft =
        DesktopMixEditorDraft(mockQueueApiClient((_) async => http.Response(
            jsonEncode(planJson(clips: [
              {...clipJson(), 'stemEdits': edits.toJson()}
            ])),
            200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(draft.replaceClip(draft.clips.single.copyWith(sourceStartMs: 3000)),
        isTrue);
    expect(draft.clips.single.stemEdits!.events.single.atMs, 2000);
    expect(
        draft.replaceClip(
            draft.clips.single.copyWith(fadeInMs: 5000, fadeOutMs: 5000)),
        isFalse);
    expect(draft.clips.single.fadeInMs, isNull);
    expect(draft.error, contains('Fades'));
  });

  test('invalid gesture never changes accepted clips or undo stack', () async {
    final clips = [
      for (var i = 0; i < 5; i++) clipJson(id: '$i', start: i < 4 ? 0 : 10000)
    ];
    final draft = DesktopMixEditorDraft(mockQueueApiClient(
        (_) async => http.Response(jsonEncode(planJson(clips: clips)), 200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.beginGesture();
    draft.previewClip(draft.clips.last.withTimelineStartMs(0));
    expect(draft.clips.last.timelineStartMs, 10000);
    expect(draft.endGesture(), isFalse);
    expect(draft.clips.last.timelineStartMs, 10000);
    expect(draft.canUndo, isFalse);
  });

  test('dispose fences pending save and document reads', () async {
    final pending = Completer<http.Response>();
    final draft =
        DesktopMixEditorDraft(mockQueueApiClient((_) => pending.future));
    final open = draft.open('plan-1');
    draft.dispose();
    pending.complete(http.Response(jsonEncode(planJson()), 200));
    await open;
    expect(draft.base, isNull);
  });

  test('rejects fifth overlapping clip and keeps last accepted draft',
      () async {
    final clips = [
      for (var i = 0; i < 5; i++) clipJson(id: '$i', start: i < 4 ? 0 : 10000)
    ];
    final draft = DesktopMixEditorDraft(mockQueueApiClient(
        (_) async => http.Response(jsonEncode(planJson(clips: clips)), 200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(
        draft.replaceClip(draft.clips.last.withTimelineStartMs(9999)), isFalse);
    expect(draft.clips.last.timelineStartMs, 10000);
    expect(draft.error, contains('four clips'));
    expect(draft.dirty, isFalse);
    expect(
        draft.replaceClip(draft.clips.last.withTimelineStartMs(10001)), isTrue);
  });

  test('1000 sequential clips are valid and a gesture is one undo command',
      () async {
    final clips = [
      for (var i = 0; i < 1000; i++) clipJson(id: '$i', start: i * 10000)
    ];
    final draft = DesktopMixEditorDraft(mockQueueApiClient(
        (_) async => http.Response(jsonEncode(planJson(clips: clips)), 200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(draft.error, isNull);
    final before = draft.clips.last;
    draft.beginGesture();
    draft.previewClip(before.withTimelineStartMs(10000001));
    draft.previewClip(before.withTimelineStartMs(10000002));
    expect(draft.clips.last.timelineStartMs, 9990000);
    expect(draft.displayClips.last.timelineStartMs, 10000002);
    expect(draft.endGesture(), isTrue);
    draft.undo();
    expect(draft.clips.last.timelineStartMs, 9990000);
    expect(draft.canUndo, isFalse);
  });

  test('409 preserves dirty draft and does not retry overwrite', () async {
    var writes = 0;
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        writes++;
        return http.Response(
            '{"code":"VERSION_CONFLICT","message":"stale"}', 409);
      }
      return http.Response(jsonEncode(planJson()), 200);
    }));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.replaceClip(draft.clips.single.withTimelineStartMs(500));
    await draft.save();
    expect(draft.conflict, isTrue);
    expect(draft.dirty, isTrue);
    expect(draft.clips.single.timelineStartMs, 500);
    expect(draft.base!.version, 3);
    await draft.save();
    expect(writes, 1);
    draft.undo();
    expect(draft.clips.single.timelineStartMs, 0);
    expect(draft.error, contains('changed elsewhere'));
  });

  test('verified save retains the accepted performance revision identity',
      () async {
    var server = planJson();
    final verificationStarted = Completer<void>();
    final verificationGate = Completer<void>();
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        server = {
          ...server,
          'version': 4,
          'clips': jsonDecode(request.body)['clips']
        };
      } else if (server['version'] == 4) {
        verificationStarted.complete();
        await verificationGate.future;
      }
      return http.Response(jsonEncode(server), 200);
    }));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.replaceClip(draft.clips.single.withTimelineStartMs(500));
    final saving = draft.save();
    await verificationStarted.future;
    final expected = draft.clips;
    draft.beginPerformanceGesture();
    final candidate =
        draft.stagePerformance(draft.clips.single.withTimelineStartMs(700));
    verificationGate.complete();
    await saving;
    expect(draft.clips, same(expected));
    expect(draft.dirty, isFalse);
    draft.acceptPerformance(expected, candidate);
    draft.endPerformanceGesture();
    expect(draft.clips.single.timelineStartMs, 700);
    expect(draft.dirty, isTrue);
    draft.undo();
    expect(draft.clips.single.timelineStartMs, 500);
    expect(draft.dirty, isFalse);
  });

  test(
      'value-identical replacement does not rebase a stale performance revision',
      () async {
    final draft = DesktopMixEditorDraft(mockQueueApiClient(
        (_) async => http.Response(jsonEncode(planJson()), 200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    final expected = draft.clips;
    final candidate =
        draft.stagePerformance(draft.clips.single.withTimelineStartMs(700));
    draft.replaceClip(draft.clips.single.withTimelineStartMs(500));
    draft.replaceClip(draft.clips.single.withTimelineStartMs(0));
    expect(draft.dirty, isFalse);
    expect(
        () => draft.acceptPerformance(expected, candidate), throwsStateError);
    expect(draft.clips.single.timelineStartMs, 0);
  });

  test('save freezes submitted payload and leaves later edits dirty', () async {
    final putStarted = Completer<void>();
    final release = Completer<void>();
    var server = planJson();
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        final payload = jsonDecode(request.body);
        putStarted.complete();
        await release.future;
        expect(payload['clips'][0]['timelineStartMs'], 500);
        server = {...server, 'version': 4, 'clips': payload['clips']};
      }
      return http.Response(jsonEncode(server), 200);
    }));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    draft.replaceClip(draft.clips.single.withTimelineStartMs(500));
    final saving = draft.save();
    await putStarted.future;
    draft.replaceClip(draft.clips.single.withTimelineStartMs(700));
    release.complete();
    await saving;
    expect(draft.base!.version, 4);
    expect(draft.base!.clips.single.timelineStartMs, 500);
    expect(draft.clips.single.timelineStartMs, 700);
    expect(draft.dirty, isTrue);
  });

  test(
      'authors only existing identified stems at source cursor with default one',
      () async {
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: 'sha256:${List.filled(64, 'a').join()}');
    final draft =
        DesktopMixEditorDraft(mockQueueApiClient((_) async => http.Response(
            jsonEncode(planJson(clips: [
              {...clipJson(), 'stemEdits': edits.toJson()}
            ])),
            200)));
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(draft.clips.single.stemEdits!.gainAt('vocals', 2000), 1);
    for (final gain in [0.0, 0.37, 1.0]) {
      expect(draft.setStemPoint('a', 'vocals', 2000, gain), isTrue);
      expect(draft.clips.single.stemEdits!.gainAt('vocals', 2000), gain);
    }
    expect(draft.clips.single.stemEdits!.events.length, 1);
    draft.replaceClip(draft.clips.single.withTimelineStartMs(3000));
    expect(draft.clips.single.stemEdits!.events.single.atMs, 2000);
    expect(draft.clips.single.stemEdits!.sourceFileHash, edits.sourceFileHash);
    expect(draft.setStemPoint('a', 'vocals', 2000, 1.01), isFalse);
    expect(draft.setStemPoint('a', 'vocals', 11000, .5), isFalse);
  });

  test('late open from a previous document is fenced', () async {
    final first = Completer<http.Response>();
    final draft = DesktopMixEditorDraft(mockQueueApiClient((request) async {
      if (request.url.path.endsWith('old')) return first.future;
      return http.Response(jsonEncode({...planJson(), 'id': 'new'}), 200);
    }));
    addTearDown(draft.dispose);
    final pending = draft.open('old');
    await draft.open('new');
    first
        .complete(http.Response(jsonEncode({...planJson(), 'id': 'old'}), 200));
    await pending;
    expect(draft.base!.id, 'new');
  });

  test('loads a saved version, moves a clip, undo/redo, saves and reads back',
      () async {
    var server = planJson();
    final requests = <http.Request>[];
    final api = mockQueueApiClient((request) async {
      requests.add(request);
      if (request.method == 'PUT') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload.keys.toSet(),
            {'schemaVersion', 'name', 'version', 'clips'});
        expect(payload['version'], 3);
        expect(payload['clips'][0]['trackId'], 42);
        expect(payload['clips'][0].containsKey('timelineEndMs'), isFalse);
        server = {...server, 'version': 4, 'clips': payload['clips']};
      }
      return http.Response(jsonEncode(server), 200);
    });
    final draft = DesktopMixEditorDraft(api);
    addTearDown(draft.dispose);
    await draft.open('plan-1');
    expect(draft.base!.version, 3);
    expect(draft.dirty, isFalse);
    expect(draft.replaceClip(draft.clips.single.withTimelineStartMs(2500)),
        isTrue);
    expect(draft.dirty, isTrue);
    draft.undo();
    expect(draft.clips.single.timelineStartMs, 0);
    draft.redo();
    expect(draft.clips.single.timelineStartMs, 2500);
    await draft.save();
    expect(draft.base!.version, 4);
    expect(draft.clips.single.timelineStartMs, 2500);
    expect(draft.dirty, isFalse);
    expect(requests.map((r) => r.method), ['GET', 'PUT', 'GET']);
    final reopened = MixPlan.fromJson(server);
    expect(reopened.clips.single.timelineStartMs, 2500);
  });
}
