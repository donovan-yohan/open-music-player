import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/track.dart';

/// Shared cached renderer for the effective artwork descriptor.
///
/// URL loading failure and `none` both use the same deterministic local
/// placeholder. [kind] remains available to semantics and callers, so a
/// provider thumbnail is never described as verified album art.
class TrackArtwork extends StatelessWidget {
  const TrackArtwork({
    super.key,
    required this.url,
    required this.kind,
    this.width = 48,
    this.height = 48,
    this.fit = BoxFit.cover,
    this.borderRadius = const BorderRadius.all(Radius.circular(4)),
    this.cacheKey,
  });

  factory TrackArtwork.fromTrack(
    Track track, {
    Key? key,
    double? width = 48,
    double? height = 48,
    BoxFit fit = BoxFit.cover,
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(4)),
  }) {
    return TrackArtwork(
      key: key,
      url: track.displayArtworkUrl,
      kind: track.artworkKind,
      width: width,
      height: height,
      fit: fit,
      borderRadius: borderRadius,
      cacheKey:
          '${track.id}:${track.artworkKind.wireValue}:${track.displayArtworkUrl ?? "none"}',
    );
  }

  final String? url;
  final TrackArtworkKind kind;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius borderRadius;
  final String? cacheKey;

  @override
  Widget build(BuildContext context) {
    final imageURL = safeTrackArtworkUrl(url);
    final placeholder = _ArtworkPlaceholder(
      width: width,
      height: height,
      cacheKey: cacheKey,
    );
    if (imageURL == null || imageURL.isEmpty || kind == TrackArtworkKind.none) {
      return placeholder;
    }

    final semanticsLabel = kind == TrackArtworkKind.providerThumbnail
        ? 'Provider thumbnail'
        : 'Track artwork';
    return Semantics(
      image: true,
      label: semanticsLabel,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: CachedNetworkImage(
          key: ValueKey('track_artwork_image_$cacheKey'),
          imageUrl: imageURL,
          cacheKey: cacheKey,
          width: width,
          height: height,
          fit: fit,
          memCacheWidth: _cacheDimension(width),
          memCacheHeight: _cacheDimension(height),
          placeholder: (_, __) => placeholder,
          errorWidget: (_, __, ___) => placeholder,
        ),
      ),
    );
  }
}

int? _cacheDimension(double? logicalPixels) {
  if (logicalPixels == null || !logicalPixels.isFinite || logicalPixels <= 0) {
    return null;
  }
  return (logicalPixels * 2).round();
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder({
    required this.width,
    required this.height,
    required this.cacheKey,
  });

  final double? width;
  final double? height;
  final String? cacheKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('track_artwork_placeholder_$cacheKey'),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(Icons.music_note, color: colors.outline),
    );
  }
}
