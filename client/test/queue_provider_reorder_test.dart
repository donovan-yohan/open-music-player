import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/providers/queue_provider.dart';

import 'support/mock_dio_client.dart';

Map<String, Object?> _track(String queueItemId, String trackId) => {
      'queueItemId': queueItemId,
      'trackId': trackId,
      'title': 'Track $trackId',
      'artist': 'Artist $trackId',
      'duration': 180,
      'addedAt': '2026-01-01T00:00:00Z',
    };

String _queueJson(
  List<Map<String, Object?>> items, {
  int currentPosition = 0,
}) =>
    jsonEncode({
      'items': items,
      'currentPosition': currentPosition,
      'updatedAt': '2026-01-01T00:00:00Z',
    });

void main() {
  test('reorderQueue ignores out-of-range newIndex without API call', () async {
    final items = [_track('queue-a', '1'), _track('queue-b', '2')];
    var reorderCalls = 0;
    final provider = QueueProvider(
      mockQueueApiClient(
        (request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(_queueJson(items), 200);
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/queue/reorder')) {
            reorderCalls++;
            return http.Response(_queueJson(items), 200);
          }
          return http.Response('{}', 404);
        },
      ),
    );

    await provider.loadQueue();
    final originalOrder =
        provider.queue.tracks.map((track) => track.queueItemId).toList();

    await provider.reorderQueue(0, -1);
    await provider.reorderQueue(0, 99);

    expect(reorderCalls, 0);
    expect(
      provider.queue.tracks.map((track) => track.queueItemId).toList(),
      originalOrder,
    );
    expect(provider.error, isNull);
  });

  test(
    'reorderQueue sends queue item id and target position for valid moves',
    () async {
      final initialItems = [_track('queue-a', '1'), _track('queue-b', '2')];
      final reorderedItems = [_track('queue-b', '2'), _track('queue-a', '1')];
      String? reorderBody;
      final provider = QueueProvider(
        mockQueueApiClient(
          (request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              return http.Response(_queueJson(initialItems), 200);
            }
            if (request.method == 'PUT' &&
                request.url.path.endsWith('/queue/reorder')) {
              reorderBody = request.body;
              return http.Response(
                _queueJson(reorderedItems, currentPosition: 1),
                200,
              );
            }
            return http.Response('{}', 404);
          },
        ),
      );

      await provider.loadQueue();
      await provider.reorderQueue(0, 1);

      expect(jsonDecode(reorderBody!), {
        'queueItemId': 'queue-a',
        'toPosition': 1,
      });
      expect(provider.queue.tracks.map((track) => track.queueItemId).toList(), [
        'queue-b',
        'queue-a',
      ]);
    },
  );
}
