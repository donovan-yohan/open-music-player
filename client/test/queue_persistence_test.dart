import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _track(int id) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'album': 'Album $id',
      'duration': 100 + id,
      'artwork_url': 'https://art/$id.jpg',
    };

void main() {
  group('QueueSnapshot round-trip', () {
    test('a populated snapshot survives encode -> decode unchanged', () {
      final snapshot = QueueSnapshot(
        tracks: [_track(1), _track(2), _track(3)],
        currentIndex: 2,
        positionMs: 45123,
      );

      final restored = QueueSnapshot.decode(snapshot.encode());

      expect(restored.tracks, snapshot.tracks);
      expect(restored.currentIndex, 2);
      expect(restored.positionMs, 45123);
      expect(restored.isEmpty, isFalse);
    });

    test('canonical mix session timing survives encode -> decode', () {
      final session = MixSession.fromQueue(
        sessionId: 'session_1',
        queue: [
          const MediaItem(
            id: '1',
            title: 'Track 1',
            duration: Duration(seconds: 30),
          ),
          const MediaItem(
            id: '2',
            title: 'Track 2',
            duration: Duration(seconds: 45),
          ),
        ],
      ).withPlacementAt(
        1,
        TimelineClip.clamped(
          id: 'ignored',
          trackId: '2',
          sourceDurationMs: 45000,
          sourceStartMs: 5000,
          sourceEndMs: 40000,
          timelineStartMs: 25000,
        ),
      );
      final snapshot = QueueSnapshot(
        tracks: [_track(1), _track(2)],
        currentIndex: 1,
        positionMs: 7000,
        session: session,
      );

      final restored = QueueSnapshot.decode(snapshot.encode());

      expect(restored.session?.sessionId, 'session_1');
      expect(restored.session?.clips.map((clip) => clip.queueItemId), [
        'session_1_item_0',
        'session_1_item_1',
      ]);
      expect(restored.session?.clips[1].sourceStartMs, 5000);
      expect(restored.session?.clips[1].sourceEndMs, 40000);
      expect(restored.session?.clips[1].timelineStartMs, 25000);
    });

    test('an empty snapshot round-trips to an empty (no-op) snapshot', () {
      const snapshot = QueueSnapshot();
      expect(snapshot.isEmpty, isTrue);

      final restored = QueueSnapshot.decode(snapshot.encode());
      expect(restored.isEmpty, isTrue);
      expect(restored.tracks, isEmpty);
      expect(restored.currentIndex, 0);
      expect(restored.positionMs, 0);
    });

    test('null / empty / malformed stored values decode to an empty snapshot',
        () {
      expect(QueueSnapshot.decode(null).isEmpty, isTrue);
      expect(QueueSnapshot.decode('').isEmpty, isTrue);
      expect(QueueSnapshot.decode('not json').isEmpty, isTrue);
      expect(QueueSnapshot.decode('[1,2,3]').isEmpty, isTrue);
    });

    test('an out-of-range index is clamped into the queue bounds', () {
      final snapshot = QueueSnapshot(
        tracks: [_track(1), _track(2)],
        currentIndex: 9,
      );
      final restored = QueueSnapshot.decode(snapshot.encode());
      expect(restored.currentIndex, 1);
    });

    test('a negative position is normalized to zero', () {
      final restored = QueueSnapshot.fromJson({
        'tracks': [_track(1)],
        'currentIndex': 0,
        'positionMs': -500,
      });
      expect(restored.positionMs, 0);
    });
  });

  group('shufflePermutation', () {
    test('returns a permutation of every index with the current item first',
        () {
      final order = shufflePermutation(8, 3, random: Random(1));
      expect(order.length, 8);
      expect(order.first, 3, reason: 'current item stays put');
      expect(order.toSet(), {for (var i = 0; i < 8; i++) i});
    });

    test('for >2 tracks the upcoming order is non-linear', () {
      // A seed that would otherwise leave the natural order must still be nudged
      // to a non-linear upcoming sequence.
      for (var seed = 0; seed < 25; seed++) {
        final order = shufflePermutation(6, 0, random: Random(seed));
        final upcoming = order.sublist(1);
        final natural = [for (var i = 1; i < 6; i++) i];
        expect(upcoming, isNot(equals(natural)),
            reason: 'seed $seed produced a linear upcoming order');
      }
    });

    test('handles the current item being in the middle', () {
      final order = shufflePermutation(5, 2, random: Random(7));
      expect(order.first, 2);
      expect(order.toSet(), {0, 1, 2, 3, 4});
    });

    test('edge cases: empty and single-item queues', () {
      expect(shufflePermutation(0, 0), isEmpty);
      expect(shufflePermutation(1, 0, random: Random(1)), [0]);
      // Two tracks: still a permutation, current first.
      final two = shufflePermutation(2, 0, random: Random(1));
      expect(two.first, 0);
      expect(two.toSet(), {0, 1});
    });
  });

  group('previousAction (3s rule)', () {
    test('more than 3s in restarts the current track', () {
      expect(previousAction(3001), PreviousAction.restart);
      expect(previousAction(10000), PreviousAction.restart);
    });

    test('at or below 3s skips to the previous track', () {
      expect(previousAction(3000), PreviousAction.skip);
      expect(previousAction(2999), PreviousAction.skip);
      expect(previousAction(0), PreviousAction.skip);
    });
  });

  group('mediaItemToPlaybackJson', () {
    test('re-emits the re-resolvable playback shape and drops signed URL data',
        () {
      final item = MediaItem(
        id: '42',
        title: 'Hells Bells',
        artist: 'AC/DC',
        album: 'Back in Black',
        duration: const Duration(seconds: 312),
        artUri: Uri.parse('https://art/42.jpg'),
        extras: {
          'url': 'https://signed/42',
          'expiresAt': '2030-01-01T00:00:00Z',
          'itemOrigin': 'context',
          'analysisStatus': 'analyzed',
          'analysisSummary': {
            'bpm': {'value': 128},
          },
          'analysisOverrides': {
            'bpm': {'value': 130},
          },
          'analysisUpdatedAt': '2026-07-10T11:00:00.123456Z',
          'isLiked': true,
          'likedAccountId': 'user-a',
          'sourceUrl': ' https://source/42 ',
        },
      );

      final json = mediaItemToPlaybackJson(item);
      expect(json['id'], 42);
      expect(json['title'], 'Hells Bells');
      expect(json['artist'], 'AC/DC');
      expect(json['album'], 'Back in Black');
      expect(json['duration'], 312);
      expect(json['artwork_url'], 'https://art/42.jpg');
      expect(json['analysisStatus'], 'analyzed');
      expect(json['analysisSummary'], {
        'bpm': {'value': 128},
      });
      expect(json['analysisOverrides'], {
        'bpm': {'value': 130},
      });
      expect(
        json['analysisUpdatedAt'],
        '2026-07-10T11:00:00.123456Z',
      );
      expect(json['isLiked'], isTrue);
      expect(json['likedAccountId'], 'user-a');
      expect(json['sourceUrl'], 'https://source/42');
      expect(json.containsKey('url'), isFalse);
      expect(json.containsKey('expiresAt'), isFalse);
    });

    test('omits optional liked and source metadata when extras lack them', () {
      const item = MediaItem(id: '42', title: 'Unknown annotations');

      final json = mediaItemToPlaybackJson(item);

      expect(json.containsKey('isLiked'), isFalse);
      expect(json.containsKey('sourceUrl'), isFalse);
    });
  });

  group('QueuePersistenceStore', () {
    test('save then load round-trips a snapshot through SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
      );

      await store.save(QueueSnapshot(
        tracks: [_track(1), _track(2)],
        currentIndex: 1,
        positionMs: 1234,
      ));

      final loaded = await store.load();
      expect(loaded.tracks.length, 2);
      expect(loaded.currentIndex, 1);
      expect(loaded.positionMs, 1234);
    });

    test('saving an empty snapshot clears any stored state', () async {
      SharedPreferences.setMockInitialValues({});
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
      );

      await store.save(QueueSnapshot(tracks: [_track(1)]));
      expect((await store.load()).isEmpty, isFalse);

      await store.save(const QueueSnapshot());
      expect((await store.load()).isEmpty, isTrue);
    });

    test('load with no stored value yields an empty (no-op) snapshot',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
      );
      expect((await store.load()).isEmpty, isTrue);
    });

    test('different account strips liked and source metadata on restore',
        () async {
      SharedPreferences.setMockInitialValues({});
      var accountId = 'user-a';
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
        accountIdProvider: () async => accountId,
      );
      await store.save(
        QueueSnapshot(
          tracks: [
            {
              ..._track(1),
              'isLiked': true,
              'likedAccountId': 'user-a',
              'sourceUrl': 'https://source/1',
            },
          ],
        ),
      );

      accountId = 'user-b';
      final loaded = await store.load();

      expect(loaded.tracks.single.containsKey('isLiked'), isFalse);
      expect(loaded.tracks.single.containsKey('sourceUrl'), isFalse);
      expect(loaded.tracks.single['title'], 'Track 1');
    });

    test('same account preserves liked and source metadata on restore',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
        accountIdProvider: () async => 'user-a',
      );
      await store.save(
        QueueSnapshot(
          tracks: [
            {
              ..._track(1),
              'isLiked': false,
              'likedAccountId': 'user-a',
              'sourceUrl': 'https://source/1',
            },
          ],
        ),
      );

      final loaded = await store.load();

      expect(loaded.tracks.single['isLiked'], isFalse);
      expect(loaded.tracks.single['sourceUrl'], 'https://source/1');
    });

    test('save cannot relabel old live metadata as the current account',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
        accountIdProvider: () async => 'user-b',
      );
      const oldAccountItem = MediaItem(
        id: '1',
        title: 'Old account item',
        extras: {
          'isLiked': true,
          'sourceUrl': 'https://source/1',
          'likedAccountId': 'user-a',
        },
      );

      await store.save(
        QueueSnapshot(
          tracks: [mediaItemToPlaybackJson(oldAccountItem)],
        ),
      );
      final loaded = await store.load();

      expect(loaded.accountId, 'user-b');
      expect(loaded.tracks.single.containsKey('isLiked'), isFalse);
      expect(loaded.tracks.single.containsKey('sourceUrl'), isFalse);
      expect(loaded.tracks.single.containsKey('likedAccountId'), isFalse);
    });
  });

  test('access-token account id parser reads the backend user_id claim', () {
    final header = base64Url.encode(utf8.encode('{}')).replaceAll('=', '');
    final payload = base64Url
        .encode(utf8.encode(jsonEncode({'user_id': 'user-123'})))
        .replaceAll('=', '');

    expect(accountIdFromAccessToken('$header.$payload.signature'), 'user-123');
    expect(accountIdFromAccessToken('invalid'), isNull);
  });
}
