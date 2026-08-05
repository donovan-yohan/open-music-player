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
  const LikeToggleButton({
    super.key,
    required this.track,
    this.buttonKey,
    this.iconSize = 20,
  });

  final Track track;

  /// Key placed on the button itself, for surface-specific tests.
  final Key? buttonKey;

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    // Nullable lookup: liked state is an authenticated-session capability, so a
    // surface rendered without it shows no heart rather than crashing.
    final likedState = context.watch<LikedTracksState?>();
    if (likedState == null) return const SizedBox.shrink();

    final liked = likedState.isLiked(track.id) ?? track.isLiked ?? false;
    final busy = likedState.isToggling(track.id);

    return IconButton(
      key: buttonKey ?? ValueKey('like_toggle_${track.id}'),
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
    likedState.assume(track.id, track.isLiked ?? false);
    try {
      await likedState.toggle(track.id);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not update liked status')),
      );
    }
  }
}
