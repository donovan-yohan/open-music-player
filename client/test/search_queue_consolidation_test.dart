import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:dio/dio.dart';
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

      await tester.tap(find.byIcon(Icons.playlist_add));
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
    'production imports deep link uses shell and Queue tab returns to playback',
    (tester) async {
      final authState = _RouterAuthState(authenticated: true);
      final queueClient = _QueueMutationClient()..postedSourceDecisions = 1;
      final queueProvider = QueueProvider(queueClient);
      final playbackState = _RouterPlaybackState();
      final commandRegistry = CommandRegistry(playbackState: playbackState);
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
      router.go('/queue/imports');
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
        3,
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
    router.go('/queue/imports');
    await tester.pumpAndSettle();

    final location = router.routeInformationProvider.value.uri;
    expect(location.path, '/login');
    expect(location.queryParameters['next'], '/queue/imports');
    expect(find.text('Sign in to continue'), findsOneWidget);
    expect(find.byKey(const ValueKey('soundq_mobile_shell')), findsNothing);
  });
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
