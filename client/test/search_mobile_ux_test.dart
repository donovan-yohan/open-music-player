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
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<_SearchAdapter> pumpSearch(
    WidgetTester tester, {
    ApiClient? queueClient,
  }) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final searchAdapter = _SearchAdapter();
    final discovery = ApiClient(
      storage: SecureStorage(),
      dio: Dio()..httpClientAdapter = searchAdapter,
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: discovery),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(queueClient ?? _EmptyQueueClient()),
          ),
        ],
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
    return searchAdapter;
  }

  Future<void> search(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('search_assist_input')),
      'sad machine',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets(
      'Song is the default tab and catalog sources stay in response order',
      (tester) async {
    await pumpSearch(tester);
    expect(
        find.byKey(const ValueKey('search_result_tab_song')), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('search_result_tab_song')))
          .height,
      greaterThanOrEqualTo(48),
    );

    await search(tester);

    expect(
        find.byKey(const ValueKey('search_sources_primary')), findsOneWidget);
    expect(find.text('Official source'), findsOneWidget);
    expect(find.text('Lower quality source'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Official source')).dy,
      lessThan(tester.getTopLeft(find.text('Lower quality source')).dy),
    );
    expect(find.text('MusicBrainz Artist'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('search_result_tab_artist')));
    await tester.pump();
    expect(find.text('MusicBrainz Artist'), findsOneWidget);
    expect(find.text('Official source'), findsNothing);
  });

  testWidgets('provider summary opens per-provider detail', (tester) async {
    await pumpSearch(tester);
    await search(tester);

    expect(
        find.byKey(const ValueKey('search_provider_summary')), findsOneWidget);
    expect(find.text('youtube: ok'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('search_provider_summary')));
    await tester.pumpAndSettle();
    expect(find.text('Discover sources'), findsOneWidget);
    expect(find.text('youtube · degraded'), findsOneWidget);
    expect(find.textContaining('Error kind: RATE_LIMITED'), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'tapping a source previews its exact provider URL without queueing',
      (tester) async {
    final originalLauncher = UrlLauncherPlatform.instance;
    final launcher = _RecordingUrlLauncher();
    final queueClient = _EmptyQueueClient();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = originalLauncher);

    final searchAdapter = await pumpSearch(tester, queueClient: queueClient);
    await search(tester);
    await tester.tap(find.text('Official source'));
    await tester.pump();

    expect(launcher.url, 'https://youtube.com/watch?v=official');
    expect(
      launcher.options?.mode,
      PreferredLaunchMode.externalApplication,
    );
    expect(queueClient.addSourceDecisionCalls, 0);
    expect(searchAdapter.sourceSelectionRequests, isEmpty);
    expect(find.byIcon(Icons.playlist_add), findsWidgets);
  });

  testWidgets('SERVICE_DISABLED queue is silent and removes queue affordances',
      (tester) async {
    final queueClient = _ActiveThenDisabledQueueClient();
    await pumpSearch(tester, queueClient: queueClient);
    await tester.pump();
    expect(queueClient.getQueueCalls, 1);

    // The initial active item schedules a poll. Its next response disables the
    // optional queue, after which advancing time cannot schedule a third call.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(queueClient.getQueueCalls, 2);
    await tester.pump(const Duration(seconds: 4));
    expect(queueClient.getQueueCalls, 2);
    await search(tester);

    expect(find.textContaining('SERVICE_DISABLED'), findsNothing);
    expect(find.byIcon(Icons.playlist_add), findsNothing);
    expect(find.byKey(const ValueKey('search_queue_affordance')), findsNothing);
    expect(
        find.byKey(const ValueKey('discover_preview_source_youtube:official')),
        findsOneWidget);
  });
}

class _SearchAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> sourceSelectionRequests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.path == '/source-selections') {
      sourceSelectionRequests.add(
        Map<String, dynamic>.from(options.data as Map),
      );
    }
    return ResponseBody.fromString(
      jsonEncode({
        'query': options.queryParameters['q'] ?? '',
        'results': [_official, _lowQuality],
        'sections': [
          {
            'kind': 'artists',
            'title': 'Artists',
            'items': [
              {
                'kind': 'artist',
                'id': 'artist-1',
                'title': 'MusicBrainz Artist'
              },
            ],
          },
          {
            'kind': 'albums',
            'title': 'Albums',
            'items': [
              {'kind': 'album', 'id': 'album-1', 'title': 'MusicBrainz Album'},
            ],
          },
        ],
        'providers': [
          {
            'provider': 'youtube',
            'status': 'degraded',
            'resultCount': 2,
            'elapsedMs': 12,
            'error': {'kind': 'RATE_LIMITED', 'message': 'Try again later'},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _official = {
  'candidateId': 'youtube:official',
  'provider': 'youtube',
  'sourceId': 'official',
  'sourceUrl': 'https://youtube.com/watch?v=official',
  'title': 'Official source',
  'downloadable': true,
  'playable': false,
  'sourceQuality': {
    'score': 98,
    'classification': 'official_audio',
    'recommendation': 'preferred',
    'confidence': 0.95,
  },
};

const _lowQuality = {
  'candidateId': 'youtube:low',
  'provider': 'youtube',
  'sourceId': 'low',
  'sourceUrl': 'https://youtube.com/watch?v=low',
  'title': 'Lower quality source',
  'downloadable': true,
  'playable': false,
  'sourceQuality': {
    'score': 12,
    'classification': 'cover',
    'recommendation': 'avoid',
    'confidence': 0.5,
  },
};

class _EmptyQueueClient extends ApiClient {
  int addSourceDecisionCalls = 0;

  @override
  Future<QueueState> getQueue() async => QueueState.empty();

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<SourceDecisionQueueResponse> addSourceDecisionToQueue({
    required String sourceDecisionId,
    String position = 'last',
  }) async {
    addSourceDecisionCalls++;
    throw UnimplementedError('preview must not queue a source');
  }
}

class _ActiveThenDisabledQueueClient extends _EmptyQueueClient {
  int getQueueCalls = 0;

  @override
  Future<QueueState> getQueue() async {
    getQueueCalls++;
    if (getQueueCalls == 1) {
      return QueueState.fromJson({
        'items': [
          {
            'queueItemId': 'q-1',
            'position': 0,
            'kind': 'source',
            'playbackState': 'downloading',
            'sourceCandidate': _official,
            'progress': 1,
            'canPlay': false,
            'canRetry': false,
            'canRemove': true,
          },
        ],
        'currentPosition': 0,
      });
    }
    throw ApiException(
      'SERVICE_DISABLED',
      503,
      errorCode: 'SERVICE_DISABLED',
    );
  }
}

class _RecordingUrlLauncher extends UrlLauncherPlatform {
  String? url;
  LaunchOptions? options;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    this.url = url;
    this.options = options;
    return true;
  }
}
