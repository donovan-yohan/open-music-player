import 'dart:async';
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
      'artwork_kind': 'provider_thumbnail',
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
        defaultCrossfadeMs: 3000,
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
      expect(restored.session?.defaultCrossfadeMs, 3000);
    });

    test('legacy per-clip fade keys are tolerated and dropped on round-trip',
        () {
      const queue = [
        MediaItem(
          id: '1',
          title: 'Track 1',
          duration: Duration(seconds: 30),
          extras: {'url': 'https://audio.test/1.mp3'},
        ),
        MediaItem(
          id: '2',
          title: 'Track 2',
          duration: Duration(seconds: 30),
          extras: {'url': 'https://audio.test/2.mp3'},
        ),
      ];
      final session = MixSession.fromQueue(
        sessionId: 'legacy_clip_fades',
        queue: queue,
        defaultCrossfadeMs: 3000,
      );
      final snapshotJson = QueueSnapshot(
        tracks: [_track(1), _track(2)],
        session: session,
      ).toJson();
      final sessionJson = Map<String, dynamic>.from(
        snapshotJson['session']! as Map,
      );
      final clips = [
        for (final clip in sessionJson['clips']! as List)
          Map<String, dynamic>.from(clip as Map),
      ];
      for (final clip in clips) {
        clip['fadeInMs'] = 1250;
        clip['fadeOutMs'] = 1750;
      }
      sessionJson['clips'] = clips;
      snapshotJson['session'] = sessionJson;

      final restored = QueueSnapshot.fromJson(snapshotJson);
      final restoredClipsJson =
          (restored.toJson()['session'] as Map)['clips'] as List;
      final timeline = CueTimeline.fromSession(
        session: restored.session!,
        queue: queue,
        playOrder: const [0, 1],
      ).toTimelineModel();

      expect(restored.session?.clips.map((clip) => clip.trackId), ['1', '2']);
      for (final clip in restoredClipsJson.cast<Map>()) {
        expect(clip, isNot(contains('fadeInMs')));
        expect(clip, isNot(contains('fadeOutMs')));
      }
      expect(timeline.clips[0].envelope.fadeOutMs, 3000);
      expect(timeline.clips[1].envelope.fadeInMs, 3000);
    });

    test('schema v1 session without crossfade field restores as off', () {
      final sessionJson = MixSession.fromQueue(
        sessionId: 'legacy_session',
        queue: const [
          MediaItem(
            id: '1',
            title: 'Track 1',
            duration: Duration(seconds: 30),
          ),
        ],
      ).toJson()
        ..remove('defaultCrossfadeMs');

      final restored = QueueSnapshot.fromJson({
        'tracks': [_track(1)],
        'session': sessionJson,
      });

      expect(restored.session?.schemaVersion, 1);
      expect(restored.session?.defaultCrossfadeMs, 0);
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

  group('compact analysis override presence', () {
    test('preserves only explicitly empty or valid beat lists', () {
      final longBeats = [
        for (var beat = 0; beat < maxPersistedBeatPositions + 4; beat++) beat,
      ];
      final boundedBeats = [
        ...longBeats.take(maxPersistedBeatPositions ~/ 2),
        ...longBeats.skip(
          longBeats.length - (maxPersistedBeatPositions ~/ 2),
        ),
      ];
      final cases = <(String, Map<String, dynamic>, List<int>?)>[
        ('absent', const {}, null),
        (
          'null',
          const {
            'beat_grid': {'beats_ms': null},
          },
          null,
        ),
        (
          'malformed',
          const {
            'beat_grid': {'beats_ms': 'not-a-list'},
          },
          null,
        ),
        (
          'empty snake case',
          const {
            'beat_grid': {'beats_ms': <int>[]},
          },
          const [],
        ),
        (
          'empty camel case',
          const {
            'beatGrid': {'beatsMs': <int>[]},
          },
          const [],
        ),
        (
          'nonempty stays in input order',
          const {
            'beat_grid': {
              'beats_ms': [300, 100, 200],
            },
          },
          const [300, 100, 200],
        ),
        (
          'bounded stays in input order',
          {
            'beat_grid': {'beats_ms': longBeats},
          },
          boundedBeats,
        ),
      ];

      for (final (name, source, expected) in cases) {
        final compact = compactAnalysisOverrides(source)!;
        final beatGrid = compact['beat_grid'] as Map?;
        final actual = beatGrid?.containsKey('beats_ms') == true
            ? (beatGrid!['beats_ms'] as List).cast<int>()
            : null;
        expect(actual, expected, reason: name);
      }
    });

    test('preserves mapped and bare explicit downbeat clears', () {
      final longDownbeats = [
        for (var beat = 0; beat < maxPersistedDownbeatPositions + 4; beat++)
          beat,
      ];
      final boundedDownbeats = [
        ...longDownbeats.take(maxPersistedDownbeatPositions ~/ 2),
        ...longDownbeats.skip(
          longDownbeats.length - (maxPersistedDownbeatPositions ~/ 2),
        ),
      ];
      final cases = <(String, Map<String, dynamic>, List<int>?)>[
        ('absent', const {}, null),
        ('null', const {'downbeats': null}, null),
        ('malformed', const {'downbeats': 'not-a-list'}, null),
        (
          'malformed mapped positions',
          const {
            'downbeats': {'positions_ms': 'not-a-list'},
          },
          null,
        ),
        (
          'empty mapped snake case',
          const {
            'downbeats': {'positions_ms': <int>[]},
          },
          const [],
        ),
        (
          'empty mapped camel case',
          const {
            'downbeats': {'positionsMs': <int>[]},
          },
          const [],
        ),
        ('empty bare list', const {'downbeats': <int>[]}, const []),
        (
          'nonempty bare list stays in input order',
          const {
            'downbeats': [300, 100, 200],
          },
          const [300, 100, 200],
        ),
        (
          'bounded stays in input order',
          {
            'downbeats': {'positions_ms': longDownbeats},
          },
          boundedDownbeats,
        ),
      ];

      for (final (name, source, expected) in cases) {
        final compact = compactAnalysisOverrides(source)!;
        final downbeats = compact['downbeats'] as Map?;
        final actual = downbeats?.containsKey('positions_ms') == true
            ? (downbeats!['positions_ms'] as List).cast<int>()
            : null;
        expect(actual, expected, reason: name);
      }
    });

    test('summary compaction still omits explicit empty marker lists', () {
      expect(
        compactAnalysisSummary(const {
          'beat_grid': {'beats_ms': <int>[]},
          'downbeats': {'positions_ms': <int>[]},
        }),
        isNull,
      );
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
            'manual_timing_override': {
              'bpm': 130,
              'beat_anchor_ms': 120,
              'beats_per_bar': 4,
              'downbeat_phase_index': 3,
              'phrase_length_bars': 8,
              'revision': 9,
            },
          },
          'analysisUpdatedAt': '2026-07-10T11:00:00.123456Z',
          'artworkKind': 'provider_thumbnail',
          'analysisOverrideRevision': 9,
          'analysisOverrideUpdatedAt': '2026-07-10T11:00:00.123456Z',
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
      expect(json['artwork_kind'], 'provider_thumbnail');
      expect(json['artwork_kind'], 'provider_thumbnail');
      expect(json['analysisStatus'], 'analyzed');
      expect(json['analysisSummary'], {
        'bpm': {'value': 128},
      });
      expect(json['analysisOverrides'], {
        'manual_timing_v2': {
          'schema_version': 2,
          'bpm': 130,
          'beat_anchor_ms': 120,
          'beats_per_bar': 4,
          'downbeat_phase_index': 3,
          'phrase_length_bars': 8,
          'revision': 9,
        },
      });
      expect(
        json['analysisUpdatedAt'],
        '2026-07-10T11:00:00.123456Z',
      );
      expect(json['analysisOverrideRevision'], 9);
      expect(
        json['analysisOverrideUpdatedAt'],
        '2026-07-10T11:00:00.123456Z',
      );
      expect(json['analysisOverrideRevision'], 9);
      expect(
        json['analysisOverrideUpdatedAt'],
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
      expect(json['artwork_kind'], 'none');
    });

    test('normalizes inconsistent artwork provenance before persistence', () {
      final unknown = mediaItemToPlaybackJson(
        MediaItem(
          id: '42',
          title: 'Unknown provenance',
          artUri: Uri.parse('https://provider.example/42.jpg'),
          extras: const {'artworkKind': 'provider'},
        ),
      );
      final absent = mediaItemToPlaybackJson(
        const MediaItem(
          id: '43',
          title: 'Missing artwork',
          extras: {'artworkKind': 'provider_thumbnail'},
        ),
      );
      final explicitNone = mediaItemToPlaybackJson(
        MediaItem(
          id: '44',
          title: 'Explicit none',
          artUri: Uri.parse('https://provider.example/44.jpg'),
          extras: const {'artworkKind': 'none'},
        ),
      );
      final legacy = mediaItemToPlaybackJson(
        MediaItem(
          id: '45',
          title: 'Legacy cover',
          artUri: Uri.parse('https://legacy.example/45.jpg'),
        ),
      );

      expect(unknown['artwork_kind'], 'none');
      expect(unknown.containsKey('artwork_url'), isFalse);
      expect(absent['artwork_kind'], 'none');
      expect(absent.containsKey('artwork_url'), isFalse);
      expect(explicitNone['artwork_kind'], 'none');
      expect(explicitNone.containsKey('artwork_url'), isFalse);
      expect(legacy['artwork_kind'], 'cover_art');
      expect(legacy['artwork_url'], 'https://legacy.example/45.jpg');
    });

    test('50 hydrated tracks persist compact bounded tempo metadata', () {
      final hydrated = [
        for (var id = 1; id <= 50; id++)
          mediaItemToPlaybackJson(
            MediaItem(
              id: '$id',
              title: 'Track $id',
              duration: const Duration(minutes: 4),
              extras: {
                'analysisSummary': {
                  'bpm': {'value': 128, 'confidence': 0.99},
                  'beat_grid': {
                    'bpm': 128,
                    'offset_ms': 42,
                    'beats_ms': [for (var beat = 0; beat < 2000; beat++) beat],
                  },
                  'downbeats': {
                    'positions_ms': [
                      for (var beat = 0; beat < 500; beat++) beat * 4,
                    ],
                  },
                  'waveform': {
                    'peaks': List<double>.filled(65536, 0.5),
                    'rms': List<double>.filled(65536, 0.25),
                  },
                },
              },
            ),
          ),
      ];

      final encoded = QueueSnapshot(tracks: hydrated).encode();
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final tracks = (decoded['tracks'] as List).cast<Map>();

      expect(encoded.length, lessThan(160 * 1024));
      for (final track in tracks) {
        final summary = track['analysisSummary'] as Map;
        expect(summary, isNot(contains('waveform')));
        expect(
          (summary['beat_grid'] as Map)['beats_ms'],
          hasLength(maxPersistedBeatPositions),
        );
        expect(
          (summary['downbeats'] as Map)['positions_ms'],
          hasLength(maxPersistedDownbeatPositions),
        );
        expect((summary['beat_grid'] as Map)['beats_ms'].first, 0);
        expect((summary['beat_grid'] as Map)['beats_ms'].last, 1999);
        expect((summary['downbeats'] as Map)['positions_ms'].first, 0);
        expect((summary['downbeats'] as Map)['positions_ms'].last, 1996);
      }
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
      store.invalidateAccountId();
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

    test('account lookup is cached until auth change invalidates it', () async {
      SharedPreferences.setMockInitialValues({});
      var accountId = 'user-a';
      var providerCalls = 0;
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
        accountIdProvider: () async {
          providerCalls++;
          return accountId;
        },
      );
      final snapshot = QueueSnapshot(tracks: [_track(1)]);

      await store.save(snapshot);
      await store.save(snapshot);
      expect(providerCalls, 1);

      accountId = 'user-b';
      store.invalidateAccountId();
      await store.save(snapshot);

      expect(providerCalls, 2);
      expect((await store.load()).accountId, 'user-b');
      expect(providerCalls, 2);
    });

    test('saves stay ordered across an in-flight auth invalidation', () async {
      SharedPreferences.setMockInitialValues({});
      final lookups = <Completer<String?>>[];
      final store = QueuePersistenceStore(
        prefs: SharedPreferences.getInstance(),
        accountIdProvider: () {
          final lookup = Completer<String?>();
          lookups.add(lookup);
          return lookup.future;
        },
      );
      final staleSnapshot = QueueSnapshot(tracks: [_track(1)]);
      final currentSnapshot = QueueSnapshot(tracks: [_track(2)]);

      final staleSave = store.save(staleSnapshot);
      while (lookups.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      store.invalidateAccountId();
      final currentSave = store.save(currentSnapshot);
      lookups[0].complete('user-a');
      while (lookups.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      lookups[1].complete('user-b');
      await staleSave;
      await currentSave;

      final loaded = await store.load();
      expect(loaded.accountId, 'user-b');
      expect(loaded.tracks.single['id'], 2);
      expect(lookups, hasLength(2));
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
