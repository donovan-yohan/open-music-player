import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/discovery/discovery_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  DiscoveryService serviceWith(_AssistAdapter adapter) {
    return DiscoveryService(
      ApiClient(storage: SecureStorage(), dio: Dio()..httpClientAdapter = adapter),
    );
  }

  test('assist posts the prompt to /discovery/assist and parses the envelope',
      () async {
    final adapter = _AssistAdapter((_) => _okEnvelope);
    final service = serviceWith(adapter);

    final response = await service.assist('porter robinson shelter live');

    expect(adapter.lastPath, '/discovery/assist');
    expect(adapter.lastBody?['prompt'], 'porter robinson shelter live');
    expect(adapter.lastBody?.containsKey('limit'), isFalse);
    expect(response.isOk, isTrue);
    expect(response.search?.results.single.title, contains('Shelter'));
    expect(response.caveats, isNotEmpty);
  });

  test('assist forwards an explicit limit', () async {
    final adapter = _AssistAdapter((_) => _okEnvelope);
    final service = serviceWith(adapter);

    await service.assist('city pop', limit: 5);

    expect(adapter.lastBody?['limit'], 5);
  });

  test('assist returns the disabled envelope without throwing', () async {
    final adapter = _AssistAdapter((_) => _disabledEnvelope);
    final service = serviceWith(adapter);

    final response = await service.assist('anything');

    expect(response.isDisabled, isTrue);
    expect(response.error?.code, 'AI_DISABLED');
  });

  test('assist resolves a pasted URL into a grounded candidate', () async {
    final adapter = _AssistAdapter((_) => _directUrlEnvelope);
    final service = serviceWith(adapter);

    final response = await service.assist('https://youtu.be/abc');

    expect(response.isOk, isTrue);
    expect(response.candidates.single.sourceUrl, 'https://youtu.be/abc');
    expect(response.candidates.single.downloadable, isTrue);
  });

  test('assist rethrows a transport failure so the UI can fall back', () async {
    final adapter = _AssistAdapter(
      (_) => (jsonEncode({'message': 'boom'}), 500),
    );
    final service = serviceWith(adapter);

    await expectLater(
      service.assist('porter robinson'),
      throwsA(isA<DioException>()),
    );
  });
}

const Map<String, dynamic> _okEnvelopeJson = {
  'status': 'ok',
  'assistantText': "Here's what I found from your sources.",
  'intent': {'kind': 'search', 'searchQuery': 'porter robinson shelter live'},
  'search': {
    'query': 'porter robinson shelter live',
    'results': [
      {
        'candidateId': 'youtube:abc',
        'provider': 'youtube',
        'sourceId': 'abc',
        'sourceUrl': 'https://youtube.com/watch?v=abc',
        'title': 'Porter Robinson - Shelter (Live)',
        'artist': 'Porter Robinson',
        'durationMs': 245000,
        'downloadable': true,
        'playable': false,
      },
    ],
    'providers': [
      {'provider': 'youtube', 'status': 'ok', 'resultCount': 1, 'elapsedMs': 30},
    ],
  },
  'caveats': ['These are likely matches, not a confirmed live version.'],
};

const Map<String, dynamic> _disabledEnvelopeJson = {
  'status': 'disabled',
  'assistantText': 'AI assist is not configured.',
  'error': {'code': 'AI_DISABLED', 'message': 'ai assist is disabled'},
};

const Map<String, dynamic> _directUrlEnvelopeJson = {
  'status': 'ok',
  'assistantText': 'I recognized a direct link.',
  'intent': {'kind': 'direct_url', 'detectedUrl': 'https://youtu.be/abc'},
  'candidates': [
    {
      'candidateId': 'youtube:abc',
      'provider': 'youtube',
      'sourceId': 'abc',
      'sourceUrl': 'https://youtu.be/abc',
      'title': 'Pasted Track',
      'downloadable': true,
      'playable': false,
    },
  ],
};

final (String, int) _okEnvelope = (jsonEncode(_okEnvelopeJson), 200);
final (String, int) _disabledEnvelope = (jsonEncode(_disabledEnvelopeJson), 200);
final (String, int) _directUrlEnvelope =
    (jsonEncode(_directUrlEnvelopeJson), 200);

class _AssistAdapter implements HttpClientAdapter {
  _AssistAdapter(this.responder);

  final (String, int) Function(RequestOptions options) responder;
  String? lastPath;
  Map<String, dynamic>? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    final data = options.data;
    if (data is Map<String, dynamic>) {
      lastBody = data;
    } else if (data is String && data.isNotEmpty) {
      lastBody = jsonDecode(data) as Map<String, dynamic>;
    }

    final (body, status) = responder(options);
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
