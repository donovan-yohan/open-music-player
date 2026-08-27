import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/engine/deck_tempo_target.dart';
import 'package:open_music_player/features/dj/models/dj_camelot.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';

import '../../support/dj_sync_fixtures.dart';

/// #413 (DJ-3) D8: keylock, key shift and the hand-set tempo, at the engine and
/// session level.
///
/// The composed pitch factor is the contract here: `pitchFactorForRate` stays
/// the single source of the rate-to-pitch mapping and the key shift is a
/// multiplier of `2^(n/12)` on top of it, so with keylock **off** the shift
/// rides on the vinyl-style coupling rather than replacing it.
void main() {
  double semitoneFactor(int semitones) =>
      math.pow(2, semitones / 12).toDouble();

  Future<DjSyncRig> loadedRig({
    double deckABpm = 124.5,
    double deckBBpm = 128,
    bool pitchSupported = true,
  }) async {
    final rig = djSyncRig(pitchSupported: pitchSupported);
    addTearDown(rig.session.dispose);
    await rig.session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: deckABpm));
    await rig.session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: deckBBpm));
    return rig;
  }

  group('keylock', () {
    test('is on by default and sends a pitch factor of 1', () async {
      final rig = await loadedRig();

      expect(rig.session.deckA.pitchMode, pitchModePreserve);

      await rig.session.setTargetBpm(DjDeckId.a, 130);

      expect(rig.voiceFor(DjDeckId.a).pitches.last, closeTo(1.0, 1e-9));
    });

    test('off couples the pitch to the rate, on returns it to 1', () async {
      final rig = await loadedRig();
      await rig.session.setTargetBpm(DjDeckId.a, 130);
      final rate = rig.session.deckA.rate;

      await rig.session.setKeylock(DjDeckId.a, false);

      expect(rig.session.deckA.pitchMode, pitchModeFollowTempo);
      expect(rig.voiceFor(DjDeckId.a).pitches.last, closeTo(rate, 1e-9));
      // The rate itself must not move: keylock is not a tempo change.
      expect(rig.session.deckA.rate, rate);

      await rig.session.setKeylock(DjDeckId.a, true);

      expect(rig.session.deckA.pitchMode, pitchModePreserve);
      expect(rig.voiceFor(DjDeckId.a).pitches.last, closeTo(1.0, 1e-9));
    });

    test('survives every later rate write on the deck', () async {
      // The regression this pins: `setRate` used to default its pitch mode to
      // `pitchModePreserve`, so the pitch fader, a bend, the sync match and the
      // correction loop each silently switched keylock back on.
      final rig = await loadedRig();
      await rig.session.setKeylock(DjDeckId.a, false);

      await rig.session.setPitchPercent(DjDeckId.a, 4);
      expect(rig.session.deckA.pitchMode, pitchModeFollowTempo);

      await rig.session.nudgePitchStart(DjDeckId.a, 2);
      expect(rig.session.deckA.pitchMode, pitchModeFollowTempo);
      await rig.session.nudgePitchEnd(DjDeckId.a);
      expect(rig.session.deckA.pitchMode, pitchModeFollowTempo);

      await rig.session.pressSync(DjDeckId.a);
      expect(rig.session.deckA.pitchMode, pitchModeFollowTempo);
      expect(
        rig.voiceFor(DjDeckId.a).pitches.last,
        closeTo(rig.session.deckA.rate, 1e-9),
      );
    });
  });

  group('key shift', () {
    test('drives setPitch with 2^(n/12) while keylock is on', () async {
      final rig = await loadedRig();

      for (final semitones in <int>[1, 2, 5, 6, -1, -4, -6]) {
        await rig.session.setKeySemitones(DjDeckId.a, semitones);

        expect(rig.session.deckA.keySemitones, semitones);
        expect(
          rig.voiceFor(DjDeckId.a).pitches.last,
          closeTo(semitoneFactor(semitones), 1e-9),
          reason: '$semitones semitones',
        );
      }
      expect(
        rig.voiceFor(DjDeckId.a).pitches.last,
        closeTo(0.707107, 1e-6),
      );
    });

    test('+2 semitones is 1.122462, the number the sheet readout claims',
        () async {
      final rig = await loadedRig();

      await rig.session.setKeySemitones(DjDeckId.a, 2);

      expect(rig.voiceFor(DjDeckId.a).pitches.last, closeTo(1.122462, 1e-6));
      expect(djCamelotShifted(rig.session.deckA.camelot, 2), '10A');
    });

    test('composes on top of the tempo coupling with keylock off', () async {
      final rig = await loadedRig();
      await rig.session.setKeylock(DjDeckId.a, false);
      await rig.session.setTargetBpm(DjDeckId.a, 130);
      final rate = rig.session.deckA.rate;

      await rig.session.setKeySemitones(DjDeckId.a, 3);

      expect(
        rig.voiceFor(DjDeckId.a).pitches.last,
        closeTo(rate * semitoneFactor(3), 1e-9),
      );

      // ...and a later tempo change keeps carrying the shift.
      await rig.session.setTargetBpm(DjDeckId.a, 120);
      expect(
        rig.voiceFor(DjDeckId.a).pitches.last,
        closeTo(rig.session.deckA.rate * semitoneFactor(3), 1e-9),
      );
    });

    test('never moves the rate', () async {
      final rig = await loadedRig();
      await rig.session.setTargetBpm(DjDeckId.a, 130);
      final rate = rig.session.deckA.rate;
      final speeds = rig.voiceFor(DjDeckId.a).speeds.length;

      await rig.session.setKeySemitones(DjDeckId.a, 4);

      expect(rig.session.deckA.rate, rate);
      expect(rig.voiceFor(DjDeckId.a).speeds.length, speeds,
          reason: 'a key shift issues no rate command');
    });

    test('clamps at +/-6 and stays inside the voice pitch clamp', () async {
      final rig = await loadedRig();

      for (var tap = 0; tap < 7; tap++) {
        await rig.session.nudgeKeySemitones(DjDeckId.a, 1);
      }
      expect(rig.session.deckA.keySemitones, kDjMaxKeySemitones);

      for (var tap = 0; tap < 13; tap++) {
        await rig.session.nudgeKeySemitones(DjDeckId.a, -1);
      }
      expect(rig.session.deckA.keySemitones, -kDjMaxKeySemitones);

      // Worst-case composition at both rate extremes, with keylock off: the
      // range never collides with Voice.setPitch's own 0.5-2.0 clamp.
      for (final rate in <double>[kDjDeckMinRate, kDjDeckMaxRate]) {
        for (final semitones in <int>[-kDjMaxKeySemitones, kDjMaxKeySemitones]) {
          final factor = rate * semitoneFactor(semitones);
          expect(factor, greaterThanOrEqualTo(0.5), reason: '$rate/$semitones');
          expect(factor, lessThanOrEqualTo(2.0), reason: '$rate/$semitones');
        }
      }
      expect(kDjDeckMaxRate * semitoneFactor(6), closeTo(1.767767, 1e-6));
      expect(kDjDeckMinRate * semitoneFactor(-6), closeTo(0.530330, 1e-6));
    });

    test('a backend with no pitch shifting is recorded, not fatal', () async {
      final rig = await loadedRig(pitchSupported: false);

      expect(rig.session.deckA.pitchSupported, isTrue,
          reason: 'a freshly loaded deck starts optimistic');

      await rig.session.setKeySemitones(DjDeckId.a, 2);

      expect(rig.session.deckA.pitchSupported, isFalse);
      // The shift is still recorded and playback still proceeds; only the
      // affordance is withheld.
      expect(rig.session.deckA.keySemitones, 2);
    });

    test('a fresh load resets the shift and the pitch verdict', () async {
      final rig = await loadedRig(pitchSupported: false);
      await rig.session.setKeySemitones(DjDeckId.a, 4);
      expect(rig.session.deckA.pitchSupported, isFalse);

      await rig.session.load(DjDeckId.a, djSyncDeckSeed(id: '92', bpm: 120));

      expect(rig.session.deckA.keySemitones, 0);
      expect(rig.session.deckA.pitchSupported, isTrue);
    });
  });

  group('the hand-set tempo and sync', () {
    test('applies an exact target BPM to an idle deck', () async {
      final rig = await loadedRig();

      final target = await rig.session.setTargetBpm(DjDeckId.a, 95);

      expect(target.isResolved, isTrue);
      expect(rig.session.deckA.rate, closeTo(95 / 124.5, 1e-6));
      expect(djDeckEffectiveBpm(rig.session.deckA)!, closeTo(95, 1e-6));
    });

    test('refuses an unreachable tempo and leaves the rate untouched',
        () async {
      final rig = await loadedRig();
      final before = rig.session.deckA.rate;
      final speeds = rig.voiceFor(DjDeckId.a).speeds.length;

      final target = await rig.session.setTargetBpm(DjDeckId.a, 300);

      expect(target.isResolved, isFalse);
      expect(rig.session.deckA.rate, before);
      expect(rig.voiceFor(DjDeckId.a).speeds.length, speeds,
          reason: 'a refusal issues no rate command at all');
    });

    test('ten fine steps land the deck exactly on 125.5 BPM', () async {
      final rig = await loadedRig();

      for (var tap = 0; tap < 10; tap++) {
        final result =
            await rig.session.stepTempo(DjDeckId.a, kDjTempoFineStepBpm);
        expect(result.isResolved, isTrue, reason: 'tap ${tap + 1}');
      }

      expect(djDeckEffectiveBpm(rig.session.deckA)!, closeTo(125.5, 1e-6));
      expect(
        djDeckEffectiveBpm(rig.session.deckA)!.toStringAsFixed(1),
        '125.5',
      );
    });

    test("an engaged follower's tempo belongs to sync", () async {
      final rig = await loadedRig();
      await rig.session.pressSync(DjDeckId.a);
      final synced = rig.session.deckA.rate;

      expect(rig.session.tempoControlledBySync(DjDeckId.a), isTrue);
      expect(rig.session.tempoControlledBySync(DjDeckId.b), isFalse);

      final target = await rig.session.setTargetBpm(DjDeckId.a, 100);

      expect(target.isResolved, isFalse);
      expect(rig.session.deckA.rate, synced);
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue,
          reason: 'a refused edit moves no sync state either');
    });

    test('key shift stays available on an engaged follower', () async {
      final rig = await loadedRig();
      await rig.session.pressSync(DjDeckId.a);
      final synced = rig.session.deckA.rate;

      await rig.session.setKeySemitones(DjDeckId.a, 2);

      expect(rig.session.deckA.keySemitones, 2);
      expect(rig.session.deckA.rate, synced);
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
    });

    test('editing the master re-matches its follower through the sync path',
        () async {
      final rig = await loadedRig();
      await rig.session.pressSync(DjDeckId.a);
      expect(rig.session.syncMaster, DjDeckId.b);

      final target = await rig.session.setTargetBpm(DjDeckId.b, 130);

      expect(target.isResolved, isTrue);
      expect(rig.session.syncMaster, DjDeckId.b,
          reason: 'a master tempo edit is not a disengage');
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
      expect(djDeckEffectiveBpm(rig.session.deckB)!, closeTo(130, 1e-6));
      expect(djDeckEffectiveBpm(rig.session.deckA)!, closeTo(130, 1e-6));
    });

    test('a master tempo the follower cannot reach releases it honestly',
        () async {
      // A 100 BPM follower matches a 124.5 BPM master at rate 1.245, just
      // inside the window. Pushing the master to 130 needs 1.30, and no octave
      // brings it back: the window is 0.737 octaves wide, so ratios in
      // (1.25, 1.5) x 2^k are unreachable by construction.
      final rig = await loadedRig(deckABpm: 124.5, deckBBpm: 100);
      await rig.session.pressSync(DjDeckId.b);
      expect(rig.session.syncEngagedOn(DjDeckId.b), isTrue);
      expect(rig.session.syncMaster, DjDeckId.a);
      expect(rig.session.deckB.rate, closeTo(1.245, 1e-6));

      await rig.session.setTargetBpm(DjDeckId.a, 130);

      expect(rig.session.syncEngagedOn(DjDeckId.b), isFalse);
      expect(rig.session.syncMaster, isNull,
          reason: 'the master mark clears with the last follower');
      // Released on its matched base rate, not stranded mid-correction.
      expect(rig.session.deckB.rate, closeTo(1.245, 1e-6));
      expect(djDeckEffectiveBpm(rig.session.deckA)!, closeTo(130, 1e-6));
    });

    test('the pitch fader still takes the deck back from sync', () async {
      final rig = await loadedRig();
      await rig.session.pressSync(DjDeckId.a);

      await rig.session.setPitchPercent(DjDeckId.a, 3);

      expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
      expect(rig.session.tempoControlledBySync(DjDeckId.a), isFalse);
    });
  });

  group('reset', () {
    test('returns an idle deck to rate 1, no shift and keylock on', () async {
      final rig = await loadedRig();
      await rig.session.setTargetBpm(DjDeckId.a, 130);
      await rig.session.setKeylock(DjDeckId.a, false);
      await rig.session.setKeySemitones(DjDeckId.a, -3);

      await rig.session.resetTempoAndKey(DjDeckId.a);

      expect(rig.session.deckA.rate, 1.0);
      expect(rig.session.deckA.keySemitones, 0);
      expect(rig.session.deckA.pitchMode, pitchModePreserve);
      expect(rig.voiceFor(DjDeckId.a).pitches.last, closeTo(1.0, 1e-9));
    });

    test("leaves an engaged follower's synced tempo alone", () async {
      final rig = await loadedRig();
      await rig.session.pressSync(DjDeckId.a);
      final synced = rig.session.deckA.rate;
      await rig.session.setKeySemitones(DjDeckId.a, 5);

      await rig.session.resetTempoAndKey(DjDeckId.a);

      expect(rig.session.deckA.keySemitones, 0);
      expect(rig.session.deckA.pitchMode, pitchModePreserve);
      expect(rig.session.deckA.rate, synced,
          reason: 'sync owns this rate until the user releases it');
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
    });
  });
}
