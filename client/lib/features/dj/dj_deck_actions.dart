import 'package:flutter/material.dart';

import '../../models/track.dart';
import '../../shared/models/track.dart';
import 'models/dj_deck_state.dart';
import 'providers/dj_session_provider.dart';

/// Where a deck's download offer currently stands.
enum DjDeckDownloadPhase { idle, running, failed }

/// One deck's download offer, as the lane needs to render it.
@immutable
class DjDeckDownload {
  const DjDeckDownload({
    required this.phase,
    this.progress,
    this.available = true,
  });

  final DjDeckDownloadPhase phase;

  /// 0..1 while [phase] is running, else null.
  final double? progress;

  /// Whether this deck has a track the download pipeline can accept at all.
  ///
  /// A deck whose queue row moved out from under it, or whose row carries no
  /// numeric track id, has nothing to download. The lane then renders copy
  /// only: #414 asks for no dead controls, and an enabled button that silently
  /// does nothing is the worst of both.
  final bool available;

  static const DjDeckDownload idle =
      DjDeckDownload(phase: DjDeckDownloadPhase.idle);

  static const DjDeckDownload unavailable =
      DjDeckDownload(phase: DjDeckDownloadPhase.idle, available: false);

  static const DjDeckDownload failed =
      DjDeckDownload(phase: DjDeckDownloadPhase.failed);

  static DjDeckDownload running(double? progress) =>
      DjDeckDownload(phase: DjDeckDownloadPhase.running, progress: progress);
}

/// Screen-level seams the deck lane needs, carried down without threading
/// parameters through the waveform/painter widgets.
///
/// [DjDeckActions.maybeOf] returning null is a supported state: a widget test
/// that pumps a lane on its own gets copy with no action row, which is what
/// keeps the pre-existing lane tests honest rather than merely green.
class DjDeckActions extends InheritedWidget {
  const DjDeckActions({
    super.key,
    required this.onPickLocalFile,
    required this.onDownload,
    required this.downloadFor,
    required super.child,
    this.queueHasTracks = false,
  });

  /// Null means the screen offers no local-file affordance.
  ///
  /// Takes the deck the affordance was rendered for. The lane draws this action
  /// on whichever deck is empty, so a deck-less callback would load the picked
  /// file onto deck A from deck B's button — replacing whatever deck A was
  /// playing and leaving deck B empty (#414 review).
  final Future<void> Function(DjDeckId deck)? onPickLocalFile;

  /// Null means the screen offers no download affordance at all (for example,
  /// no `DownloadState` in the tree).
  final Future<void> Function(DjDeckId deck)? onDownload;

  final DjDeckDownload Function(DjDeckId deck) downloadFor;

  /// Whether the queue currently holds anything at all.
  ///
  /// An unseeded deck beside a full queue must not tell the user to add a track
  /// they have already added; the lane picks its copy on this fact. Defaults to
  /// false so a lane pumped without a queue keeps the empty-queue wording.
  final bool queueHasTracks;

  static DjDeckActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DjDeckActions>();

  @override
  bool updateShouldNotify(DjDeckActions old) => true;
}

/// The [Track] the deck hands to the download pipeline for [track].
///
/// There is no `QueueTrack -> Track` converter and no single-track library
/// fetch in this client, so the row is synthesised. `identityHash` uses the
/// `library-<id>` placeholder `Track.fromLibraryJson` already sanctions for
/// exactly this gap; the downloads store keys on the numeric `id`, and the
/// next real library row replaces this one wholesale.
///
/// Returns null when the queue row carries no numeric track id: the pipeline
/// keys on that id, so fabricating one would download the wrong thing.
Track? djDownloadTrackFor(QueueTrack track) {
  final ref = DjSessionProvider.djDeckTrackRef(track);
  final id = ref == null ? null : int.tryParse(ref);
  if (id == null) return null;
  final now = DateTime.now().toUtc();
  return Track(
    id: id,
    identityHash: 'library-$id',
    title: track.title,
    artist: track.artist,
    album: track.album,
    durationMs: track.durationMs,
    createdAt: now,
    updatedAt: now,
  );
}
