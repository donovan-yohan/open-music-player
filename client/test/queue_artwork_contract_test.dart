import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/shared/models/track.dart'
    show TrackArtworkKind;
import 'package:open_music_player/shared/widgets/track_artwork.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';
import 'package:open_music_player/widgets/queue_item.dart';

void main() {
  test('playback queue projection retains URL and provider kind', () {
    final track = playbackTrackForMediaItem(
      MediaItem(
        id: '42',
        title: 'Provider',
        artUri: Uri.parse('https://provider.example/42.jpg'),
        extras: const {'artworkKind': 'provider_thumbnail'},
      ),
      queueItemId: 'queue-42',
    );

    expect(track.artworkUrl, 'https://provider.example/42.jpg');
    expect(track.artworkKind, TrackArtworkKind.providerThumbnail);
    expect(track.toPlaybackJson()['artwork_kind'], 'provider_thumbnail');
  });

  test('playback queue projection fails closed but reads legacy cover', () {
    final unknown = playbackTrackForMediaItem(
      MediaItem(
        id: '43',
        title: 'Unknown',
        artUri: Uri.parse('https://provider.example/43.jpg'),
        extras: const {'artworkKind': 'provider'},
      ),
      queueItemId: 'queue-43',
    );
    final legacy = playbackTrackForMediaItem(
      MediaItem(
        id: '44',
        title: 'Legacy',
        artUri: Uri.parse('https://legacy.example/44.jpg'),
      ),
      queueItemId: 'queue-44',
    );

    expect(unknown.artworkUrl, isNull);
    expect(unknown.artworkKind, TrackArtworkKind.none);
    expect(legacy.artworkUrl, 'https://legacy.example/44.jpg');
    expect(legacy.artworkKind, TrackArtworkKind.coverArt);
  });

  testWidgets('QueueItem uses shared cached artwork with error fallback', (
    tester,
  ) async {
    final track = QueueTrack(
      id: 'queue-45',
      title: 'Provider',
      duration: 100,
      artworkUrl: 'https://provider.example/45.jpg',
      artworkKind: TrackArtworkKind.providerThumbnail,
      addedAt: DateTime.utc(2026),
    );

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QueueItem(track: track))),
    );

    expect(find.byType(TrackArtwork), findsOneWidget);
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, 'https://provider.example/45.jpg');
    expect(image.errorWidget, isNotNull);
  });

  testWidgets('legacy TrackTile URL infers cover while explicit none clears', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Legacy',
            duration: '1:00',
            coverArtUrl: 'https://legacy.example/cover.jpg',
          ),
        ),
      ),
    );
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Cleared',
            duration: '1:00',
            coverArtUrl: 'https://legacy.example/cover.jpg',
            artworkKind: TrackArtworkKind.none,
          ),
        ),
      ),
    );
    expect(find.byType(CachedNetworkImage), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Unsafe legacy',
            duration: '1:00',
            coverArtUrl: 'file:///tmp/cover.jpg',
          ),
        ),
      ),
    );
    expect(find.byType(CachedNetworkImage), findsNothing);
  });
}
