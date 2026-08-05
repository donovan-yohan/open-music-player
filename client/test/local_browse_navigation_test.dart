import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_music_player/core/services/api_client.dart' as local_api;
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/features/library/local_browse_navigation.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/shared/models/track.dart';

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

  group('route builders', () {
    test('encode names into a single path segment', () {
      expect(localArtistRoute('AC/DC'), '/library/artist/AC%2FDC');
      expect(
        localAlbumRoute('Back in Black'),
        '/library/album/Back%20in%20Black',
      );
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

  testWidgets('pushed artist names survive the route round trip', (
    tester,
  ) async {
    late BuildContext probeContext;
    final service = await pumpRouter(
      tester,
      Builder(
        builder: (context) {
          probeContext = context;
          return const Scaffold(body: Text('home'));
        },
      ),
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

  testWidgets('pushed album names survive the route round trip', (
    tester,
  ) async {
    late BuildContext probeContext;
    final service = await pumpRouter(
      tester,
      Builder(
        builder: (context) {
          probeContext = context;
          return const Scaffold(body: Text('home'));
        },
      ),
    );

    openLocalAlbum(probeContext, 'Back in Black');
    await tester.pumpAndSettle();

    expect(find.byType(LocalAlbumScreen), findsOneWidget);
    expect(service.capturedAlbum, 'Back in Black');
  });
}
