/// The single declaration of the stem mixer contract shared by every stem
/// surface (DJ deck panel, timeline automation editor, authoring stub).
///
/// The DJ deck lane and the stems lane each grew a byte-identical copy of
/// [StemChannel] / [StemChannelSource]; this file is the merge point. It is
/// deliberately dependency-free — no Flutter widgets, no audio engine, no
/// HTTP — so both a pure authoring adapter and a live API-backed adapter can
/// implement it without dragging one lane's dependencies into the other.
///
/// Nothing here owns playback. Per-stem audible mixing is ADR 0006 Rung B and
/// is not wired: an implementation reports [StemChannelSource.isAvailable] for
/// *the mixer surface being meaningful*, and callers must still render the
/// honest "preview mix not yet audible" copy.
library;

/// Availability of rendered stems for a track, as reported by the backend.
///
/// This is the client-side collapse of the durable `track_stems.status`
/// values. The backend distinguishes `pending` (row created, job queued) from
/// `separating` (worker leased the job); both are "work is in flight" to a UI,
/// so they fold into [pending]. `stale` — artifacts invalidated by a
/// re-download — folds into [unavailable] because the honest next action is
/// the same: ask for separation again.
enum StemsStatus {
  /// Separation has not been requested, the row is stale, or the channel set
  /// is not audio-addressable.
  unavailable,

  /// Separation is queued or running (backend `pending` or `separating`).
  pending,

  /// Stems exist and the manifest lists their objects.
  ready,

  /// Separation or render failed.
  failed,
}

/// Parses a durable `track_stems.status` wire value into a [StemsStatus].
///
/// Unknown values map to [StemsStatus.unavailable] rather than throwing: a
/// newer backend status must degrade to "offer separation" instead of
/// crashing a deck.
StemsStatus stemsStatusFromWire(String? wire) => switch (wire?.trim()) {
      'pending' || 'separating' => StemsStatus.pending,
      'ready' => StemsStatus.ready,
      'failed' => StemsStatus.failed,
      _ => StemsStatus.unavailable,
    };

/// One mixer channel exposed to a deck or automation surface.
class StemChannel {
  const StemChannel({
    required this.id,
    required this.label,
    required this.gain,
    required this.muted,
    this.honestyCopy = '',
  });

  /// Canonical wire name, e.g. `perc`.
  final String id;

  /// Display label, e.g. `Kick (low drums)`.
  final String label;

  /// Linear gain in `[0, 1]`.
  final double gain;

  final bool muted;

  /// ADR 0006 honesty line for this channel. Empty when the implementation has
  /// no descriptor to quote (e.g. a manifest channel outside the known set).
  final String honestyCopy;
}

/// Narrow adapter over the stems5-hybrid-v1 contract.
///
/// Implementations range from [UnavailableStemChannelSource] (no stems at all)
/// through an authoring-only document adapter to a live API-backed source.
abstract class StemChannelSource {
  bool get isAvailable;
  bool get isPending;
  List<StemChannel> get channels;
  Future<void> setGain(String id, double gain);
  Future<void> setMute(String id, bool muted);
}

/// Honest empty source for tracks with no stems at all.
class UnavailableStemChannelSource implements StemChannelSource {
  const UnavailableStemChannelSource({this.isPending = false});

  @override
  final bool isPending;
  @override
  bool get isAvailable => false;
  @override
  List<StemChannel> get channels => const [];
  @override
  Future<void> setGain(String id, double gain) async {}
  @override
  Future<void> setMute(String id, bool muted) async {}
}
