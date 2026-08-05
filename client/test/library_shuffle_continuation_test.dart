import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/library_shuffle_continuation.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';

/// Captures the endpoint/params the source asked for and returns a canned
/// parsed body, mirroring the fake in library_service_sort_test.dart.
class _CapturingApiClient extends ApiClient {
  _CapturingApiClient(this.envelope) : super();

  final Map<String, dynamic> envelope;
  String? capturedEndpoint;
  Map<String, String>? capturedParams;
  int getCalls = 0;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    getCalls++;
    capturedEndpoint = endpoint;
    capturedParams = queryParams;
    return parser!(envelope);
  }
}

class _FailingApiClient extends ApiClient {
  _FailingApiClient() : super();

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    throw Exception('offline');
  }
}

Map<String, dynamic> _envelope(int count) => {
      'tracks': [
        for (var id = 1; id <= count; id++)
          {
            'id': id,
            'title': 'Track $id',
            'artist': 'Artist $id',
            'duration_ms': 180000,
          },
      ],
      'total': count,
      'limit': count,
      'offset': 0,
    };

void main() {
  group('LibraryShuffleContinuationSource', () {
    test('reads one generous library page with the list projection', () async {
      final api = _CapturingApiClient(_envelope(3));
      final source = LibraryShuffleContinuationSource(
        LibraryService(api),
        random: Random(7),
        candidatePoolSize: 250,
      );

      await source.fetch(excludeTrackIds: const {}, limit: 2);

      expect(api.capturedEndpoint, '/library');
      expect(api.capturedParams?['limit'], '250');
      expect(
        api.capturedParams?['fields'],
        LibraryService.libraryListFields.join(','),
      );
    });

    test('drops excluded ids and honors the batch limit', () async {
      final source = LibraryShuffleContinuationSource(
        LibraryService(_CapturingApiClient(_envelope(6))),
        random: Random(3),
      );

      final batch = await source.fetch(
        excludeTrackIds: const {'1', '2', '3'},
        limit: 2,
      );

      expect(batch, hasLength(2));
      final ids = batch.map((track) => track['id']).toSet();
      expect(ids.intersection({1, 2, 3}), isEmpty);
    });

    test('emits the playback-json shape playQueue consumes', () async {
      final source = LibraryShuffleContinuationSource(
        LibraryService(_CapturingApiClient(_envelope(1))),
        random: Random(1),
      );

      final batch = await source.fetch(excludeTrackIds: const {}, limit: 5);

      expect(batch.single['id'], 1);
      expect(batch.single['title'], 'Track 1');
      // playQueue expects whole seconds, not the library envelope's ms.
      expect(batch.single['duration'], 180);
    });

    test('shuffles rather than replaying the library in order', () async {
      final source = LibraryShuffleContinuationSource(
        LibraryService(_CapturingApiClient(_envelope(40))),
        random: Random(11),
      );

      final batch = await source.fetch(excludeTrackIds: const {}, limit: 40);
      final ids = [for (final track in batch) track['id'] as int];

      expect(ids, hasLength(40));
      expect(ids.toSet(), hasLength(40));
      expect(ids, isNot([for (var id = 1; id <= 40; id++) id]));
    });

    test('an exhausted library answers empty instead of repeating', () async {
      final source = LibraryShuffleContinuationSource(
        LibraryService(_CapturingApiClient(_envelope(2))),
      );

      final batch = await source.fetch(
        excludeTrackIds: const {'1', '2'},
        limit: 5,
      );

      expect(batch, isEmpty);
    });

    test('a zero limit never touches the network', () async {
      final api = _CapturingApiClient(_envelope(2));
      final source = LibraryShuffleContinuationSource(LibraryService(api));

      expect(await source.fetch(excludeTrackIds: const {}, limit: 0), isEmpty);
      expect(api.getCalls, 0);
    });

    test('an offline fetch throws so the caller can stop silently', () async {
      final source = LibraryShuffleContinuationSource(
        LibraryService(_FailingApiClient()),
      );

      await expectLater(
        source.fetch(excludeTrackIds: const {}, limit: 2),
        throwsA(isA<Exception>()),
      );
    });
  });
}
