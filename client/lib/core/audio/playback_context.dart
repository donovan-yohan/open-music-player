/// The kind of collection a listening session was launched from, so the player
/// can attribute playback with a "Playing from <label>" line.
enum PlaybackContextKind { playlist, album, artist, library, queue, search }

/// A small, reusable descriptor of where the current listening queue came from.
///
/// Attached to a [PlaybackState] when a whole collection is played (album,
/// playlist, ...) so the mini/full player can surface "Playing from <label>".
/// A context-less play clears it, so no stale attribution lingers.
class PlaybackContext {
  final PlaybackContextKind kind;
  final String label;
  final String? id;

  const PlaybackContext({
    required this.kind,
    required this.label,
    this.id,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaybackContext &&
      other.kind == kind &&
      other.label == label &&
      other.id == id;

  @override
  int get hashCode => Object.hash(kind, label, id);

  @override
  String toString() => 'PlaybackContext($kind, $label, $id)';
}
