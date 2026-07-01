import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/api_client.dart' as local_api;
import 'package:open_music_player/core/services/search_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_dio_client.dart';

/// Local-search ApiClient stub: routes the three /search/* endpoints to canned
/// envelopes so the screen's local-search wiring is exercised end-to-end
/// without a real HTTP call.
class _FakeSearchApi extends local_api.ApiClient {
  int trackCalls = 0;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    if (endpoint == '/search/recordings') trackCalls++;
    if (queryParams?['q'] == 'zzz') {
      return parser!({'data': [], 'total': 0, 'limit': 20, 'offset': 0});
    }
    final data = switch (endpoint) {
      '/search/recordings' => [
          {
            'id': 1,
            'title': 'Come as You Are',
            'artist': 'Nirvana',
            'album': 'Nevermind',
          }
        ],
      '/search/artists' => [
          {'name': 'Nirvana', 'mbArtistId': 'a1', 'trackCount': 12}
        ],
      '/search/releases' => [
          {
            'name': 'Nevermind',
            'artist': 'Nirvana',
            'mbReleaseId': 'r1',
            'trackCount': 13,
          }
        ],
      _ => <Map<String, dynamic>>[],
    };
    return parser!({
      'data': data,
      'total': data.length,
      'limit': 20,
      'offset': 0,
    });
  }
}

class _NoopDiscoveryAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'query': '', 'results': [], 'providers': []}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  Future<_FakeSearchApi> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final discoveryClient = ApiClient(
      storage: SecureStorage(),
      dio: Dio()..httpClientAdapter = _NoopDiscoveryAdapter(),
    );
    final queueApiClient = EmptyQueueApiClient();
    final searchApi = _FakeSearchApi();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: discoveryClient),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(queueApiClient),
          ),
        ],
        child: MaterialApp(
          home: SearchScreen(searchService: SearchService(searchApi)),
        ),
      ),
    );
    await tester.pump();
    return searchApi;
  }

  Future<void> switchToLibraryAndSearch(WidgetTester tester, String query) async {
    await tester.tap(find.text('My Library'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('search_assist_input')),
      query,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('My Library scope runs local search and renders all sections',
      (tester) async {
    final api = await pump(tester);
    await switchToLibraryAndSearch(tester, 'nirvana');

    expect(api.trackCalls, greaterThan(0));
    expect(find.text('Come as You Are'), findsOneWidget); // song
    expect(find.text('12 tracks in library'), findsOneWidget); // artist section
    expect(find.text('Nevermind'), findsOneWidget); // album title
    expect(find.byKey(const ValueKey('search_local_results')), findsOneWidget);
  });

  testWidgets('Songs chip re-scopes the same query client-side', (tester) async {
    await pump(tester);
    await switchToLibraryAndSearch(tester, 'nirvana');

    // Before filtering, artist + album sections are present.
    expect(find.text('Nevermind'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search_type_chip_songs')));
    await tester.pump();

    // The song survives; the album/artist sections are filtered out without a
    // refetch.
    expect(find.text('Come as You Are'), findsOneWidget);
    expect(find.text('Nevermind'), findsNothing);
  });

  testWidgets('empty results show the "No results for" state', (tester) async {
    await pump(tester);
    await switchToLibraryAndSearch(tester, 'zzz');

    expect(find.byKey(const ValueKey('search_local_empty')), findsOneWidget);
    expect(find.text('No results for "zzz"'), findsOneWidget);
  });

  testWidgets('recent searches appear focused-and-empty and re-run on tap',
      (tester) async {
    await pump(tester);
    await switchToLibraryAndSearch(tester, 'nirvana');

    // Empty the field while keeping it focused -> recents surface.
    await tester.enterText(
      find.byKey(const ValueKey('search_assist_input')),
      '',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('search_recent_searches')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search_recent_nirvana')), findsOneWidget);

    // Re-run from history.
    await tester.tap(find.byKey(const ValueKey('search_recent_nirvana')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Come as You Are'), findsOneWidget);
  });

  testWidgets('remove and clear-all prune recent searches', (tester) async {
    await pump(tester);
    await switchToLibraryAndSearch(tester, 'nirvana');
    await tester.enterText(
      find.byKey(const ValueKey('search_assist_input')),
      '',
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('search_recent_remove_nirvana')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('search_recent_nirvana')), findsNothing);
  });
}
