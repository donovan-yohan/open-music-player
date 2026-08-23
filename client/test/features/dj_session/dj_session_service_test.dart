import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:open_music_player/features/dj_session/dj_session_models.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';

import '../../support/mock_dio_client.dart' as support;

void main() {
  group('DjLineup detail field', () {
    test('parses an optional per-block detail line', () {
      final lineup = DjLineup.fromJson({
        'requested': <String, Object?>{},
        'blocks': [
          {
            'id': 'on-repeat',
            'title': 'On Repeat',
            'reason': 'The ones you keep coming back to.',
            'detail': '23 plays in the last 90 days',
            'tracks': <Object?>[],
          },
          {
            'id': 'flashback',
            'title': 'Flashback',
            'reason': "Haven't heard this in a minute.",
            'tracks': <Object?>[],
          },
        ],
      });

      expect(lineup.blocks[0].detail, '23 plays in the last 90 days');
      expect(lineup.blocks[1].detail, isEmpty);
    });

    test('treats a null detail as absent', () {
      final lineup = DjLineup.fromJson({
        'requested': <String, Object?>{},
        'blocks': [
          {
            'id': 'on-repeat',
            'title': 'On Repeat',
            'reason': 'reason',
            'detail': null,
            'tracks': <Object?>[],
          },
        ],
      });

      expect(lineup.blocks.single.detail, isEmpty);
    });
  });

  group('DjPin parsing', () {
    test('parses a full pin payload', () {
      final pin = DjPin.fromJson({
        'blockId': 'on-repeat',
        'energyLow': 0.2,
        'energyHigh': 0.6,
        'genres': ['house', 'ambient'],
        'expiresAt': '2026-08-30T12:00:00Z',
      });

      expect(pin.blockId, 'on-repeat');
      expect(pin.energyLow, 0.2);
      expect(pin.energyHigh, 0.6);
      expect(pin.genres, ['house', 'ambient']);
      expect(pin.expiresAt, DateTime.utc(2026, 8, 30, 12));
    });

    test('tolerates missing optional fields', () {
      final pin = DjPin.fromJson({'blockId': 'fresh-finds'});

      expect(pin.blockId, 'fresh-finds');
      expect(pin.genres, isEmpty);
      expect(pin.expiresAt, isNull);
    });
  });

  group('DjSessionService pin calls', () {
    test('POST /dj/pin sends blockId and parses the returned pin', () async {
      http.Request? captured;
      final apiClient = support.mockQueueApiClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'blockId': 'on-repeat',
            'energyLow': 0.2,
            'energyHigh': 0.6,
            'genres': ['house'],
            'expiresAt': '2026-08-30T12:00:00Z',
          }),
          200,
        );
      });
      final service = DjSessionService(apiClient);

      final pin = await service.pinBlock('on-repeat');

      expect(captured!.method, 'POST');
      expect(captured!.url.path.endsWith('/dj/pin'), isTrue);
      expect(jsonDecode(captured!.body), {'blockId': 'on-repeat'});
      expect(pin.blockId, 'on-repeat');
    });

    test('DELETE /dj/pin succeeds and swallows 404 as already-gone',
        () async {
      var deleteCount = 0;
      var status = 200;
      final apiClient = support.mockQueueApiClient((request) async {
        if (request.method == 'DELETE') {
          deleteCount++;
          if (status == 500) return http.Response('{}', 500);
          if (status == 404) return http.Response('{}', 404);
          return http.Response('{}', 204);
        }
        return http.Response('{}', 405);
      });
      final service = DjSessionService(apiClient);

      await service.unpinBlock();
      expect(deleteCount, 1);

      status = 404;
      await service.unpinBlock();
      expect(deleteCount, 2);

      status = 500;
      try {
        await service.unpinBlock();
        fail('expected a 5xx unpin to rethrow');
      } on DioException {
        // Expected: transport/5xx failures propagate.
      }
    });

    test('GET /dj/pin returns the pin, or null on 404', () async {
      var status = 200;
      http.Request? captured;
      final apiClient = support.mockQueueApiClient((request) async {
        captured = request;
        if (status == 404) return http.Response('{}', 404);
        return http.Response(
          jsonEncode({
            'blockId': 'flashback',
            'energyLow': 0.1,
            'energyHigh': 0.4,
            'genres': [],
          }),
          200,
        );
      });
      final service = DjSessionService(apiClient);

      final active = await service.fetchPin();
      expect(captured!.method, 'GET');
      expect(captured!.url.path.endsWith('/dj/pin'), isTrue);
      expect(active?.blockId, 'flashback');

      status = 404;
      expect(await service.fetchPin(), isNull);
    });
  });
}
