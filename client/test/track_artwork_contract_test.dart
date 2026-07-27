import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/track.dart';

void main() {
  test(
    'camelCase Home descriptor preserves provider provenance into playback',
    () {
      final track = Track.fromJson({
        'id': 42,
        'title': 'Provider visual',
        'artworkUrl': 'https://provider.example/42.jpg',
        'artworkKind': 'provider_thumbnail',
        'coverArtUrl': 'https://legacy.example/should-not-win.jpg',
      });

      expect(track.displayArtworkUrl, 'https://provider.example/42.jpg');
      expect(track.artworkKind, TrackArtworkKind.providerThumbnail);
      expect(track.artworkDescriptorPresent, isTrue);
      expect(track.coverArtUrl, isNull);
      expect(
        track.toPlaybackJson(),
        containsPair('artwork_url', 'https://provider.example/42.jpg'),
      );
      expect(
        track.toPlaybackJson()['artwork_kind'],
        TrackArtworkKind.providerThumbnail.wireValue,
      );
    },
  );

  test('snake_case Library descriptor matches Home for the same track', () {
    final home = Track.fromJson({
      'id': 42,
      'title': 'Parity',
      'artworkUrl': 'https://provider.example/42.jpg',
      'artworkKind': 'provider_thumbnail',
    });
    final library = Track.fromLibraryJson({
      'id': 42,
      'title': 'Parity',
      'added_at': '2026-07-26T00:00:00Z',
      'artwork_url': 'https://provider.example/42.jpg',
      'artwork_kind': 'provider_thumbnail',
    });

    expect(library.displayArtworkUrl, home.displayArtworkUrl);
    expect(library.artworkKind, home.artworkKind);
  });

  test('legacy flat cover fields remain readable without metadata folding', () {
    final camel = Track.fromJson({
      'id': 1,
      'title': 'Legacy Home',
      'coverArtUrl': 'https://covers.example/home.jpg',
    });
    final snake = Track.fromLibraryJson({
      'id': 2,
      'title': 'Legacy Library',
      'added_at': '2026-07-26T00:00:00Z',
      'cover_art_url': 'https://covers.example/library.jpg',
    });

    expect(camel.artworkKind, TrackArtworkKind.coverArt);
    expect(camel.artworkDescriptorPresent, isFalse);
    expect(camel.coverArtUrl, 'https://covers.example/home.jpg');
    expect(snake.artworkKind, TrackArtworkKind.coverArt);
    expect(snake.artworkDescriptorPresent, isFalse);
    expect(snake.coverArtUrl, 'https://covers.example/library.jpg');
  });

  test('release fallback survives missing descriptor and remains explicit', () {
    final track = Track.fromJson({
      'id': 7,
      'title': 'Release',
      'mbReleaseId': '11111111-1111-1111-1111-111111111111',
    });

    expect(track.artworkKind, TrackArtworkKind.releaseCover);
    expect(
      track.displayArtworkUrl,
      'https://coverartarchive.org/release/'
      '11111111-1111-1111-1111-111111111111/front-250',
    );
  });

  test(
    'invalid provider descriptors fail closed or reveal release fallback',
    () {
      for (final invalid in [
        '',
        'file:///tmp/cover.jpg',
        'data:image/png;base64,abc',
        'javascript:alert(1)',
        'https:///missing-host.jpg',
        'https://user:secret@example.test/cover.jpg',
      ]) {
        final none = Track.fromJson({
          'id': 9,
          'title': 'Unsafe',
          'artworkUrl': invalid,
          'artworkKind': 'provider_thumbnail',
        });
        expect(none.displayArtworkUrl, isNull, reason: invalid);
        expect(none.artworkKind, TrackArtworkKind.none, reason: invalid);

        final release = Track.fromJson({
          'id': 10,
          'title': 'Safe fallback',
          'mbReleaseId': '22222222-2222-2222-2222-222222222222',
          'artworkUrl': invalid,
          'artworkKind': 'provider_thumbnail',
        });
        expect(
          release.artworkKind,
          TrackArtworkKind.releaseCover,
          reason: invalid,
        );
      }
    },
  );

  test('unknown explicit provenance never becomes legacy cover art', () {
    final track = Track.fromJson({
      'id': 11,
      'title': 'Unknown kind',
      'artworkUrl': 'https://provider.example/11.jpg',
      'artworkKind': 'provider',
    });
    final direct = Track(
      id: 12,
      identityHash: 'track-12',
      title: 'Invalid provider',
      artworkUrl: 'file:///tmp/provider.jpg',
      artworkKind: TrackArtworkKind.providerThumbnail,
      metadata: const {
        'cover_art_url': 'https://legacy.example/should-not-be-provider.jpg',
      },
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    expect(track.displayArtworkUrl, isNull);
    expect(track.artworkKind, TrackArtworkKind.none);
    expect(direct.displayArtworkUrl, isNull);
    expect(direct.artworkKind, TrackArtworkKind.none);
  });

  test('authoritative none clears even when a legacy release can be derived',
      () {
    final track = Track.fromJson({
      'id': 13,
      'title': 'Cleared',
      'mbReleaseId': '33333333-3333-3333-3333-333333333333',
      'artworkKind': 'none',
    });

    expect(track.artworkDescriptorPresent, isTrue);
    expect(track.displayArtworkUrl, isNull);
    expect(track.artworkKind, TrackArtworkKind.none);
  });

  test('legacy JSON round-trip keeps descriptor absence', () {
    final legacy = Track.fromJson({
      'id': 14,
      'title': 'Legacy',
      'coverArtUrl': 'https://legacy.example/14.jpg',
    });
    final restored = Track.fromJson(legacy.toJson());

    expect(restored.artworkDescriptorPresent, isFalse);
    expect(restored.displayArtworkUrl, 'https://legacy.example/14.jpg');
    expect(restored.artworkKind, TrackArtworkKind.coverArt);
  });

  test('JSON and offline maps round-trip one URL and kind', () {
    final original = Track.fromLibraryJson({
      'id': 55,
      'title': 'Round trip',
      'added_at': '2026-07-26T00:00:00Z',
      'artwork_url': 'https://provider.example/55.jpg',
      'artwork_kind': 'provider_thumbnail',
    });

    final json = Track.fromJson(original.toJson());
    final offline = Track.fromDbMap(original.toDbMap());
    for (final restored in [json, offline]) {
      expect(restored.displayArtworkUrl, original.displayArtworkUrl);
      expect(restored.artworkKind, original.artworkKind);
      expect(restored.artworkDescriptorPresent, isTrue);
    }
  });
}
