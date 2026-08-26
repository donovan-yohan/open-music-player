/// Deck sync, as a pure function of two deck snapshots (#413, DJ-3).
///
/// Deliberately holds no `Timer`, no `Voice`, no `ChangeNotifier` and no
/// Flutter import: it takes [DjDeckState] snapshots in and returns an intent
/// out, so the tempo maths is reviewable and testable without the session
/// wiring that applies it. `DjSessionProvider` owns master/follower state and
/// is the only thing that ever calls `DeckController.setRate` with the result.
///
/// This is the module `docs/dj-deck-spec.md` reserves as `engine/deck_sync.dart`.
library;

import '../../../core/engine/tempo_automation.dart';
import '../../../models/track_analysis.dart';
import '../models/dj_beat_grid.dart';
import '../models/dj_deck_state.dart';
import 'deck_controller.dart';

/// Why a sync press could not be honoured, in the user's terms.
///
/// Every value maps to one sentence-case reason string; see
/// `djDeckSyncReasonFor` in `widgets/dj_transport.dart`.
enum DjSyncRefusal {
  /// Defensive: a deck was asked to follow itself.
  noLeader,
  leaderNotLoaded,
  followerNotLoaded,
  leaderTempoUnreliable,
  followerTempoUnreliable,
  tempoOutOfRange,
}

/// The intent [djSyncTempoMatch] produced: either a follower rate to apply, or
/// a refusal to render.
class DjSyncMatch {
  const DjSyncMatch.matched({
    required this.targetRate,
    required this.targetBpm,
    required this.followerTempoScale,
  }) : refusal = null;

  const DjSyncMatch.refused(this.refusal)
      : targetRate = 1,
        targetBpm = 0,
        followerTempoScale = 1;

  /// The follower playback rate that lines its pulse up with the leader's.
  final double targetRate;

  /// The follower's effective BPM once [targetRate] is applied. Equal to the
  /// leader's effective BPM by construction, up to the octave interpretation.
  final double targetBpm;

  /// The octave interpretation chosen for the follower: 0.5, 1 or 2.
  final double followerTempoScale;

  final DjSyncRefusal? refusal;

  bool get isMatched => refusal == null;
}

/// Octave-normalized tempo match of [follower] against [leader].
///
/// [leader] is strictly read-only: nothing this returns can be applied to it,
/// and the session never calls `setRate` on the master (issue #413, AC 8).
///
/// The octave search is the shipped one (`resolveTempoTransitionBpmPair`,
/// tempo_automation.dart:647), so a 64 BPM follower matched to a 128 BPM leader
/// picks the 2x interpretation and lands at rate 1.0 rather than an unreachable
/// 2.0. The reachability test is against the *deck's* window
/// ([kDjDeckMinRate] .. [kDjDeckMaxRate]), never the engine's wider 0.5-2.0:
/// a follower settled outside the pitch fader's range is a tempo the user
/// cannot then take back by hand.
///
/// Gated on `hasReliableBpm` only. Phase work is gated on
/// `hasReliableBeatGrid` separately; requiring the grid here would disable the
/// tempo match on roughly two thirds of the dogfood library for no benefit,
/// because a tempo match needs a trustworthy BPM and nothing else.
DjSyncMatch djSyncTempoMatch({
  required DjDeckState leader,
  required DjDeckState follower,
}) {
  if (leader.deckId == follower.deckId) {
    return const DjSyncMatch.refused(DjSyncRefusal.noLeader);
  }
  if (!leader.isLoaded) {
    return const DjSyncMatch.refused(DjSyncRefusal.leaderNotLoaded);
  }
  if (!follower.isLoaded) {
    return const DjSyncMatch.refused(DjSyncRefusal.followerNotLoaded);
  }

  final leaderAnalysis = leader.queueTrack?.analysis;
  if (leaderAnalysis == null) {
    return const DjSyncMatch.refused(DjSyncRefusal.leaderTempoUnreliable);
  }
  final followerAnalysis = follower.queueTrack?.analysis;
  if (followerAnalysis == null) {
    return const DjSyncMatch.refused(DjSyncRefusal.followerTempoUnreliable);
  }

  // ClipTempoMetadata is the only timing-override interpreter on the client, so
  // an overridden BPM is the BPM sync matches. Never merge overrides here.
  final leaderTempo = ClipTempoMetadata.fromTrackAnalysis(leaderAnalysis);
  final followerTempo = ClipTempoMetadata.fromTrackAnalysis(followerAnalysis);
  if (!leaderTempo.hasReliableBpm) {
    return const DjSyncMatch.refused(DjSyncRefusal.leaderTempoUnreliable);
  }
  if (!followerTempo.hasReliableBpm) {
    return const DjSyncMatch.refused(DjSyncRefusal.followerTempoUnreliable);
  }

  final pair = resolveTempoTransitionBpmPair(
    outgoingTempo: leaderTempo,
    incomingTempo: followerTempo,
    outgoingBaseRate: leader.rate,
    incomingBaseRate: 1,
  );
  if (pair == null) {
    return const DjSyncMatch.refused(DjSyncRefusal.tempoOutOfRange);
  }

  final targetRate = pair.outgoingBpm * leader.rate / pair.incomingBpm;
  if (!targetRate.isFinite ||
      targetRate < kDjDeckMinRate - 1e-9 ||
      targetRate > kDjDeckMaxRate + 1e-9) {
    return const DjSyncMatch.refused(DjSyncRefusal.tempoOutOfRange);
  }

  return DjSyncMatch.matched(
    targetRate: targetRate,
    targetBpm: pair.incomingBpm * targetRate,
    followerTempoScale: pair.incomingTempoScale,
  );
}

// ---------------------------------------------------------------------------
// Beat-level alignment (#413, DJ-3, slice 2)
// ---------------------------------------------------------------------------

/// Largest rate offset the correction may add on top of the matched base rate.
///
/// docs/dj-deck-spec.md:312 fixes the correction at +/-1-2% extra rate. It is
/// not a knob: a wider cap closes a half-beat error faster but makes the
/// follower audibly wobble, which is the thing a synced deck must never do.
const double kDjSyncMaxRateOffset = 0.02;

/// Dimensionless proportional term. The loop is deliberately P-only: there is
/// no integrator to wind up while the cap is saturated, and no derivative term
/// to amplify the +/-30-80ms position jitter the just_audio/ExoPlayer clock
/// already has (docs/dj-deck-spec.md:312).
const double kDjSyncPhaseGain = 0.5;

/// Below this the decks are as aligned as the platform can report.
///
/// Achievable holding is +/-30-80ms (docs/dj-deck-spec.md:312), so a 1ms
/// deadband would chase reporting noise with real rate commands forever.
const double kDjSyncPhaseDeadbandMs = 10;

/// Minimum wall gap between two rate commands to one deck.
///
/// `setSpeed` itself takes 100-200ms to settle (docs/dj-deck-spec.md:320), so a
/// 30Hz command stream would only ever measure its own transient.
const int kDjSyncCorrectionIntervalMs = 250;

/// Two offsets closer than this are the same command; re-issuing costs a
/// settle transient and buys nothing.
const double kDjSyncRateEpsilon = 0.002;

/// A follower's beat-level alignment against its leader, at one instant.
class DjSyncPhaseReading {
  const DjSyncPhaseReading({required this.errorMs, required this.pulseMs});

  /// Wall-clock error in `(-pulseMs / 2, +pulseMs / 2]`. Positive means the
  /// follower's beat sounded earlier than the leader's, i.e. it is ahead.
  final double errorMs;

  /// The shared pulse the error was reduced into: the shorter of the two decks'
  /// wall beat periods.
  final double pulseMs;
}

class _DeckPulse {
  const _DeckPulse({required this.sinceBeatWallMs, required this.periodWallMs});
  final double sinceBeatWallMs;
  final double periodWallMs;
}

/// Wall-time position of [deck] inside its current beat, or null when it has no
/// usable beat interval there.
///
/// The interval comes from the grid itself rather than `60000 / bpm`: the
/// effective grid is allowed to breathe, and a deck with a trustworthy grid but
/// no trustworthy BPM still has a pulse to align to.
_DeckPulse? _deckPulse(DjDeckState deck) {
  final beats = deck.beatsMs;
  final index = djLastBeatIndexAtOrBefore(beats, deck.positionMs);
  if (index < 0 || index >= beats.length - 1) return null;
  final interval = beats[index + 1] - beats[index];
  if (interval <= 0) return null;
  final rate = deck.rate;
  if (!rate.isFinite || rate <= 0) return null;
  return _DeckPulse(
    sinceBeatWallMs: (deck.positionMs - beats[index]) / rate,
    periodWallMs: interval / rate,
  );
}

/// Beat-level alignment of [follower] against [leader], in WALL milliseconds.
///
/// Null when either deck has no usable beat interval at its current position.
///
/// Compared in wall time modulo the SHORTER of the two wall beat periods. Under
/// octave normalization the two grids tick at different rates - a 64 BPM
/// follower matched to a 128 BPM leader has beats twice as far apart - so
/// equating beat fractions is unsatisfiable and would report a full 469ms error
/// for a deck that is 234ms out. See docs/dj-deck-spec.md:365: beat level only,
/// never bar level, until downbeat authority is trustworthy.
DjSyncPhaseReading? djSyncPhaseReading({
  required DjDeckState leader,
  required DjDeckState follower,
}) {
  final leaderPulse = _deckPulse(leader);
  final followerPulse = _deckPulse(follower);
  if (leaderPulse == null || followerPulse == null) return null;
  final pulseMs = leaderPulse.periodWallMs < followerPulse.periodWallMs
      ? leaderPulse.periodWallMs
      : followerPulse.periodWallMs;
  if (!pulseMs.isFinite || pulseMs <= 0) return null;
  final raw = followerPulse.sinceBeatWallMs - leaderPulse.sinceBeatWallMs;
  // Reduce into (-P/2, +P/2] and take the shorter way round: a deck 234ms late
  // against a 469ms pulse is corrected forwards by 234ms, never backwards by
  // 235ms. `round()` would send an exact +P/2 to -P/2 and reopen that choice.
  final wrapped = raw - pulseMs * ((raw / pulseMs) - 0.5).ceil();
  return DjSyncPhaseReading(errorMs: wrapped, pulseMs: pulseMs);
}

/// [DjSyncPhaseReading.errorMs] alone, for callers that only need the signal.
double? djSyncPhaseErrorMs({
  required DjDeckState leader,
  required DjDeckState follower,
}) =>
    djSyncPhaseReading(leader: leader, follower: follower)?.errorMs;

/// Memoises the grid verdict per analysis object, the way `DjBeatRuler` does.
///
/// `hasReliableBeatGrid` walks the whole marker array and takes a median of its
/// intervals (tempo_automation.dart:99-112). The correction asks this question
/// on every 33ms pass for both decks, and the answer cannot change without the
/// analysis object itself being replaced, so re-deriving it 60 times a second
/// is pure waste. Weak keys, so a superseded snapshot is collected with its
/// verdict and no eviction policy is needed.
final Expando<bool> _reliableGridByAnalysis =
    Expando<bool>('djSyncReliableBeatGrid');

bool _hasReliableGrid(TrackAnalysis? analysis) {
  if (analysis == null) return false;
  final cached = _reliableGridByAnalysis[analysis];
  if (cached != null) return cached;
  return _reliableGridByAnalysis[analysis] =
      ClipTempoMetadata.fromTrackAnalysis(analysis).hasReliableBeatGrid;
}

/// Whether beat-level correction may act on this pair at all.
///
/// The tempo match is gated on `hasReliableBpm` (see [djSyncTempoMatch]); this
/// work needs the grid itself to be trustworthy on BOTH decks, because a
/// correction computed against a wrong grid pushes a deck away from the beat
/// rather than towards it (docs/dj-deck-spec.md:365).
bool djSyncPhaseCorrectionAllowed({
  required DjDeckState leader,
  required DjDeckState follower,
}) =>
    _hasReliableGrid(leader.queueTrack?.analysis) &&
    _hasReliableGrid(follower.queueTrack?.analysis);

/// The correction cap available on top of [baseRate].
///
/// [kDjSyncMaxRateOffset] shrinks into whatever headroom the deck window still
/// has rather than becoming a new refusal: a follower matched at 1.24 gets
/// 0.806% of correction instead of being told its tempo is unreachable after it
/// has already been matched. Zero when [baseRate] is already at a bound.
double djSyncCorrectionCap(double baseRate) {
  if (!baseRate.isFinite || baseRate <= 0) return 0;
  var cap = kDjSyncMaxRateOffset;
  final headroomUp = kDjDeckMaxRate / baseRate - 1;
  final headroomDown = 1 - kDjDeckMinRate / baseRate;
  if (headroomUp < cap) cap = headroomUp;
  if (headroomDown < cap) cap = headroomDown;
  return cap <= 0 ? 0 : cap;
}

/// The capped proportional rate offset for [errorMs] against [pulseMs].
///
/// Sign: a follower that is ahead ([errorMs] positive) is slowed. The closed
/// loop is `de/dt = offset` in wall ms per wall ms, so the cap is also the
/// honest convergence rate: a half-beat error at 128 BPM is 234ms and closes in
/// about 11.7s at 2%.
double djSyncRateOffset({
  required double errorMs,
  required double pulseMs,
  required double baseRate,
}) {
  if (!errorMs.isFinite || errorMs.abs() < kDjSyncPhaseDeadbandMs) return 0;
  if (!pulseMs.isFinite || pulseMs <= 0) return 0;
  final cap = djSyncCorrectionCap(baseRate);
  if (cap <= 0) return 0;
  return (-kDjSyncPhaseGain * errorMs / pulseMs).clamp(-cap, cap).toDouble();
}
