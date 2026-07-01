import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
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

  testWidgets(
    'Search Queue action writes through QueueProvider and links to Queue',
    (tester) async {
      final searchApiClient = ApiClient(
        storage: SecureStorage(),
        dio: Dio()..httpClientAdapter = _SearchResultAdapter(),
      );
      final queueClient = _QueueMutationClient();
      final queueProvider = QueueProvider(queueClient);
      final router = GoRouter(
        initialLocation: '/search',
        routes: [
          GoRoute(path: '/search', builder: (_, __) => const SearchScreen()),
          GoRoute(
            path: '/queue',
            builder: (_, __) => const Scaffold(body: Text('queue landing')),
          ),
        ],
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<ApiClient>.value(value: searchApiClient),
            ChangeNotifierProvider<QueueProvider>.value(value: queueProvider),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'plastic love');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.playlist_add));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(queueClient.postedSourceCandidates, 1);
      expect(
        queueProvider.queue.tracks.single.sourceCandidateId,
        'youtube:abc',
      );
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('View Queue'), findsWidgets);
      expect(
        find.byKey(const ValueKey('search_queue_affordance')),
        findsOneWidget,
      );

      await tester
          .tap(find.byKey(const ValueKey('search_view_queue_youtube:abc')));
      await tester.pumpAndSettle();

      expect(find.text('queue landing'), findsOneWidget);
    },
  );
}

/// Drives [QueueProvider] through the unified [ApiClient] surface (method
/// override) so the Search → Queue write-through is exercised without a live
/// transport. The POST body contract itself is covered by
/// queue_api_client_contract_test.dart.
class _QueueMutationClient extends ApiClient {
  int postedSourceCandidates = 0;

  @override
  Future<QueueState> getQueue() async => QueueState.fromJson(
        postedSourceCandidates == 0 ? _emptyQueue() : _queuedSourceQueue(),
      );

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<QueueState> addSourceCandidateToQueue({
    required DiscoveryCandidate candidate,
    String position = 'last',
  }) async {
    postedSourceCandidates++;
    return QueueState.fromJson(_queuedSourceQueue());
  }
}

class _SearchResultAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/discovery/search') {
      return ResponseBody.fromString(
        jsonEncode({
          'query': options.queryParameters['q'] ?? 'plastic love',
          'results': [_candidateJson()],
          'providers': [
            {
              'provider': 'youtube',
              'status': 'ok',
              'resultCount': 1,
              'elapsedMs': 12,
            },
          ],
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }

    return ResponseBody.fromString(
      jsonEncode({'message': 'unexpected ${options.method} ${options.path}'}),
      404,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _emptyQueue() => {'items': [], 'currentPosition': 0};

Map<String, dynamic> _queuedSourceQueue() {
  return {
    'items': [
      {
        'queueItemId': 'q_source',
        'position': 0,
        'kind': 'source',
        'playbackState': 'queued',
        'sourceCandidate': _candidateJson(),
        'downloadJobId': 'job_1',
        'trackId': null,
        'progress': 0,
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
    'sourceUrl': 'https://youtube.test/watch?v=abc',
    'title': 'Plastic Love',
    'uploader': 'mariya channel',
    'durationMs': 253000,
    'downloadable': true,
    'playable': false,
  };
}
