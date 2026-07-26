import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:open_music_player/shared/widgets/track_artwork.dart';

void main() {
  testWidgets('none renders deterministic local placeholder', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TrackArtwork(
          url: null,
          kind: TrackArtworkKind.none,
          cacheKey: 'none',
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('track_artwork_placeholder_none')),
      findsOneWidget,
    );
    expect(find.byType(CachedNetworkImage), findsNothing);
  });

  testWidgets('provider uses URL-aware cache identity and truthful semantics', (
    tester,
  ) async {
    const url = 'https://provider.example/42.jpg';
    const cacheKey = '42:provider_thumbnail:$url';
    await tester.pumpWidget(
      const MaterialApp(
        home: TrackArtwork(
          url: url,
          kind: TrackArtworkKind.providerThumbnail,
          cacheKey: cacheKey,
        ),
      ),
    );

    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    expect(image.imageUrl, url);
    expect(image.cacheKey, cacheKey);
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byType(CachedNetworkImage),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(semantics.properties.label, 'Provider thumbnail');
  });

  testWidgets('image load error uses the same local placeholder', (
    tester,
  ) async {
    const cacheKey = '42:cover_art:https://covers.example/missing.jpg';
    await tester.pumpWidget(
      const MaterialApp(
        home: TrackArtwork(
          url: 'https://covers.example/missing.jpg',
          kind: TrackArtworkKind.coverArt,
          cacheKey: cacheKey,
        ),
      ),
    );
    final image = tester.widget<CachedNetworkImage>(
      find.byType(CachedNetworkImage),
    );
    final context = tester.element(find.byType(CachedNetworkImage));
    final fallback = image.errorWidget!(
      context,
      image.imageUrl,
      StateError('fixture load failure'),
    );

    await tester.pumpWidget(MaterialApp(home: fallback));
    expect(
      find.byKey(const ValueKey('track_artwork_placeholder_$cacheKey')),
      findsOneWidget,
    );
  });
}
