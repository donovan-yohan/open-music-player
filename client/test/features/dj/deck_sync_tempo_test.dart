import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/engine/deck_sync.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';

import '../../support/dj_sync_fixtures.dart';
import '../../support/fake_voice.dart';

/// #413 (DJ-3), slice 1: the tempo half of deck sync.
///
/// The numbers below are the exact output of the shipped octave search
/// (`resolveTempoTransitionBpmPair`, tempo_automation.dart:647), not
/// hand-derived ratios. They are pinned to six decimals so an "equivalent"
/// rewrite of the objective function cannot pass silently.
void main() {
  DeckController controller(FakeVoice voice) => DeckController.empty(
        deckId: DjDeckId.a,
        voice: voice,
        resolver: const DirectEngineAudioSourceResolver(),
      );

  group('DeckController.setRate reports what it did', () {
    test('an out-of-window request comes back marked as clamped', () async {
      final voice = FakeVoice('rate');
      final deck = controller(voice);

      final outcome = await deck.setRate(1.556);

      expect(outcome.clamped, isTrue);
      expect(outcome.requested, 1.556);
      expect(outcome.applied, kDjDeckMaxRate);
      expect(deck.state.rate, 1.25);
      expect(voice.speeds, [1.25]);
    });

    test('an in-window request is not marked as clamped', () async {
      final voice = FakeVoice('rate');
      final deck = controller(voice);

      final outcome = await deck.setRate(1.03);

      expect(outcome.clamped, isFalse);
      expect(outcome.applied, 1.03);
      expect(deck.state.rate, 1.03);
    });

    test('a backend without pitch shifting still plays, and says so', () async {
      final voice = FakeVoice('rate', pitchSupported: false);
      final deck = controller(voice);

      expect(deck.pitchSupported, isTrue);
      await deck.setRate(1.02);

      expect(deck.pitchSupported, isFalse);
      expect(deck.state.pitchSupported, isFalse);
      // The refusal is about key shift, never about playback: the rate landed.
      expect(voice.speeds, [1.02]);
      expect(deck.state.rate, 1.02);
    });
  });

  group('djSyncTempoMatch', () {
    DjSyncMatch match({
      required double leaderBpm,
      required double followerBpm,
      double leaderRate = 1,
      double? followerConfidence,
      bool overriddenFollower = false,
    }) =>
        djSyncTempoMatch(
          leader: djSyncDeckState(
            deckId: DjDeckId.b,
            id: '91',
            bpm: leaderBpm,
            rate: leaderRate,
          ),
          follower: djSyncDeckState(
            deckId: DjDeckId.a,
            id: '90',
            bpm: followerBpm,
            analysis: overriddenFollower
                ? djSyncOverriddenAnalysis(
                    generatedBpm: 124.5,
                    overrideBpm: followerBpm,
                  )
                : followerConfidence == null
                    ? null
                    : djSyncGeneratedAnalysis(
                        bpm: followerBpm,
                        confidence: followerConfidence,
                      ),
          ),
        );

    test('a near pair matches at the leader effective BPM', () {
      final result = match(leaderBpm: 128, followerBpm: 124);

      expect(result.isMatched, isTrue);
      expect(result.targetRate, closeTo(1.032258, 1e-6));
      expect(result.targetBpm, closeTo(128.0, 1e-6));
      expect(result.followerTempoScale, 1);
    });

    test('a half-tempo follower takes the octave, not an unreachable rate', () {
      final result = match(leaderBpm: 128, followerBpm: 64);

      expect(result.isMatched, isTrue);
      expect(result.followerTempoScale, 2);
      expect(result.targetRate, closeTo(1.0, 1e-6));
      expect(result.targetRate, inInclusiveRange(kDjDeckMinRate, kDjDeckMaxRate));
    });

    test('leader 140 over follower 90 matches, it does not refuse', () {
      // Issue #413's refusal criterion is arithmetically wrong: it quotes the
      // un-normalized 1.556 and contradicts its own octave criterion. The
      // shipped octave search picks scales 1 / 2 (140 against 180 BPM) and a
      // follower rate of 0.777778, which is inside the deck window. The
      // refusal case is pinned separately, below.
      final result = match(leaderBpm: 140, followerBpm: 90);

      expect(result.isMatched, isTrue);
      expect(result.followerTempoScale, 2);
      expect(result.targetRate, closeTo(0.777778, 1e-6));
    });

    test('a genuinely unreachable pair refuses instead of clamping', () {
      // 128 / 95 resolves to scales 1/1 and rate 1.347368. The deck window is
      // 0.737 octaves wide, so no octave shift can bring a ratio in
      // (1.25, 1.5) back inside it.
      final result = match(leaderBpm: 128, followerBpm: 95);

      expect(result.isMatched, isFalse);
      expect(result.refusal, DjSyncRefusal.tempoOutOfRange);
    });

    test('an unreliable follower tempo refuses by name', () {
      final result =
          match(leaderBpm: 128, followerBpm: 124, followerConfidence: 0.4);

      expect(result.refusal, DjSyncRefusal.followerTempoUnreliable);
    });

    test('an unloaded leader deck refuses by name', () {
      final result = djSyncTempoMatch(
        leader: const DjDeckState(deckId: DjDeckId.b),
        follower: djSyncDeckState(deckId: DjDeckId.a, bpm: 124.5),
      );

      expect(result.refusal, DjSyncRefusal.leaderNotLoaded);
    });

    test('a manual BPM override is the BPM sync matches', () {
      // Generated 124.5, overridden to 100, leader 124.5: 124.5 / 100 = 1.245.
      // Against the generated value the answer would have been 1.0.
      final result =
          match(leaderBpm: 124.5, followerBpm: 100, overriddenFollower: true);

      expect(result.isMatched, isTrue);
      expect(result.targetRate, closeTo(124.5 / 100, 1e-6));
      expect(result.targetRate, isNot(closeTo(1.0, 1e-3)));
    });
  });

  group('the leader is read-only', () {
    test('a refused press leaves the follower rate bit-identical', () async {
      final rig = djSyncRig();
      addTearDown(rig.session.dispose);
      await rig.session
          .load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
      await rig.session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 95));

      final before = rig.session.stateFor(DjDeckId.a).rate;
      final result = await rig.session.pressSync(DjDeckId.a);

      expect(result.refusal, DjSyncRefusal.tempoOutOfRange);
      expect(rig.session.stateFor(DjDeckId.a).rate, before);
      expect(rig.voiceFor(DjDeckId.a).speeds, isEmpty,
          reason: 'a refusal must not reach the voice at all');
      expect(rig.session.syncMaster, isNull);
      expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
    });

    test('twenty presses never touch the master deck', () async {
      final rig = djSyncRig();
      addTearDown(rig.session.dispose);
      await rig.session
          .load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
      await rig.session
          .load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));

      final leaderBefore = rig.session.stateFor(DjDeckId.b);
      for (var i = 0; i < 20; i++) {
        await rig.session.pressSync(DjDeckId.a);
      }
      final leaderAfter = rig.session.stateFor(DjDeckId.b);

      expect(leaderAfter.rate, leaderBefore.rate);
      expect(leaderAfter.pitchMode, pitchModePreserve);
      expect(leaderAfter.positionMs, leaderBefore.positionMs);
      expect(rig.voiceFor(DjDeckId.b).speeds, isEmpty,
          reason: 'issue #413 AC 8: sync never mutates the leader rate');
    });
  });
}
