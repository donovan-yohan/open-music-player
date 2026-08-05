import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/liked_tracks_state.dart';
import '../models/track.dart';

/// The shared like heart for any track row.
///
/// Every surface reads and writes the one [LikedTracksState], so a toggle on a
/// playlist row is visible on the player, the library and Liked Songs without
/// a refetch.
class LikeToggleButton extends StatelessWidget {
  LikeToggleButton({
    super.key,
    required Track track,
    this.buttonKey,
    this.iconSize = 20,
  })  : trackId = track.id,
        isLiked = track.isLiked;

  /// For surfaces that carry only a backend track id (e.g. playback queue
  /// rows, whose payloads are queue items rather than full track models).
  const LikeToggleButton.forId({
    super.key,
    required this.trackId,
    this.isLiked,
    this.buttonKey,
    this.iconSize = 20,
  });

  final int trackId;

  /// The payload's `is_liked` annotation; null when the source payload did not
  /// carry one (only the library listing annotates it).
  final bool? isLiked;

  /// Key placed on the button itself, for surface-specific tests.
  final Key? buttonKey;

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    // Nullable lookup: liked state is an authenticated-session capability, so a
    // surface rendered without it shows no heart rather than crashing.
    final likedState = context.watch<LikedTracksState?>();
    if (likedState == null) return const SizedBox.shrink();

    final liked = likedState.isLiked(trackId) ?? isLiked ?? false;
    final busy = likedState.isToggling(trackId);

    return IconButton(
      key: buttonKey ?? ValueKey('like_toggle_$trackId'),
      iconSize: iconSize,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        liked ? Icons.favorite : Icons.favorite_border,
        color: liked ? Theme.of(context).colorScheme.primary : null,
      ),
      tooltip: liked ? 'Unlike' : 'Like',
      onPressed: busy ? null : () => _toggle(context, likedState),
    );
  }

  Future<void> _toggle(
    BuildContext context,
    LikedTracksState likedState,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    // Only the library listing annotates `is_liked`, so a row reached from a
    // playlist / home / downloads payload can have no known value yet. Seed the
    // value the heart is already showing before flipping it, otherwise the
    // toggle would reject an unknown track.
    likedState.assume(trackId, isLiked ?? false);
    try {
      await likedState.toggle(trackId);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not update liked status')),
      );
    }
  }
}
