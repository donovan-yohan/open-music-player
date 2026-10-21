import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/services/mix_exchange_service.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:open_music_player/models/mix_plan.dart';

import 'support/mock_dio_client.dart';
import 'desktop_mix_editor_draft_test.dart' show planJson, clipJson;

Map<String, dynamic> portableMix() => {
      'format': 'soundq-mix',
      'version': 1,
      'name': 'Evening set',
      'clips': [
        {
          'clipId': 'clip-a',
          'queueItemId': 'queue-a',
          'sourceFileHash': 'sha256:${'a' * 64}',
          'sourceStartMs': 0,
          'sourceEndMs': 8000,
          'timelineStartMs': 0,
          'gainDb': -3,
          'pitchMode': 'preserve',
          'tempoPolicy': 'volumeOnly',
        }
      ]
    };

void main() {
  test('exports the authenticated saved performance without server identifiers',
      () async {
    final api = mockQueueApiClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/mix-plans/plan-a/export');
      return http.Response(jsonEncode(portableMix()), 200);
    });

    final text = await MixExchangeService(api).exportMix('plan-a');
    expect(jsonDecode(text), portableMix());
    expect(text, isNot(contains('trackId')));
  });

  test('import keeps raw JSON and verifies the created plan through GET',
      () async {
    final raw = ' ${jsonEncode(portableMix())}\n';
    final saved = planJson(clips: [
      {...clipJson(id: 'clip-a'), 'trackId': 7}
    ]);
    final calls = <String>[];
    final api = mockQueueApiClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.method == 'POST') {
        expect(request.body, raw);
      }
      return http.Response(
          jsonEncode(saved), request.method == 'POST' ? 201 : 200);
    });
    final imported = await MixExchangeService(api).importMix(raw);
    expect(imported.id, saved['id']);
    expect(calls,
        ['POST /api/v1/mix-plans/import', 'GET /api/v1/mix-plans/plan-1']);
  });

  test('oversized UTF-8 metadata is rejected before a request', () async {
    var calls = 0;
    final api = mockQueueApiClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    await expectLater(
        MixExchangeService(api).importMix('é' * 140000), throwsFormatException);
    expect(calls, 0);
  });

  test('a missing-source refusal retains the server error code', () async {
    var calls = 0;
    final api = mockQueueApiClient((_) async {
      calls++;
      return http.Response(
          '{"code":"MISSING_SOURCES","message":"Required audio is missing."}',
          422);
    });
    await expectLater(
        MixExchangeService(api).importMix(jsonEncode(portableMix())),
        throwsA(isA<ApiException>()
            .having((e) => e.errorCode, 'code', 'MISSING_SOURCES')));
    expect(calls, 1);
  });

  test('changed persisted automation cannot certify an import', () async {
    final api = mockQueueApiClient((request) async => http.Response(
        jsonEncode(planJson(clips: [
          {...clipJson(), 'gainDb': request.method == 'POST' ? 0 : -6}
        ])),
        request.method == 'POST' ? 201 : 200));
    await expectLater(
        MixExchangeService(api).importMix(jsonEncode(portableMix())),
        throwsFormatException);
  });

  for (final mutation in ['gain', 'ramp', 'unknown', 'fractional timing']) {
    test('readback rejects raw $mutation changes before DTO normalization',
        () async {
      final edits = StemEdits(
          channelSet: StemChannelSet.stems5Hybrid,
          sourceFileHash: 'sha256:${'a' * 64}',
          events: [
            StemGainEvent(channel: 'vocals', atMs: 2000, gain: 1, rampMs: 250)
          ]);
      final original = planJson(clips: [
        {...clipJson(), 'stemEdits': edits.toJson()}
      ]);
      var calls = 0;
      final api = mockQueueApiClient((request) async {
        calls++;
        final body = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        if (request.method == 'GET') {
          final clip = body['clips'][0];
          final event = clip['stemEdits']['events'][0];
          switch (mutation) {
            case 'gain':
              event['gain'] = 2;
            case 'ramp':
              event['rampMs'] = 251;
            case 'unknown':
              clip['futureAutomation'] = {'gain': 0};
            case 'fractional timing':
              clip['sourceStartMs'] = 1000.1;
          }
        }
        return http.Response(
            jsonEncode(body), request.method == 'POST' ? 201 : 200);
      });
      await expectLater(
          MixExchangeService(api).importMix(jsonEncode(portableMix())),
          throwsFormatException);
      expect(calls, 2);
    });
  }

  test('readback object key order does not change authoring data', () async {
    final original = planJson();
    final api = mockQueueApiClient((request) async => http.Response(
        jsonEncode(request.method == 'POST'
            ? original
            : Map.fromEntries(original.entries.toList().reversed)),
        request.method == 'POST' ? 201 : 200));
    final result =
        await MixExchangeService(api).importMix(jsonEncode(portableMix()));
    expect(result.id, 'plan-1');
  });

  test('ordinary saved-plan reads reject clamped authoring values', () async {
    final edits = StemEdits(
            channelSet: StemChannelSet.stems5Hybrid,
            sourceFileHash: 'sha256:${'a' * 64}',
            events: [StemGainEvent(channel: 'vocals', atMs: 2000, gain: 1)])
        .toJson();
    (edits['events'] as List)[0]['gain'] = 2;
    final api = mockQueueApiClient((_) async => http.Response(
        jsonEncode(planJson(clips: [
          {...clipJson(), 'stemEdits': edits}
        ])),
        200));
    await expectLater(api.getMixPlan('plan-1'), throwsFormatException);
  });

  test('saved authoring response accepts its checked derived end', () async {
    final body = planJson(clips: [
      {...clipJson(), 'timelineEndMs': 10000, 'pitchMode': 'preserve'}
    ]);
    final api =
        mockQueueApiClient((_) async => http.Response(jsonEncode(body), 200));
    expect((await api.getMixPlan('plan-1')).clips.single.timelineEndMs, 10000);
  });

  test('ordinary saved-plan writes reject normalized response mutations',
      () async {
    final original = planJson();
    final api = mockQueueApiClient((_) async => http.Response(
        jsonEncode({
          ...original,
          'clips': [
            {...clipJson(), 'sourceStartMs': 1000.1}
          ]
        }),
        200));
    await expectLater(
        api.updateMixPlan(
            id: 'plan-1',
            version: 2,
            name: 'Night drive',
            clips: [MixPlanClip.fromJson(clipJson())]),
        throwsFormatException);
  });
}
