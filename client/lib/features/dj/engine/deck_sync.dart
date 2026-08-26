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
