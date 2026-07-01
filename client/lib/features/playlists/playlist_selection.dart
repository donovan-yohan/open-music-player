/// Immutable value object tracking which playlist tracks are selected in the
/// playlist-detail multi-select ("batch remove") mode.
///
/// Kept free of Flutter dependencies so the selection-count logic is unit
/// testable without a widget harness.
class PlaylistSelection {
  final Set<int> selectedIds;

  const PlaylistSelection([this.selectedIds = const {}]);

  int get count => selectedIds.length;
  bool get isEmpty => selectedIds.isEmpty;
  bool get isNotEmpty => selectedIds.isNotEmpty;

  bool contains(int trackId) => selectedIds.contains(trackId);

  /// Returns a new selection with [trackId] added if absent, or removed if
  /// already present.
  PlaylistSelection toggle(int trackId) {
    final next = Set<int>.from(selectedIds);
    if (!next.add(trackId)) {
      next.remove(trackId);
    }
    return PlaylistSelection(next);
  }

  /// Selects every id in [trackIds] (union with the current selection).
  PlaylistSelection selectAll(Iterable<int> trackIds) {
    return PlaylistSelection({...selectedIds, ...trackIds});
  }

  PlaylistSelection clear() => const PlaylistSelection();

  /// Human label for the remove action, e.g. "Remove 1 track" /
  /// "Remove 3 tracks".
  String get removeLabel =>
      count == 1 ? 'Remove 1 track' : 'Remove $count tracks';
}
