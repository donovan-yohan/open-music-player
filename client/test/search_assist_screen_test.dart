import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<_QueueClient> pumpSearch(
    WidgetTester tester, {
    required Map<String, dynamic> assistEnvelope,
    int assistStatus = 200,
    Future<void>? assistGate,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final discoveryClient = ApiClient(
      storage: SecureStorage(),
      dio: Dio()
        ..httpClientAdapter = _DiscoveryAdapter(
          assistEnvelope,
          assistStatus: assistStatus,
          assistGate: assistGate,
        ),
    );
    final queueClient = _QueueClient();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: discoveryClient),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(queueClient),
          ),
        ],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
    return queueClient;
  }

  Future<void> enterAssistMode(WidgetTester tester, String prompt) async {
    await tester.tap(find.text('Assist'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('search_assist_input')), prompt);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets(
    'assist mode renders assistant text + grounded candidate with an explicit, non-auto queue action',
    (tester) async {
      final queueClient = await pumpSearch(
        tester,
        assistEnvelope: _searchEnvelope,
      );

      await enterAssistMode(tester, 'that live porter robinson shelter');

      // Grounded assistant text + candidate card are rendered.
      expect(
          find.text("Here's what I found from your sources."), findsOneWidget);
      expect(find.text('Porter Robinson - Shelter (Live)'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.byIcon(Icons.playlist_add), findsOneWidget);

      // Nothing was queued by rendering candidates: the action is explicit.
      expect(queueClient.addItemRequests, 0);

      await tester.tap(find.byIcon(Icons.playlist_add));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(queueClient.addItemRequests, 1);
      // The explicit tap queues exactly the grounded candidate — not a
      // fabricated or mismatched one.
      final sent =
          queueClient.lastAddBody?['sourceCandidate'] as Map<String, dynamic>?;
      expect(sent?['candidateId'], 'youtube:abc');
      expect(sent?['sourceUrl'], 'https://youtube.com/watch?v=abc');
      expect(sent?['metadata'], containsPair('sourceQuality', isA<Map>()));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source quality chip opens auditable ranking details',
    (tester) async {
      await pumpSearch(
        tester,
        assistEnvelope: _searchEnvelope,
      );

      await enterAssistMode(tester, 'that live porter robinson shelter');

      await tester.tap(
        find.byKey(const ValueKey('source_quality_chip_live_acceptable')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Source quality'), findsOneWidget);
      expect(find.text('Acceptable'), findsOneWidget);
      expect(find.text('73/100'), findsOneWidget);
      expect(find.text('79%'), findsOneWidget);
      expect(find.text('Reasons'), findsOneWidget);
      expect(find.text('query asked for live content'), findsOneWidget);
      expect(find.text('Provenance'), findsOneWidget);
      expect(find.text('deterministic_source_quality_v1'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pasting a URL in search mode auto-routes to assist and shows a queueable candidate',
    (tester) async {
      final queueClient = await pumpSearch(
        tester,
        assistEnvelope: _directUrlEnvelope,
      );

      // Stay in Search mode; paste a URL and submit.
      await tester.enterText(
        find.byKey(const ValueKey('search_assist_input')),
        'https://youtu.be/abc',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Routed to assist: the direct-link candidate is shown, not auto-queued.
      expect(find.text('Pasted Track'), findsOneWidget);
      expect(find.text('Direct link'), findsOneWidget);
      expect(find.byIcon(Icons.playlist_add), findsOneWidget);
      expect(queueClient.addItemRequests, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'disabled assist state shows a graceful banner and Search directly falls back to discovery search',
    (tester) async {
      await pumpSearch(tester, assistEnvelope: _disabledEnvelope);

      await enterAssistMode(tester, 'find me something');

      expect(
        find.textContaining('AI assist is not configured'),
        findsOneWidget,
      );
      expect(find.text('Search directly'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('assist_search_directly')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Fell back to normal discovery search, which still works.
      expect(find.text('Fallback Search Hit'), findsOneWidget);
      expect(find.textContaining('AI assist is not configured'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'assist surfaces provider caveats and provenance honestly',
    (tester) async {
      await pumpSearch(tester, assistEnvelope: _caveatEnvelope);

      await enterAssistMode(tester, 'find me something');

      expect(find.text('Heads up'), findsOneWidget);
      expect(
        find.textContaining('youtube provider failed'),
        findsWidgets,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'assist error envelope shows the error banner with Retry and Search directly',
    (tester) async {
      final queueClient =
          await pumpSearch(tester, assistEnvelope: _errorEnvelope);

      await enterAssistMode(tester, 'find me something');

      expect(
        find.textContaining('assistant is unavailable'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Search directly'), findsOneWidget);

      // Retry re-hits the assist endpoint (no auto-queue side effect).
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('assistant is unavailable'), findsOneWidget);
      expect(queueClient.addItemRequests, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a transport failure surfaces an error banner and Search directly still works',
    (tester) async {
      await pumpSearch(
        tester,
        assistEnvelope: {'message': 'boom'},
        assistStatus: 500,
      );

      await enterAssistMode(tester, 'find me something');

      // No spinner stuck, no crash: the thrown DioException degrades to a
      // banner that keeps the search-directly fallback.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
          find.byKey(const ValueKey('assist_status_banner')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('assist_search_directly')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Fallback Search Hit'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'clarification card renders options and tapping one re-queries assist',
    (tester) async {
      await pumpSearch(tester, assistEnvelope: _clarificationEnvelope);

      await enterAssistMode(tester, 'shelter');

      expect(find.text('Which Shelter do you mean?'), findsOneWidget);
      expect(find.text('The 2016 single'), findsOneWidget);
      // A clarification (no candidates) must NOT show the "no sources" panel.
      expect(find.text('No grounded sources'), findsNothing);

      await tester.tap(find.text('The 2016 single'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The chip re-ran assist with the chosen option as the prompt.
      expect(
        find.byKey(const ValueKey('search_assist_input')),
        findsOneWidget,
      );
      expect(find.text('The 2016 single'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an ok-but-ungrounded response shows the honest empty state without a provenance promise',
    (tester) async {
      await pumpSearch(tester, assistEnvelope: _okEmptyEnvelope);

      await enterAssistMode(tester, 'something obscure');

      expect(find.text('No grounded sources'), findsOneWidget);
      expect(find.byIcon(Icons.playlist_add), findsNothing);
      // The provenance footnote must not promise candidates that are not there.
      expect(
        find.textContaining('Candidates below come from your sources'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'clearing the prompt mid-request never leaves the spinner stuck',
    (tester) async {
      final gate = Completer<void>();
      await pumpSearch(
        tester,
        assistEnvelope: _searchEnvelope,
        assistGate: gate.future,
      );

      await tester.tap(find.text('Assist'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('search_assist_input')),
        'porter robinson',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Request is in flight: spinner shown.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Clear the field before the response lands.
      await tester.enterText(
        find.byKey(const ValueKey('search_assist_input')),
        '',
      );
      await tester.pump();

      // Now let the superseded request complete.
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // No stuck spinner and no resurrected result under the empty prompt.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Porter Robinson - Shelter (Live)'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

const Map<String, dynamic> _candidateJson = {
  'candidateId': 'youtube:abc',
  'provider': 'youtube',
  'sourceId': 'abc',
  'sourceUrl': 'https://youtube.com/watch?v=abc',
  'title': 'Porter Robinson - Shelter (Live)',
  'artist': 'Porter Robinson',
  'durationMs': 245000,
  'downloadable': true,
  'playable': false,
  'metadata': {
    'sourceQuality': {
      'score': 73,
      'classification': 'live',
      'recommendation': 'acceptable',
      'confidence': 0.79,
      'reasons': ['query asked for live content'],
      'warnings': [],
      'provenance': 'deterministic_source_quality_v1',
    },
  },
};

const Map<String, dynamic> _searchEnvelope = {
  'status': 'ok',
  'assistantText': "Here's what I found from your sources.",
  'intent': {'kind': 'search', 'searchQuery': 'porter robinson shelter'},
  'search': {
    'query': 'porter robinson shelter',
    'results': [_candidateJson],
    'providers': [
      {
        'provider': 'youtube',
        'status': 'ok',
        'resultCount': 1,
        'elapsedMs': 20
      },
    ],
  },
};

const Map<String, dynamic> _directUrlEnvelope = {
  'status': 'ok',
  'assistantText':
      'I recognized a direct link. Confirm to add it to your queue.',
  'intent': {'kind': 'direct_url', 'detectedUrl': 'https://youtu.be/abc'},
  'candidates': [
    {
      'candidateId': 'youtube:abc',
      'provider': 'youtube',
      'sourceId': 'abc',
      'sourceUrl': 'https://youtu.be/abc',
      'title': 'Pasted Track',
      'downloadable': true,
      'playable': false,
    },
  ],
};

const Map<String, dynamic> _disabledEnvelope = {
  'status': 'disabled',
  'assistantText':
      'AI assist is not configured. You can still search directly or paste a YouTube/SoundCloud link.',
  'error': {'code': 'AI_DISABLED', 'message': 'ai assist is disabled'},
};

const Map<String, dynamic> _errorEnvelope = {
  'status': 'error',
  'assistantText':
      'The assistant is unavailable right now. You can still search directly or paste a link.',
  'error': {'code': 'AI_UPSTREAM', 'message': 'upstream timeout'},
};

const Map<String, dynamic> _clarificationEnvelope = {
  'status': 'clarification',
  'assistantText': 'Could you give me a bit more detail?',
  'clarification': {
    'question': 'Which Shelter do you mean?',
    'options': ['The 2016 single', 'A live festival set'],
  },
  'intent': {'kind': 'clarify'},
};

const Map<String, dynamic> _okEmptyEnvelope = {
  'status': 'ok',
  'assistantText': 'I looked but came up empty.',
  'intent': {'kind': 'search', 'searchQuery': 'something obscure'},
};

const Map<String, dynamic> _caveatEnvelope = {
  'status': 'ok',
  'assistantText': 'I found a few likely matches.',
  'intent': {'kind': 'search', 'searchQuery': 'something'},
  'search': {
    'query': 'something',
    'results': [_candidateJson],
    'providers': [
      {
        'provider': 'youtube',
        'status': 'degraded',
        'resultCount': 0,
        'elapsedMs': 5,
        'error': {'message': 'youtube provider failed'},
      },
    ],
  },
  'caveats': ['youtube provider failed: degraded'],
};

class _DiscoveryAdapter implements HttpClientAdapter {
  _DiscoveryAdapter(
    this.assistEnvelope, {
    this.assistStatus = 200,
    this.assistGate,
  });

  final Map<String, dynamic> assistEnvelope;
  final int assistStatus;
  final Future<void>? assistGate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.path == '/discovery/assist') {
      if (assistGate != null) {
        await assistGate;
      }
      return _json(assistEnvelope, statusCode: assistStatus);
    }
    if (options.method == 'GET' && options.path == '/discovery/search') {
      return _json({
        'query': options.queryParameters['q'] ?? '',
        'results': [
          {
            'candidateId': 'youtube:fallback',
            'provider': 'youtube',
            'sourceId': 'fallback',
            'sourceUrl': 'https://youtube.com/watch?v=fallback',
            'title': 'Fallback Search Hit',
            'downloadable': true,
            'playable': false,
          },
        ],
        'providers': [
          {
            'provider': 'youtube',
            'status': 'ok',
            'resultCount': 1,
            'elapsedMs': 9,
          },
        ],
      });
    }
    return _json({'message': 'unexpected ${options.method} ${options.path}'},
        statusCode: 404);
  }

  ResponseBody _json(Map<String, dynamic> data, {int statusCode = 200}) {
    return ResponseBody.fromString(
      jsonEncode(data),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _QueueClient extends ApiClient {
  int addItemRequests = 0;
  Map<String, dynamic>? lastAddBody;
  bool _queued = false;

  @override
  Future<QueueState> getQueue() async => QueueState.fromJson(_queueJson());

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<QueueState> addSourceCandidateToQueue({
    required DiscoveryCandidate candidate,
    String position = 'last',
  }) async {
    addItemRequests++;
    lastAddBody = {
      'position': position,
      'sourceCandidate': candidate.toQueueJson(),
    };
    _queued = true;
    return QueueState.fromJson(_queueJson());
  }

  Map<String, dynamic> _queueJson() {
    return {
      'items': _queued
          ? [
              {
                'queueItemId': 'q_1',
                'position': 0,
                'kind': 'source',
                'playbackState': 'downloading',
                'sourceCandidate': _candidateJson,
                'downloadJobId': 'job_1',
                'trackId': null,
                'progress': 5,
                'error': null,
                'canPlay': false,
                'canRetry': false,
                'canRemove': true,
              },
            ]
          : <Map<String, dynamic>>[],
      'currentPosition': 0,
    };
  }
}
