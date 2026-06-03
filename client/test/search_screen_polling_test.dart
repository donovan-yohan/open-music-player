import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'does not restart queue polling after SearchScreen is disposed',
    (tester) async {
      final adapter = _QueuePollingAdapter();
      final apiClient = ApiClient(
        storage: SecureStorage(),
        dio: Dio()..httpClientAdapter = adapter,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<ApiClient>.value(value: apiClient),
            ListenableProvider<PlaybackState>.value(value: _FakePlaybackState()),
          ],
          child: MaterialApp(
            home: SearchScreen(initialQueue: [_activeQueueItem(progress: 1)]),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 3));
      expect(adapter.queuePollRequests, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      adapter.completeFirstQueuePoll();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(adapter.queuePollRequests, 1);
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

class _QueuePollingAdapter implements HttpClientAdapter {
  final Completer<ResponseBody> _firstQueuePoll = Completer<ResponseBody>();
  int queuePollRequests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET' && options.path == '/queue') {
      queuePollRequests++;
      if (queuePollRequests == 1) {
        return _firstQueuePoll.future;
      }
      return _jsonResponse(_activeQueueJson(progress: 2));
    }

    return _jsonResponse(
      {'message': 'unexpected ${options.method} ${options.path}'},
      statusCode: 404,
    );
  }

  void completeFirstQueuePoll() {
    if (!_firstQueuePoll.isCompleted) {
      _firstQueuePoll.complete(_jsonResponse(_activeQueueJson(progress: 2)));
    }
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(
  Map<String, dynamic> data, {
  int statusCode = 200,
}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

Map<String, dynamic> _activeQueueJson({required int progress}) {
  return {
    'items': [
      {
        'queueItemId': 'q_1',
        'position': 0,
        'kind': 'source',
        'playbackState': 'downloading',
        'sourceCandidate': _candidateJson(),
        'downloadJobId': 'job_1',
        'trackId': null,
        'progress': progress,
        'error': null,
        'canPlay': false,
        'canRetry': false,
        'canRemove': true,
      },
    ],
    'currentPosition': 0,
  };
}

DiscoveryQueueItem _activeQueueItem({required int progress}) {
  return DiscoveryQueueItem.fromJson(
    _activeQueueJson(progress: progress)['items'].single as Map<String, dynamic>,
  );
}

Map<String, dynamic> _candidateJson() {
  return {
    'candidateId': 'youtube:abc',
    'provider': 'youtube',
    'sourceId': 'abc',
    'sourceUrl': 'https://youtube.com/watch?v=abc',
    'title': 'Plastic Love',
    'uploader': 'mariya channel',
    'durationMs': 253000,
    'downloadable': true,
    'playable': false,
  };
}
