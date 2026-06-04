import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/services/api_client.dart' as queue_api;
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'mobile discovery result tiles use compact media and icon-only queue action',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final apiClient = ApiClient(
        storage: SecureStorage(),
        dio: Dio()..httpClientAdapter = _SearchResultAdapter(),
      );

      final queueApiClient = queue_api.ApiClient(
        httpClient: _emptyQueueClient(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<ApiClient>.value(value: apiClient),
            Provider<queue_api.ApiClient>.value(value: queueApiClient),
            ChangeNotifierProvider<QueueProvider>(
              create: (_) => QueueProvider(queueApiClient),
            ),
            ListenableProvider<PlaybackState>.value(
              value: _FakePlaybackState(),
            ),
          ],
          child: const MaterialApp(home: SearchScreen()),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'porter robinson');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.text('Porter Robinson - Sad Machine'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byIcon(Icons.playlist_add), findsOneWidget);

      final queueButton = find.ancestor(
        of: find.byIcon(Icons.playlist_add),
        matching: find.byType(IconButton),
      );
      expect(tester.getSize(queueButton), const Size(40, 40));

      final thumbBox = find.ancestor(
        of: find.byIcon(Icons.music_note),
        matching: find.byType(SizedBox),
      );
      expect(tester.getSize(thumbBox.first), const Size(42, 42));

      final title = tester.widget<Text>(
        find.text('Porter Robinson - Sad Machine'),
      );
      expect(title.style?.fontSize, 14);

      final subtitle = tester.widget<Text>(
        find.text('Porter Robinson • soundcloud • 4:32'),
      );
      expect(subtitle.style?.fontSize, 12);
    },
  );
}

class _FakePlaybackState extends Fake implements PlaybackState {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  bool get isResolvingSignedUrl => false;

  @override
  String? get playbackError => null;
}

MockClient _emptyQueueClient() {
  return MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/api/v1/queue') {
      return http.Response(jsonEncode({'items': []}), 200);
    }
    return http.Response(
      jsonEncode({
        'message': 'unexpected ${request.method} ${request.url.path}',
      }),
      404,
    );
  });
}

class _SearchResultAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/discovery/search') {
      return _jsonResponse({
        'query': options.queryParameters['q'] ?? 'porter robinson',
        'results': [
          {
            'candidateId': 'soundcloud:123',
            'provider': 'soundcloud',
            'sourceId': '123',
            'sourceUrl': 'https://soundcloud.com/porter/sad-machine',
            'title': 'Porter Robinson - Sad Machine',
            'artist': 'Porter Robinson',
            'durationMs': 272000,
            'downloadable': true,
            'playable': false,
          },
        ],
        'providers': [
          {
            'provider': 'soundcloud',
            'status': 'ok',
            'resultCount': 1,
            'elapsedMs': 12,
          },
        ],
      });
    }

    return _jsonResponse({
      'message': 'unexpected ${options.method} ${options.path}',
    }, statusCode: 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
