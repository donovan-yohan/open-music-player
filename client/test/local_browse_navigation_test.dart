import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/api_client.dart' as local_api;
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/search_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/library/local_browse_navigation.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/mock_dio_client.dart';

/// Local-search ApiClient stub returning one artist and one album whose names
/// exercise the encoding boundary: a slash (path separator) and a space.
class _FakeSearchApi extends local_api.ApiClient {
  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    final data = switch (endpoint) {
      '/search/artists' => [
          {'name': 'AC/DC', 'mbArtistId': '', 'trackCount': 3}
        ],
      '/search/releases' => [
          {'name': 'Back in Black', 'artist': 'AC/DC', 'mbReleaseId': ''}
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

/// Records the filter the destination screen asked the backend for.
class _RecordingLibraryService extends LibraryService {
  _RecordingLibraryService() : super(local_api.ApiClient());

  String? capturedArtist;
  String? capturedAlbum;

  @override
  Future<List<Track>> getLibraryByArtist(String artist, {int limit = 500}) {
    capturedArtist = artist;
    return Future.value(const <Track>[]);
  }

  @override
  Future<List<Track>> getLibraryByAlbum(String album, {int limit = 500}) {
    capturedAlbum = album;
    return Future.value(const <Track>[]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('route builders', () {
    test('encode names into a single path segment', () {
      expect(localArtistRoute('AC/DC'), '/library/artist/AC%2FDC');
      expect(
          localAlbumRoute('Back in Black'), '/library/album/Back%20in%20Black');
      expect(localArtistRoute('50%'), '/library/artist/50%25');
    });

    test('reject names that address nothing', () {
      expect(canBrowseLocalName(null), isFalse);
      expect(canBrowseLocalName('   '), isFalse);
      expect(canBrowseLocalName(unknownArtistLabel), isFalse);
      expect(canBrowseLocalName('AC/DC'), isTrue);
    });
  });

  /// Builds the real shipped routes plus a probe screen that pushes them, so
  /// the encode -> match -> decode round trip is the one production runs.
  Future<_RecordingLibraryService> pumpRouter(
    WidgetTester tester,
    Widget home,
  ) async {
    final service = _RecordingLibraryService();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => home),
        ...localBrowseRoutes(libraryService: service),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    return service;
  }

  testWidgets('pushed artist names survive the route round trip',
      (tester) async {
    late BuildContext probeContext;
    final service = await pumpRouter(
      tester,
      Builder(builder: (context) {
        probeContext = context;
        return const Scaffold(body: Text('home'));
      }),
    );

    openLocalArtist(probeContext, 'Sigur Rós / AC/DC 50%');
    await tester.pumpAndSettle();

    expect(find.byType(LocalArtistScreen), findsOneWidget);
    expect(
      tester.widget<LocalArtistScreen>(find.byType(LocalArtistScreen)).artist,
      'Sigur Rós / AC/DC 50%',
    );
    expect(service.capturedArtist, 'Sigur Rós / AC/DC 50%');
  });

  testWidgets('pushed album names survive the route round trip',
      (tester) async {
    late BuildContext probeContext;
    final service = await pumpRouter(
      tester,
      Builder(builder: (context) {
        probeContext = context;
        return const Scaffold(body: Text('home'));
      }),
    );

    openLocalAlbum(probeContext, 'Back in Black');
    await tester.pumpAndSettle();

    expect(find.byType(LocalAlbumScreen), findsOneWidget);
    expect(service.capturedAlbum, 'Back in Black');
  });

  testWidgets('local search artist tile opens the local artist page',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final discoveryClient = ApiClient(
      storage: SecureStorage(),
      dio: Dio()..httpClientAdapter = _NoopDiscoveryAdapter(),
    );
    final service = await pumpRouter(
      tester,
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: discoveryClient),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(EmptyQueueApiClient()),
          ),
        ],
        child: SearchScreen(searchService: SearchService(_FakeSearchApi())),
      ),
    );

    await tester.tap(find.text('My Library'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('search_assist_input')),
      'ac dc',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('search_result_tab_artist')));
    await tester.pump();

    final tile = find.byKey(const ValueKey('search_local_artist_AC/DC'));
    expect(tile, findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.byType(LocalArtistScreen), findsOneWidget);
    expect(
      tester.widget<LocalArtistScreen>(find.byType(LocalArtistScreen)).artist,
      'AC/DC',
    );
    // The screen actually asked the backend for that artist's library rows.
    expect(service.capturedArtist, 'AC/DC');
  });

  testWidgets('local search album tile opens the local album page',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final discoveryClient = ApiClient(
      storage: SecureStorage(),
      dio: Dio()..httpClientAdapter = _NoopDiscoveryAdapter(),
    );
    final service = await pumpRouter(
      tester,
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: discoveryClient),
          ChangeNotifierProvider<QueueProvider>(
            create: (_) => QueueProvider(EmptyQueueApiClient()),
          ),
        ],
        child: SearchScreen(searchService: SearchService(_FakeSearchApi())),
      ),
    );

    await tester.tap(find.text('My Library'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('search_assist_input')),
      'ac dc',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const ValueKey('search_result_tab_album')));
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey('search_local_album_Back in Black')));
    await tester.pumpAndSettle();

    expect(find.byType(LocalAlbumScreen), findsOneWidget);
    expect(service.capturedAlbum, 'Back in Black');
  });
}
