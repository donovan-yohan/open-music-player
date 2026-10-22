import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native startup ignores the macOS sandbox file Uri.base', () {
    final sandbox = Directory(
      '/Users/soundq-fixture/Library/Containers/'
      'com.openmusicplayer.openMusicPlayer/Data/',
    );
    IOOverrides.runZoned(() {
      expect(Uri.base, sandbox.uri);
      expect(Uri.base.scheme, 'file');
      final router = createRouter(_StartupAuth());
      addTearDown(router.dispose);
      expect(router.routeInformationProvider.value.uri.toString(), '/');
      expect(router.configuration.findMatch('/').error, isNull);
    }, getCurrentDirectory: () => sandbox);
  }, skip: kIsWeb);

  test('web startup retains the browser Uri.base path fallback', () {
    final router = createRouter(_StartupAuth());
    addTearDown(router.dispose);
    final path = Uri.base.path;
    expect(router.routeInformationProvider.value.uri.toString(),
        path.isEmpty ? '/' : path);
  }, skip: !kIsWeb);

  final shared = Uri(path: '/share', queryParameters: {
    'text': 'https://youtu.be/test-video?list=one&index=2',
    'auto': '1',
  }).toString();
  const imports = '/queue/imports?importJobId=startup-job#progress';

  for (final location in [imports, shared]) {
    testWidgets('platform startup deep link preserves $location',
        (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = location;
      addTearDown(() {
        tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
      });
      final router = createRouter(_StartupAuth());
      addTearDown(router.dispose);
      expect(router.overridePlatformDefaultLocation, isFalse);
      expect(router.routeInformationProvider.value.uri.toString(), location);
      final parsed = await _parseStartupLocation(tester, router);
      expect(parsed.error, isNull);
      expect(parsed.uri.toString(), location);
    });
  }

  testWidgets('runtime platform deep link retains shared text and auto query',
      (tester) async {
    final router = createRouter(_StartupAuth());
    addTearDown(router.dispose);
    void listener() {}
    router.routeInformationProvider.addListener(listener);
    addTearDown(() => router.routeInformationProvider.removeListener(listener));
    expect(
        await router.routeInformationProvider
            .didPushRouteInformation(RouteInformation(uri: Uri.parse(shared))),
        isTrue);
    final parsed = await _parseStartupLocation(tester, router);
    expect(parsed.error, isNull);
    expect(parsed.uri.toString(), shared);
    expect(parsed.uri.queryParameters, {
      'text': 'https://youtu.be/test-video?list=one&index=2',
      'auto': '1',
    });
  });

  for (final locked in [false, true]) {
    testWidgets('platform deep link survives auth gate locked=$locked',
        (tester) async {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = imports;
      addTearDown(() {
        tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
      });
      final auth = _StartupAuth(authenticated: false, locked: locked);
      final router = createRouter(auth);
      addTearDown(router.dispose);
      final gated = await _parseStartupLocation(tester, router);
      expect(gated.error, isNull);
      expect(gated.uri.path, locked ? '/unlock' : '/login');
      expect(gated.uri.queryParameters['next'], imports);
      // Exercise the existing post-login redirect with the retained destination.
      auth.authenticated = true;
      auth.locked = false;
      router.go('/login?next=${Uri.encodeComponent(imports)}');
      final resumed = await _parseStartupLocation(tester, router);
      expect(resumed.error, isNull);
      expect(resumed.uri.toString(), imports);
    });
  }

  testWidgets('platform login next preserves the public share query',
      (tester) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue =
        '/login?next=${Uri.encodeComponent(shared)}';
    addTearDown(() {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    });
    final router = createRouter(_StartupAuth());
    addTearDown(router.dispose);
    final parsed = await _parseStartupLocation(tester, router);
    expect(parsed.error, isNull);
    expect(parsed.uri.toString(), shared);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'Search import actions write through QueueProvider and link to imports',
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
            builder: (_, __) => const Scaffold(body: Text('playback landing')),
          ),
          GoRoute(
            path: '/queue/imports',
            builder: (_, __) => const Scaffold(body: Text('imports landing')),
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

      await tester.tap(find.byIcon(Icons.queue_music));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(queueClient.postedSourceDecisions, 1);
      expect(
        queueProvider.queue.tracks.single.sourceCandidateId,
        'youtube:abc',
      );
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('View imports'), findsWidgets);
      expect(find.text('1 item in Import queue'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('search_queue_affordance')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('search_view_queue_youtube:abc')),
      );
      await tester.pumpAndSettle();

      expect(find.text('imports landing'), findsOneWidget);

      router.go('/search');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('search_queue_affordance')),
          matching: find.text('View imports'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('imports landing'), findsOneWidget);
      expect(find.text('playback landing'), findsNothing);
    },
  );

  testWidgets(
    'ordinary Discover selection accepts a non-first Scribble Remix without ranking metadata',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final sourceSelectionRequests = <Map<String, dynamic>>[];
      final discoveryClient = ApiClient(
        storage: SecureStorage(),
        dio: Dio()
          ..httpClientAdapter = _NeutralSelectionSearchAdapter(
            sourceSelectionRequests,
          ),
      );
      final queueClient = _QueueMutationClient();

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

      await tester.enterText(find.byType(TextField), 'one more time remix');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        find.text('Daft Punk - One More Time (Scribble Remix)'),
        findsOneWidget,
      );
      await tester.tap(find.byIcon(Icons.queue_music).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Choose alternate source'), findsNothing);
      expect(sourceSelectionRequests, [
        {
          'sessionId': '22222222-2222-2222-2222-222222222222',
          'candidateId': 'youtube:scribble-remix',
          'action': 'selected',
        },
      ]);
      expect(queueClient.postedSourceDecisions, 1);
    },
  );

  testWidgets(
    'production imports deep link uses shell and Queue tab returns to playback',
    (tester) async {
      final authState = _RouterAuthState(authenticated: true);
      final queueClient = _QueueMutationClient()..postedSourceDecisions = 1;
      final queueProvider = QueueProvider(queueClient);
      final playbackState = _RouterPlaybackState();
      final commandRegistry = CommandRegistry(playbackState: playbackState);
      tester.binding.platformDispatcher.defaultRouteNameTestValue =
          '/queue/imports';
      addTearDown(() {
        tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
      });
      final router = createRouter(authState);
      addTearDown(router.dispose);
      addTearDown(queueProvider.dispose);
      addTearDown(playbackState.disposeFake);
      addTearDown(commandRegistry.dispose);

      await tester.pumpWidget(
        _productionRouterHost(
          authState: authState,
          queueProvider: queueProvider,
          playbackState: playbackState,
          commandRegistry: commandRegistry,
          router: router,
        ),
      );
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/queue/imports');
      expect(find.byKey(const ValueKey('soundq_mobile_shell')), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey('queue_list_view')),
        findsOneWidget,
      );
      expect(find.text('Plastic Love'), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        4,
      );

      await tester.tap(find.widgetWithText(NavigationDestination, 'Queue'));
      await tester.pumpAndSettle();

      expect(router.routeInformationProvider.value.uri.path, '/queue');
      expect(find.text('Playback Queue'), findsOneWidget);
      expect(
        find.byKey(const PageStorageKey('playback_queue_list_view')),
        findsOneWidget,
      );
      expect(find.byKey(const PageStorageKey('queue_list_view')), findsNothing);
    },
  );

  testWidgets('production imports deep link preserves auth redirect target', (
    tester,
  ) async {
    final authState = _RouterAuthState(authenticated: false);
    final queueProvider = QueueProvider(_QueueMutationClient());
    final playbackState = _RouterPlaybackState();
    final commandRegistry = CommandRegistry(playbackState: playbackState);
    tester.binding.platformDispatcher.defaultRouteNameTestValue =
        '/queue/imports';
    addTearDown(() {
      tester.binding.platformDispatcher.defaultRouteNameTestValue = '/';
    });
    final router = createRouter(authState);
    addTearDown(router.dispose);
    addTearDown(queueProvider.dispose);
    addTearDown(playbackState.disposeFake);
    addTearDown(commandRegistry.dispose);

    await tester.pumpWidget(
      _productionRouterHost(
        authState: authState,
        queueProvider: queueProvider,
        playbackState: playbackState,
        commandRegistry: commandRegistry,
        router: router,
      ),
    );
    await tester.pumpAndSettle();

    final location = router.routeInformationProvider.value.uri;
    expect(location.path, '/login');
    expect(location.queryParameters['next'], '/queue/imports');
    expect(find.text('Sign in to continue'), findsOneWidget);
    expect(find.byKey(const ValueKey('soundq_mobile_shell')), findsNothing);
  });
}

// Use production provider/parser/auth redirects without mounting audio/network
// owners. Startup tests never call go() to replace the initial route.
Future<RouteMatchList> _parseStartupLocation(
    WidgetTester tester, GoRouter router) async {
  late BuildContext context;
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Builder(builder: (value) {
      context = value;
      return const SizedBox.shrink();
    }),
  ));
  return router.routeInformationParser.parseRouteInformationWithDependencies(
      router.routeInformationProvider.value, context);
}

class _StartupAuth extends Fake implements AuthState {
  _StartupAuth({this.authenticated = true, this.locked = false});
  bool authenticated;
  bool locked;
  @override
  bool get hasLocalSession => authenticated || locked;
  @override
  bool get isBiometricLocked => locked;
  @override
  bool get isAuthenticated => authenticated;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

Widget _productionRouterHost({
  required AuthState authState,
  required QueueProvider queueProvider,
  required PlaybackState playbackState,
  required CommandRegistry commandRegistry,
  required GoRouter router,
}) {
  return MultiProvider(
    providers: [
      ListenableProvider<AuthState>.value(value: authState),
      ChangeNotifierProvider<QueueProvider>.value(value: queueProvider),
      ListenableProvider<PlaybackState>.value(value: playbackState),
      Provider<CommandRegistry>.value(value: commandRegistry),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

class _RouterAuthState extends Fake implements AuthState {
  _RouterAuthState({required this.authenticated});

  final bool authenticated;

  @override
  bool get hasLocalSession => authenticated;

  @override
  bool get isAuthenticated => authenticated;

  @override
  bool get isBiometricLocked => false;

  @override
  bool get isLoading => false;

  @override
  String? get error => null;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _RouterPlaybackState extends Fake implements PlaybackState {
  final ChangeNotifier _notifier = ChangeNotifier();
  static const item = audio_service.MediaItem(
    id: 'playback-track',
    title: 'Playback route track',
    duration: Duration(minutes: 2),
  );
  final TimelineModel _timelineModel = TimelineModel();

  @override
  bool get hasTrack => true;

  @override
  audio_service.MediaItem get currentItem => item;

  @override
  List<audio_service.MediaItem> get queue => const [item];

  @override
  int get currentIndex => 0;

  @override
  Duration get duration => item.duration!;

  @override
  Duration get position => Duration.zero;

  @override
  bool get isPlaying => false;

  @override
  bool get isResolvingSignedUrl => false;

  @override
  bool get canSkipNext => false;

  @override
  bool get hasPreviousInPlayOrder => false;

  @override
  PlaybackContext? get playbackContext => null;

  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot.empty();

  @override
  TimelineModel get timelineModel => _timelineModel;

  @override
  BeatSnapMode get transitionSnapMode => BeatSnapMode.downbeat;

  @override
  int get timelinePositionMs => 0;

  @override
  Future<void> togglePlayPause() async {}

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  void disposeFake() => _notifier.dispose();
}

/// Drives [QueueProvider] through the unified [ApiClient] surface (method
/// override) so the Search → Queue write-through is exercised without a live
/// transport. The POST body contract itself is covered by
/// queue_api_client_contract_test.dart.
class _QueueMutationClient extends ApiClient {
  int postedSourceDecisions = 0;

  @override
  Future<QueueState> getQueue() async => QueueState.fromJson(
        postedSourceDecisions == 0 ? _emptyQueue() : _queuedSourceQueue(),
      );

  @override
  Future<List<MixPlan>> listMixPlans({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<SourceDecisionQueueResponse> addSourceDecisionToQueue({
    required String sourceDecisionId,
    String position = 'last',
    int? playlistId,
  }) async {
    postedSourceDecisions++;
    return SourceDecisionQueueResponse(
      queue: QueueState.fromJson(_queuedSourceQueue()),
      downloadJobId: 'job_1',
      idempotent: false,
    );
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
          'selectionSessionId': '11111111-1111-1111-1111-111111111111',
          'recommendedCandidateId': 'youtube:abc',
          'selectionExpiresAt': '2099-01-01T00:00:00Z',
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

    if (options.method == 'POST' && options.path == '/source-selections') {
      return ResponseBody.fromString(
        jsonEncode({
          'id': 'decision-1',
          'sessionId': '11111111-1111-1111-1111-111111111111',
          'selectedCandidateId': 'youtube:abc',
          'recommendedCandidateId': 'youtube:abc',
          'action': 'accepted',
          'origin': 'search',
          'selectedCandidate': _candidateJson(),
          'sourceQuality': const {},
          'createdAt': '2026-07-13T00:00:00Z',
        }),
        201,
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

class _NeutralSelectionSearchAdapter implements HttpClientAdapter {
  _NeutralSelectionSearchAdapter(this.sourceSelectionRequests);

  final List<Map<String, dynamic>> sourceSelectionRequests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/discovery/search') {
      return ResponseBody.fromString(
        jsonEncode({
          'query': options.queryParameters['q'] ?? '',
          'results': [_ordinaryFirstCandidate(), _scribbleRemixCandidate()],
          'selectionSessionId': '22222222-2222-2222-2222-222222222222',
          'selectionExpiresAt': '2099-01-01T00:00:00Z',
          'providers': [
            {
              'provider': 'youtube',
              'status': 'ok',
              'resultCount': 2,
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

    if (options.method == 'POST' && options.path == '/source-selections') {
      final request = Map<String, dynamic>.from(options.data as Map);
      sourceSelectionRequests.add(request);
      return ResponseBody.fromString(
        jsonEncode({
          'id': 'decision-scribble',
          'sessionId': request['sessionId'],
          'selectedCandidateId': request['candidateId'],
          'action': request['action'],
          'origin': 'search',
          'selectedCandidate': _scribbleRemixCandidate(),
          'sourceQuality': const {},
          'createdAt': '2026-08-05T00:00:00Z',
        }),
        201,
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

Map<String, dynamic> _ordinaryFirstCandidate() {
  return {
    'candidateId': 'youtube:official',
    'provider': 'youtube',
    'sourceId': 'official',
    'sourceUrl': 'https://youtube.test/watch?v=official',
    'title': 'Daft Punk - One More Time',
    'downloadable': true,
    'playable': false,
  };
}

Map<String, dynamic> _scribbleRemixCandidate() {
  return {
    'candidateId': 'youtube:scribble-remix',
    'provider': 'youtube',
    'sourceId': 'scribble-remix',
    'sourceUrl': 'https://youtube.test/watch?v=scribble-remix',
    'title': 'Daft Punk - One More Time (Scribble Remix)',
    'downloadable': true,
    'playable': false,
  };
}
