import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';
import 'package:open_music_player/core/discovery/research_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('creates and reviews research with idempotency headers', () async {
    final requests = <RequestOptions>[];
    final api = ApiClient(
      storage: SecureStorage(),
      dio: Dio()
        ..httpClientAdapter = _Adapter((options) {
          requests.add(options);
          if (options.uri.path.endsWith('/research-jobs')) {
            return _Reply(_snapshotJson(), 201);
          }
          if (options.uri.path.endsWith('/reviews')) {
            return _Reply(_decisionJson(), 201);
          }
          throw StateError('unexpected ${options.uri.path}');
        }),
    );
    final service = ResearchService(api);

    final snapshot = await service.create(
      query: 'find shelter',
      idempotencyKey: 'create-1',
    );
    final decision = await service.review(
      jobId: snapshot.job.id,
      candidateId: 'yt:1',
      action: SourceSelectionAction.accepted,
      idempotencyKey: 'review-1',
    );

    expect(snapshot.latestRevision.number, 1);
    expect(decision.id, 'decision-1');
    expect(requests[0].headers['Idempotency-Key'], 'create-1');
    expect(requests[1].headers['Idempotency-Key'], 'review-1');
    expect(requests[0].data, {
      'query': 'find shelter',
      'providers': ['youtube', 'soundcloud'],
      'limit': 12,
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this._handler);

  final _Reply Function(RequestOptions options) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final reply = _handler(options);
    return ResponseBody.fromString(
      jsonEncode(reply.body),
      reply.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Reply {
  const _Reply(this.body, this.statusCode);
  final Map<String, dynamic> body;
  final int statusCode;
}

Map<String, dynamic> _snapshotJson() => {
      'job': {
        'id': 'job-1',
        'status': 'completed',
        'retrySafe': false,
        'attempts': 1,
        'maxAttempts': 2,
        'latestRevision': 1,
        'latestRevisionId': 'revision-1',
        'createdAt': '2026-07-17T00:00:00Z',
        'updatedAt': '2026-07-17T00:00:01Z',
      },
      'revisions': [
        {
          'id': 'revision-1',
          'jobId': 'job-1',
          'number': 1,
          'kind': 'baseline',
          'validatedAt': '2026-07-17T00:00:01Z',
          'payload': {
            'schemaVersion': 'omp.research.revision.v1',
            'stage': 'baseline',
            'query': 'find shelter',
            'candidates': [],
            'recommendations': [],
            'provenance': {'source': 'deterministic'},
            'timing': {},
          },
        },
      ],
    };

Map<String, dynamic> _decisionJson() => {
      'id': 'decision-1',
      'selectedCandidateId': 'yt:1',
      'recommendedCandidateId': 'yt:1',
      'action': 'accepted',
      'origin': 'research',
      'selectedCandidate': {
        'candidateId': 'yt:1',
        'provider': 'youtube',
        'sourceUrl': 'https://youtube.example/watch?v=1',
        'title': 'Shelter',
        'downloadable': true,
        'playable': false,
      },
      'sourceQuality': {
        'score': 90,
        'classification': 'official_audio',
        'recommendation': 'recommended',
        'confidence': 0.9
      },
      'createdAt': '2026-07-17T00:00:01Z',
    };
