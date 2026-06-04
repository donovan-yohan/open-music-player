import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/services/api_client.dart' as queue_api;
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('does not restart queue polling after SearchScreen is disposed', (
    tester,
  ) async {
    final queueClient = _QueuePollingClient();
    final apiClient = ApiClient(storage: SecureStorage(), dio: Dio());
    final queueApiClient = queue_api.ApiClient(httpClient: queueClient.client);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: apiClient),
          Provider<queue_api.ApiClient>.value(value: queueApiClient),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(queueApiClient),
          ),
        ],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
    expect(queueClient.queuePollRequests, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    queueClient.completeFirstQueuePoll();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(queueClient.queuePollRequests, 1);
  });
}

class _QueuePollingClient {
  final Completer<http.Response> _firstQueuePoll = Completer<http.Response>();
  late final MockClient client = MockClient(_handle);
  int queuePollRequests = 0;

  Future<http.Response> _handle(http.Request request) async {
    if (request.method == 'GET' && request.url.path == '/api/v1/queue') {
      queuePollRequests++;
      if (queuePollRequests == 1) {
        return _firstQueuePoll.future;
      }
      return _jsonResponse(_activeQueueJson(progress: 2));
    }

    return _jsonResponse({
      'message': 'unexpected ${request.method} ${request.url.path}',
    }, statusCode: 404);
  }

  void completeFirstQueuePoll() {
    if (!_firstQueuePoll.isCompleted) {
      _firstQueuePoll.complete(_jsonResponse(_activeQueueJson(progress: 2)));
    }
  }
}

http.Response _jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(data),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}

Map<String, dynamic> _activeQueueJson({required int progress}) {
  return {
    'items': [
      {
        'queueItemId': 'q_1',
        'position': 0,
        'kind': 'source',
        'playbackState': 'downloading',
        'sourceCandidate': _candidateJson(),
        'downloadJobId': 'job_1',
        'trackId': null,
        'progress': progress,
        'error': null,
        'canPlay': false,
        'canRetry': false,
        'canRemove': true,
      },
    ],
    'currentPosition': 0,
  };
}

Map<String, dynamic> _candidateJson() {
  return {
    'candidateId': 'youtube:abc',
    'provider': 'youtube',
    'sourceId': 'abc',
    'sourceUrl': 'https://youtube.com/watch?v=abc',
    'title': 'Plastic Love',
    'uploader': 'mariya channel',
    'durationMs': 253000,
    'downloadable': true,
    'playable': false,
  };
}
