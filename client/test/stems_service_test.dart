import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/stem_channel_source.dart';

/// Captures the endpoint/body a service asked for and returns a canned parsed
/// response, so routing + parsing are asserted without a real HTTP call.
class _FakeApiClient extends ApiClient {
  _FakeApiClient({this.getBody, this.postBody, this.getError}) : super();

  final Map<String, dynamic>? getBody;
  final Map<String, dynamic>? postBody;
  final ApiException? getError;

  String? capturedGetEndpoint;
  Map<String, String>? capturedQueryParams;
  String? capturedPostEndpoint;
  Map<String, dynamic>? capturedPostBody;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    capturedGetEndpoint = endpoint;
    capturedQueryParams = queryParams;
    if (getError != null) throw getError!;
    return parser!(getBody!);
  }

  @override
  Future<T> post<T>(
    String endpoint, {
    Map<String, dynamic>? body,
    T Function(Map<String, dynamic>)? parser,
    bool requiresAuth = true,
  }) async {
    capturedPostEndpoint = endpoint;
    capturedPostBody = body;
    return parser!(postBody!);
  }
}

Map<String, dynamic> _readyBody() => {
      'trackId': 42,
      'channelSet': 'stems5-hybrid-v1',
      'stemModelVersion': 'htdemucs-4s-v1+lr4-180',
      'status': 'ready',
      'artifacts': {
        'objects': [
          {'channel': 'vocals', 'key': 'stems/42/vocals.opus'},
          {'channel': 'melody', 'key': 'stems/42/other.opus'},
          {'channel': 'bass', 'key': 'stems/42/bass.opus'},
          {'channel': 'kick', 'key': 'stems/42/kick.opus'},
          {'channel': 'perc', 'key': 'stems/42/perc.opus'},
        ],
        'codec': {'name': 'opus'},
      },
      'queuePosition': -1,
    };

void main() {
  group('StemsService.getTrackStems', () {
    test('routes to the track stems endpoint with the channel set', () async {
      final api = _FakeApiClient(getBody: _readyBody());

      await StemsService(api).getTrackStems(42);

      expect(api.capturedGetEndpoint, '/tracks/42/stems');
      expect(api.capturedQueryParams, {'channelSet': 'stems5-hybrid-v1'});
    });

    test('reads the channel list out of the worker manifest', () async {
      final stems =
          await StemsService(_FakeApiClient(getBody: _readyBody())).getTrackStems(42);

      expect(stems.status, StemsStatus.ready);
      expect(stems.isReady, isTrue);
      expect(stems.channels, ['vocals', 'melody', 'bass', 'kick', 'perc']);
      expect(stems.stemModelVersion, 'htdemucs-4s-v1+lr4-180');
    });

    test('a ready row with no manifest objects is not reported ready',
        () async {
      final body = _readyBody()..['artifacts'] = {'objects': <dynamic>[]};

      final stems =
          await StemsService(_FakeApiClient(getBody: body)).getTrackStems(42);

      expect(stems.status, StemsStatus.ready);
      expect(stems.isReady, isFalse,
          reason: 'a mixer with no channels is worse than an honest gap');
    });

    test('separating folds into pending so the UI has one in-flight state',
        () async {
      for (final wire in ['pending', 'separating']) {
        final body = _readyBody()
          ..['status'] = wire
          ..['artifacts'] = <String, dynamic>{}
          ..['queuePosition'] = 3;

        final stems =
            await StemsService(_FakeApiClient(getBody: body)).getTrackStems(42);

        expect(stems.status, StemsStatus.pending, reason: wire);
        expect(stems.isPending, isTrue, reason: wire);
        expect(stems.queuePosition, 3);
      }
    });

    test('stale and unknown statuses degrade to unavailable', () async {
      for (final wire in ['stale', 'something-new', '']) {
        final body = _readyBody()..['status'] = wire;

        final stems =
            await StemsService(_FakeApiClient(getBody: body)).getTrackStems(42);

        expect(stems.status, StemsStatus.unavailable, reason: wire);
      }
    });

    test('a failed row carries the backend error text', () async {
      final body = _readyBody()
        ..['status'] = 'failed'
        ..['error'] = 'separator exited 1';

      final stems =
          await StemsService(_FakeApiClient(getBody: body)).getTrackStems(42);

      expect(stems.status, StemsStatus.failed);
      expect(stems.error, 'separator exited 1');
    });

    test('404 is the normal "never asked" state, not an error', () async {
      final api = _FakeApiClient(
        getError: ApiException(
          code: 'STEMS_NOT_FOUND',
          message: 'track stems not found',
          statusCode: 404,
        ),
      );

      final stems = await StemsService(api).getTrackStems(42);

      expect(stems.status, StemsStatus.unavailable);
      expect(stems.channels, isEmpty);
    });

    test('other failures still surface so a deck can say why', () async {
      final api = _FakeApiClient(
        getError: ApiException(
          code: 'SERVICE_DISABLED',
          message: 'stem separation is unavailable',
          statusCode: 503,
        ),
      );

      expect(
        () => StemsService(api).getTrackStems(42),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('StemsService.requestSeparation', () {
    test('POSTs the channel set and parses the trigger result', () async {
      final api = _FakeApiClient(postBody: {
        'trackId': 42,
        'channelSet': 'stems5-hybrid-v1',
        'status': 'pending',
        'queued': true,
        'queuePosition': 1,
        'reason': 'queued',
      });

      final result = await StemsService(api).requestSeparation(42);

      expect(api.capturedPostEndpoint, '/tracks/42/stems');
      expect(api.capturedPostBody, {'channelSet': 'stems5-hybrid-v1'});
      expect(result.status, StemsStatus.pending);
      expect(result.queued, isTrue);
      expect(result.queuePosition, 1);
    });

    test('an idempotent no-op is reported as not queued', () async {
      final api = _FakeApiClient(postBody: {
        'trackId': 42,
        'channelSet': 'stems5-hybrid-v1',
        'status': 'ready',
        'queued': false,
        'reason': 'already_ready',
      });

      final result = await StemsService(api).requestSeparation(42);

      expect(result.queued, isFalse);
      expect(result.reason, 'already_ready');
    });
  });
}
