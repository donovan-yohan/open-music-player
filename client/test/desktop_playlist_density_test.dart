import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/playlists/playlists_screen.dart';
import 'package:open_music_player/shared/models/playlist.dart';
import 'package:open_music_player/shared/widgets/playlist_card.dart';
import 'package:open_music_player/shared/widgets/song_list_item.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => HttpOverrides.global = null);

  for (final width in [959.0, 960.0, 1440.0, 2560.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('real Playlists grid bounded geometry $width $scale',
          (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final http = _OfflineHttp();
        HttpOverrides.global = http;
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(
                  size: Size(width, 900), textScaler: TextScaler.linear(scale)),
              child: const PlaylistsScreen()),
        ));
        await tester.pumpAndSettle();
        expect(http.paths, ['/api/v1/playlists']);
        expect(find.byType(PlaylistCard), findsWidgets);
        final size = tester.getSize(find.byType(PlaylistCard).first);
        if (width >= 960) {
          expect(size.width, lessThanOrEqualTo(220));
          expect(size.height, lessThanOrEqualTo(320));
        } else {
          expect(size.width, greaterThan(400),
              reason: 'mobile two-column layout unchanged');
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('desktop PlaylistListTile uses canonical 56px geometry',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Column(children: [
      PlaylistListTile(
          playlist: Playlist(
              id: 1,
              name: 'Set',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026)),
          onTap: () {}),
    ]))));
    expect(find.byType(SongListItem), findsOneWidget);
    expect(tester.getSize(find.byType(PlaylistListTile)).height, 56);
    expect(tester.takeException(), isNull);
  });
}

// Same isolated transport seam as desktop_delivery_visual_test: real service
// decoding, literal test records, no backend, sockets or platform credentials.
class _OfflineHttp extends HttpOverrides {
  final paths = <String>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Http(paths);
}

class _Http extends Fake implements HttpClient {
  _Http(this.paths);
  final List<String> paths;
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    paths.add(url.path);
    if (url.path != '/api/v1/playlists') throw StateError('Unexpected $url');
    return _Request({
      'playlists': [
        for (var i = 1; i <= 30; i++)
          {
            'id': i,
            'name': 'Playlist $i',
            'track_count': 12,
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00Z',
          }
      ],
      'total': 30,
      'limit': 50,
      'offset': 0
    });
  }

  @override
  void close({bool force = false}) {}
}

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) =>
      action('content-type', ['application/json']);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.body);
  final Object body;
  @override
  final headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  set maxRedirects(int value) {}
  @override
  set persistentConnection(bool value) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async =>
      stream.drain<void>();
  @override
  Future<HttpClientResponse> close() async => _Response(body);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Object body) : bytes = utf8.encode(jsonEncode(body));
  final List<int> bytes;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  HttpHeaders get headers => _Headers();
  @override
  int get statusCode => 200;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  String get reasonPhrase => 'Controlled fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
