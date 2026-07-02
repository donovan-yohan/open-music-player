import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('does not restart queue polling after SearchScreen is disposed', (
    tester,
  ) async {
    final queueClient = _FakeQueueApiClient();
    final apiClient = ApiClient(storage: SecureStorage(), dio: Dio());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: apiClient),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(queueClient),
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

/// Counts queue polls via the unified [ApiClient] surface (method override), so
/// the SearchScreen polling lifecycle is exercised without a live transport.
class _FakeQueueApiClient extends ApiClient {
  final Completer<QueueState> _firstQueuePoll = Completer<QueueState>();
  int queuePollRequests = 0;

  @override
  Future<QueueState> getQueue() async {
    queuePollRequests++;
    if (queuePollRequests == 1) {
      return _firstQueuePoll.future;
    }
    return _activeQueueState(progress: 2);
  }

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  void completeFirstQueuePoll() {
    if (!_firstQueuePoll.isCompleted) {
      _firstQueuePoll.complete(_activeQueueState(progress: 2));
    }
  }
}

QueueState _activeQueueState({required int progress}) =>
    QueueState.fromJson(_activeQueueJson(progress: progress));

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
