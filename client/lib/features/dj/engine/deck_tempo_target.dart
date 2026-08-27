/// Target-BPM resolution for the per-deck tempo sheet (#413, DJ-3).
///
/// A pure module, exactly like `deck_sync.dart`: no `Timer`, no `Voice`, no
/// `ChangeNotifier` and no Flutter import. It takes a [DjDeckState] snapshot and
/// a number the user typed, and returns either a playback rate to apply or an
/// honest refusal. `DjSessionProvider` is the only thing that applies it.
///
/// The deck **never clamps a typed tempo silently**. A tempo the deck cannot
/// reach is refused and the reachable band is named, because a clamp answers a
/// question the user did not ask and gives no sign that it did.
library;

import '../../../core/engine/tempo_automation.dart';
import '../models/dj_deck_state.dart';
import 'deck_controller.dart';

/// Field bounds. Outside this the input is not a dance-music tempo at all, and
/// refusing early keeps the refusal about the number rather than about the
/// deck's rate window.
const double kDjTempoFieldMinBpm = 50;
const double kDjTempoFieldMaxBpm = 200;

/// One tap of the fine steps.
const double kDjTempoFineStepBpm = 0.1;

/// Why a typed or stepped tempo could not be applied.
enum DjTempoTargetRefusal {
  /// The deck has no analysis, so it has no tempo to move.
  noTempo,

  /// No octave interpretation puts the deck's rate inside its own window.
  outOfReach,
}

/// The tempo band a deck can reach at its native octave.
///
/// Deliberately the **scale-1** band: it is the range the header's BPM readout
/// moves through as the pitch fader sweeps, so it is the range a user can
/// verify. Half- and double-time interpretations are reachable too (see
/// [djResolveTargetBpm]) but naming four bands in one helper line would obscure
/// the one that matters.
class DjTempoBand {
  const DjTempoBand({required this.minBpm, required this.maxBpm});

  final double minBpm;
  final double maxBpm;

  bool contains(double bpm) => bpm >= minBpm - 1e-9 && bpm <= maxBpm + 1e-9;
}

/// What [djResolveTargetBpm] decided.
class DjTempoTarget {
  const DjTempoTarget.resolved({
    required this.rate,
    required this.effectiveBpm,
    required this.tempoScale,
  }) : refusal = null;

  const DjTempoTarget.refused(this.refusal)
      : rate = 1,
        effectiveBpm = 0,
        tempoScale = 1;

  /// The playback rate to hand [DeckController.setRate].
  final double rate;

  /// What the deck header will read once [rate] is applied: `nativeBpm * rate`.
  /// Equal to the typed value at [tempoScale] 1, and to twice or half it at the
  /// other two.
  final double effectiveBpm;

  /// The octave interpretation this resolution used: 0.5, 1 or 2.
  final double tempoScale;

  final DjTempoTargetRefusal? refusal;

  bool get isResolved => refusal == null;

  /// True when the typed number was read as a half- or double-time statement of
  /// the same tempo. The sheet says so rather than letting the readout appear
  /// to contradict the input.
  bool get octaveShifted => isResolved && tempoScale != 1;
}

/// The deck's native BPM, through the one override interpreter
/// (`ClipTempoMetadata`, via [DjDeckState.bpm]). Null when it has no analysis.
double? djDeckNativeBpm(DjDeckState deck) {
  final bpm = deck.bpm;
  if (bpm == null || !bpm.isFinite || bpm <= 0) return null;
  return bpm;
}

/// What the deck's header reads right now: native BPM times the applied rate.
double? djDeckEffectiveBpm(DjDeckState deck) {
  final native = djDeckNativeBpm(deck);
  return native == null ? null : native * deck.rate;
}

/// The scale-1 reachable band, or null when the deck has no tempo.
DjTempoBand? djReachableBpmBand(DjDeckState deck) {
  final native = djDeckNativeBpm(deck);
  if (native == null) return null;
  return DjTempoBand(
    minBpm: native * kDjDeckMinRate,
    maxBpm: native * kDjDeckMaxRate,
  );
}

/// Resolves [targetBpm] into a rate this deck can actually hold.
///
/// The octave search is the shipped one's rule (`tempoOctaveScales`): the typed
/// number is tried against the deck's native tempo, then against half and
/// double it, and the interpretation needing the least rate adjustment wins.
/// Scale 1 always wins when it is reachable at all - the deck window is only
/// 0.75-1.25, so halving or doubling a rate already inside it always lands
/// further from 1 - so the other two scales are strictly a fallback for a user
/// who typed the half- or double-time reading of a tempo.
DjTempoTarget djResolveTargetBpm({
  required DjDeckState deck,
  required double targetBpm,
}) {
  final native = djDeckNativeBpm(deck);
  if (native == null) {
    return const DjTempoTarget.refused(DjTempoTargetRefusal.noTempo);
  }
  if (!targetBpm.isFinite ||
      targetBpm < kDjTempoFieldMinBpm - 1e-9 ||
      targetBpm > kDjTempoFieldMaxBpm + 1e-9) {
    return const DjTempoTarget.refused(DjTempoTargetRefusal.outOfReach);
  }

  DjTempoTarget? best;
  var bestAdjustment = double.infinity;
  for (final scale in tempoOctaveScales) {
    final interpreted = native * scale;
    if (!interpreted.isFinite || interpreted <= 0) continue;
    final rate = playbackRateForTargetBpm(
      baseRate: deck.rate,
      nativeBpm: interpreted,
      targetBpm: targetBpm,
    );
    // The shipped helper clamps to the engine's 0.5-2.0; the deck refuses
    // against its OWN 0.75-1.25 window, because a rate the pitch fader cannot
    // express is a tempo the user could never take back by hand.
    if (rate < kDjDeckMinRate - 1e-9 || rate > kDjDeckMaxRate + 1e-9) continue;
    final adjustment = (rate - 1).abs();
    if (adjustment >= bestAdjustment) continue;
    bestAdjustment = adjustment;
    best = DjTempoTarget.resolved(
      rate: rate,
      effectiveBpm: native * rate,
      tempoScale: scale,
    );
  }
  return best ?? const DjTempoTarget.refused(DjTempoTargetRefusal.outOfReach);
}

/// The BPM one fine step of [deltaBpm] from [deck]'s current effective tempo.
///
/// Steps the **target BPM**, not the rate, and rounds to one decimal on every
/// tap: stepping the rate accumulates float error, so ten `+0.1` taps from
/// 124.5 landed on 125.49999999999999 and the readout started disagreeing with
/// itself. Null when the deck has no tempo to step.
double? djSteppedTargetBpm(DjDeckState deck, double deltaBpm) {
  final effective = djDeckEffectiveBpm(deck);
  if (effective == null) return null;
  final next = double.parse((effective + deltaBpm).toStringAsFixed(1));
  return next.isFinite ? next : null;
}
