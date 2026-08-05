import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/library_shuffle_continuation.dart';
import 'package:open_music_player/core/audio/playback_source_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/models/track.dart';

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

  group('exclusion id round trip', () {
    // The exclusion set is built from MediaItem.id (PlaybackState
    // ._handleQueueExhausted) but compared against Track.id.toString(). These
    // pin that the two representations cannot drift apart, including for the
    // one shape that looks like it should: a source-backed queue row whose own
    // `id` is a UUID rather than the backend track id.
    test('a source-backed queue item resolves to the numeric library id',
        () async {
      final queueTrack = QueueTrack.fromJson({
        'id': '7a1f4d02-3c9b-4f11-9a55-2f6c8de40b13',
        'queueItemId': '7a1f4d02-3c9b-4f11-9a55-2f6c8de40b13',
        // Backend track id, carried separately from the queue item UUID.
        'trackId': 2,
        'title': 'Source backed',
        'artist': 'Artist 2',
        'duration': 180,
        'status': 'completed',
      });
      expect(queueTrack.id, isNot('2'), reason: 'the row id is the item UUID');

      final items = await _resolver().resolveQueue([
        queueTrack.toPlaybackJson(),
      ]);

      // MediaItem.id is PlaybackSourceResolver's `trackId.toString()`, never
      // the queue item UUID — so the exclusion key is the library id.
      expect(items.single.id, '2');
    });

    test('an excluded source-backed item is dropped from the candidate pool',
        () async {
      final queueTrack = QueueTrack.fromJson({
        'id': '7a1f4d02-3c9b-4f11-9a55-2f6c8de40b13',
        'trackId': 2,
        'title': 'Source backed',
        'duration': 180,
        'status': 'completed',
      });
      final items = await _resolver().resolveQueue([
        queueTrack.toPlaybackJson(),
      ]);
      final source = LibraryShuffleContinuationSource(
        LibraryService(_CapturingApiClient(_envelope(3))),
        random: Random(5),
      );

      final batch = await source.fetch(
        // Exactly how PlaybackState assembles the set from the played queue.
        excludeTrackIds: {for (final item in items) item.id},
        limit: 5,
      );

      expect(batch.map((track) => track['id']), isNot(contains(2)));
      expect(batch.map((track) => track['id']).toSet(), {1, 3});
    });

    test('a library track resolves to the same id it is excluded by', () async {
      final page = await LibraryService(
        _CapturingApiClient(_envelope(1)),
      ).getLibraryPage(limit: 1);
      final track = page.tracks.single;

      final items = await _resolver().resolveQueue([track.toPlaybackJson()]);

      expect(items.single.id, track.id.toString());
    });
  });
}

/// A resolver wired to a canned signing backend, so `resolveQueue` exercises
/// the real MediaItem construction path without network or platform audio.
PlaybackSourceResolver _resolver() => PlaybackSourceResolver(
      signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
        final ids = (body['trackIds'] as List).cast<int>();
        return {
          'urls': [
            for (final id in ids)
              {
                'trackId': id,
                'url': 'https://example.com/$id.mp3',
                'expiresAt': DateTime.utc(2027).toIso8601String(),
              },
          ],
          'unavailable': <Map<String, dynamic>>[],
        };
      }),
    );
