import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/engine/deck_sync.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';

import '../../support/dj_sync_fixtures.dart';

/// #413 (DJ-3) D3: master/follower is session state with an exact tap table.
///
/// Deck A is the 124.5 BPM fixture and deck B the 128 BPM one, matching
/// `dj_viewport_fixtures.dart`'s loaded pair, so the numbers here are the same
/// ones the widget and emulator evidence show.
void main() {
  Future<DjSyncRig> loadedRig({
    double deckABpm = 124.5,
    double deckBBpm = 128,
  }) async {
    final rig = djSyncRig();
    addTearDown(rig.session.dispose);
    await rig.session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: deckABpm));
    await rig.session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: deckBBpm));
    return rig;
  }

  test('the first press makes the other deck the master', () async {
    final rig = await loadedRig();

    final result = await rig.session.pressSync(DjDeckId.a);

    expect(result.isMatched, isTrue);
    expect(rig.session.syncMaster, DjDeckId.b);
    expect(rig.session.isSyncMaster(DjDeckId.b), isTrue);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
    expect(rig.session.syncEngagedOn(DjDeckId.b), isFalse);
    expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(1.028112, 1e-6));
    expect(rig.session.stateFor(DjDeckId.b).rate, 1.0);
  });

  test('pressing the master swaps master without moving a tempo', () async {
    final rig = await loadedRig();
    await rig.session.pressSync(DjDeckId.a);
    final deckBRateBefore = rig.session.stateFor(DjDeckId.b).rate;

    await rig.session.pressSync(DjDeckId.b);

    expect(rig.session.syncMaster, DjDeckId.a);
    expect(rig.session.syncEngagedOn(DjDeckId.b), isTrue);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
    // The master-swap invariant: both decks are already at the same effective
    // BPM, so the new follower's target is the rate it already holds.
    expect(
      (rig.session.stateFor(DjDeckId.b).rate - deckBRateBefore).abs(),
      lessThanOrEqualTo(1e-9),
    );
  });

  test('pressing an engaged follower disengages it at its current rate',
      () async {
    final rig = await loadedRig();
    await rig.session.pressSync(DjDeckId.a);
    final rateWhileEngaged = rig.session.stateFor(DjDeckId.a).rate;

    await rig.session.pressSync(DjDeckId.a);

    expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
    expect(rig.session.syncMaster, DjDeckId.b,
        reason: 'disengaging a follower does not depose the master');
    expect(rig.session.stateFor(DjDeckId.a).rate, rateWhileEngaged,
        reason: 'snapping back to 1.0 would be an audible jump mid-blend');
  });

  test('a manual pitch move disengages sync, a nudge does not', () async {
    final rig = await loadedRig();
    await rig.session.pressSync(DjDeckId.a);

    await rig.session.nudgePitchStart(DjDeckId.a, 2);
    await rig.session.nudgePitchEnd(DjDeckId.a);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue,
        reason: 'a bend restores the base rate, exactly like a correction');
    // The restore is the half that matters: this is the one seam where the
    // sync flag and the real rate can silently disagree, and a deck left 2%
    // fast while its glyph still reads "matched" is audible drift under a UI
    // that claims otherwise. Pin it in state and at the voice.
    const matchedRate = 128 / 124.5;
    expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(matchedRate, 1e-9));
    expect(rig.voiceFor(DjDeckId.a).speeds.last, closeTo(matchedRate, 1e-9));

    await rig.session.setPitchPercent(DjDeckId.a, 3);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
    expect(rig.session.syncMaster, DjDeckId.b);
  });

  test('a refusal moves nothing at all', () async {
    final rig = await loadedRig(deckABpm: 95, deckBBpm: 128);
    final rateA = rig.session.stateFor(DjDeckId.a).rate;
    final rateB = rig.session.stateFor(DjDeckId.b).rate;

    final result = await rig.session.pressSync(DjDeckId.a);

    expect(result.refusal, DjSyncRefusal.tempoOutOfRange);
    expect(rig.session.syncMaster, isNull);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
    expect(rig.session.stateFor(DjDeckId.a).rate, rateA);
    expect(rig.session.stateFor(DjDeckId.b).rate, rateB);
  });

  test('with one deck loaded the would-be leader is the empty one', () async {
    final rig = djSyncRig();
    addTearDown(rig.session.dispose);
    await rig.session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));

    expect(
      rig.session.syncMatchFor(DjDeckId.a).refusal,
      DjSyncRefusal.leaderNotLoaded,
    );
    expect(
      rig.session.syncMatchFor(DjDeckId.b).refusal,
      DjSyncRefusal.followerNotLoaded,
      reason: 'the empty deck is the one that cannot be made to follow',
    );
  });

  test('loading over an engaged deck releases its sync role', () async {
    final rig = await loadedRig();
    await rig.session.pressSync(DjDeckId.a);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);

    await rig.session.load(DjDeckId.b, djSyncDeckSeed(id: '92', bpm: 128));

    expect(rig.session.syncMaster, isNull,
        reason: 'the master deck was replaced, so nothing leads any more');
    expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
  });

  test('stopAll clears the sync roles', () async {
    final rig = await loadedRig();
    await rig.session.pressSync(DjDeckId.a);

    await rig.session.stopAll();

    expect(rig.session.syncMaster, isNull);
    expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
  });
}
