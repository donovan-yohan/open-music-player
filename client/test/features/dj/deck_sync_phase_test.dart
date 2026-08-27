import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/engine/deck_sync.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/models/track.dart';

import '../../support/dj_sync_fixtures.dart';

/// #413 (DJ-3) D5/D6: the beat-level alignment signal and the capped
/// correction loop that rides the 33ms snapshot pass.
///
/// Every timing assertion here runs on a fake clock and hand-driven deck
/// positions. Nothing waits on a real timer: the throttle's contract is stated
/// in wall milliseconds, so a test that counted ticks would pin the wrong rule.

/// A bare deck snapshot. The alignment signal reads only the grid, the position
/// and the rate, so these cases deliberately carry no analysis: the reliability
/// gate is a separate function with its own tests.
DjDeckState gridDeck({
  DjDeckId deckId = DjDeckId.a,
  required List<int> beatsMs,
  required int positionMs,
  double rate = 1,
}) =>
    DjDeckState(
      deckId: deckId,
      trackRef: '1',
      beatsMs: beatsMs,
      positionMs: positionMs,
      rate: rate,
    );

/// The compact, analysis-less shape a hydration eviction hands the deck back.
QueueTrack bareQueueTrack(String id) => QueueTrack(
      id: id,
      queueItemId: 'dj-sync-$id',
      playbackTrackId: id,
      title: 'Sync fixture track',
      artist: 'Fixture artist',
      duration: 245000,
      addedAt: DateTime.utc(2026, 1, 1),
    );

List<int> grid(int intervalMs, {int beats = 32}) =>
    [for (var i = 0; i < beats; i++) intervalMs * i];

void main() {
  group('the alignment signal', () {
    test('two decks on the same beat read zero', () {
      final error = djSyncPhaseErrorMs(
        leader: gridDeck(deckId: DjDeckId.b, beatsMs: grid(469), positionMs: 0),
        follower: gridDeck(beatsMs: grid(469), positionMs: 0),
      );

      expect(error, closeTo(0, 1e-9));
    });

    test('a follower past its beat reads positive', () {
      final error = djSyncPhaseErrorMs(
        leader: gridDeck(deckId: DjDeckId.b, beatsMs: grid(469), positionMs: 0),
        follower: gridDeck(beatsMs: grid(469), positionMs: 100),
      );

      // Positive means the follower's beat sounded first, so it is ahead.
      expect(error, closeTo(100, 1e-6));
    });

    test('an error past the half beat wraps to the shorter way round', () {
      // 400ms into a 469ms beat is not 400ms late, it is 69ms early. A
      // controller fed +400 would drive the deck the long way round the pulse.
      final error = djSyncPhaseErrorMs(
        leader: gridDeck(deckId: DjDeckId.b, beatsMs: grid(469), positionMs: 0),
        follower: gridDeck(beatsMs: grid(469), positionMs: 400),
      );

      expect(error, closeTo(-69, 1e-6));
    });

    test('an octave-normalized pair is compared on the shorter pulse', () {
      // The single most likely correctness bug in this ticket: a 64 BPM
      // follower matched to a 128 BPM leader has beats twice as far apart, so
      // equating beat fractions is unsatisfiable and would report the follower
      // a whole 469ms leader-beat out when it is 234ms out.
      final reading = djSyncPhaseReading(
        leader: gridDeck(deckId: DjDeckId.b, beatsMs: grid(469), positionMs: 234),
        follower: gridDeck(beatsMs: grid(938), positionMs: 0),
      );

      expect(reading, isNotNull);
      expect(reading!.pulseMs, closeTo(469, 1e-9));
      expect(reading.errorMs.abs(), lessThanOrEqualTo(234.5));
      expect(reading.errorMs, closeTo(-234, 1e-6));
      // Negative: the follower's beat sounded 234ms after the leader's, and
      // 234ms of catching up is shorter than 235ms of holding back, so the
      // correction advances the follower.
      expect(
        djSyncRateOffset(
          errorMs: reading.errorMs,
          pulseMs: reading.pulseMs,
          baseRate: 1,
        ),
        greaterThan(0),
      );
    });

    test('a rate other than 1 converts the offset and the period to wall time',
        () {
      final reading = djSyncPhaseReading(
        leader: gridDeck(deckId: DjDeckId.b, beatsMs: grid(469), positionMs: 0),
        follower:
            gridDeck(beatsMs: grid(484), positionMs: 100, rate: 1.032258),
      );

      expect(reading, isNotNull);
      expect(reading!.errorMs, closeTo(100 / 1.032258, 1e-6));
      expect(reading.pulseMs, closeTo(484 / 1.032258, 1e-6));
      // The follower's own wall period is now the shorter of the two.
      expect(reading.pulseMs, lessThan(469));
    });

    test('a position with no beat interval around it reads null', () {
      final leader =
          gridDeck(deckId: DjDeckId.b, beatsMs: grid(469), positionMs: 0);

      expect(
        djSyncPhaseErrorMs(
          leader: leader,
          follower:
              gridDeck(beatsMs: [1000, 1469, 1938], positionMs: 500),
        ),
        isNull,
        reason: 'the position precedes the grid',
      );
      expect(
        djSyncPhaseErrorMs(
          leader: leader,
          follower: gridDeck(beatsMs: const [0, 469], positionMs: 900),
        ),
        isNull,
        reason: 'the position is past the last beat, so there is no interval',
      );
      expect(
        djSyncPhaseErrorMs(
          leader: leader,
          follower: gridDeck(beatsMs: const [], positionMs: 0),
        ),
        isNull,
        reason: 'there is no grid at all',
      );
    });
  });

  group('the correction maths', () {
    test('the deadband holds the base rate', () {
      expect(
        djSyncRateOffset(errorMs: 9.5, pulseMs: 469, baseRate: 1),
        0,
      );
      expect(
        djSyncRateOffset(errorMs: -9.5, pulseMs: 469, baseRate: 1),
        0,
      );
      expect(
        djSyncRateOffset(errorMs: 15, pulseMs: 469, baseRate: 1),
        closeTo(-kDjSyncPhaseGain * 15 / 469, 1e-12),
        reason: 'just outside the deadband and well inside the cap',
      );
    });

    test('the cap shrinks into the remaining deck headroom', () {
      expect(djSyncCorrectionCap(1), closeTo(kDjSyncMaxRateOffset, 1e-12));
      // 1.25 / 1.24 - 1: a follower matched near the top of the deck window
      // gets less correction rather than a new refusal after the fact.
      expect(djSyncCorrectionCap(1.24), closeTo(0.00806451, 1e-8));
      expect(djSyncCorrectionCap(0.76), closeTo(1 - 0.75 / 0.76, 1e-12));
      expect(djSyncCorrectionCap(kDjDeckMaxRate), 0);
      expect(djSyncCorrectionCap(0), 0);
    });

    test('a saturated error never exceeds the headroom cap', () {
      // Half a beat at 128 BPM, which is the worst case the loop ever sees.
      expect(
        djSyncRateOffset(errorMs: 234, pulseMs: 469, baseRate: 1.24),
        closeTo(-0.00806451, 1e-8),
      );
      expect(
        djSyncRateOffset(errorMs: -234, pulseMs: 469, baseRate: 1.24),
        closeTo(0.00806451, 1e-8),
      );
      expect(
        djSyncRateOffset(errorMs: -234, pulseMs: 469, baseRate: 1),
        closeTo(kDjSyncMaxRateOffset, 1e-12),
      );
    });
  });

  group('the correction gate', () {
    test('a short grid keeps the tempo match and withholds the correction', () {
      final follower = djSyncDeckState(
        analysis: djSyncShortGridAnalysis(bpm: 124.5),
        positionMs: 206,
      );
      final leader = djSyncDeckState(deckId: DjDeckId.b, bpm: 128, id: '91');

      expect(djSyncTempoMatch(leader: leader, follower: follower).isMatched,
          isTrue);
      expect(
        djSyncPhaseErrorMs(leader: leader, follower: follower),
        isNotNull,
        reason: 'the signal exists; it is the gate that withholds the command',
      );
      expect(
        djSyncPhaseCorrectionAllowed(leader: leader, follower: follower),
        isFalse,
      );
    });

    test('two manual grids allow the correction', () {
      expect(
        djSyncPhaseCorrectionAllowed(
          leader: djSyncDeckState(deckId: DjDeckId.b, bpm: 128, id: '91'),
          follower: djSyncDeckState(bpm: 124.5),
        ),
        isTrue,
      );
    });
  });

  group('the loop on the snapshot pass', () {
    late DjSyncFakeClock clock;
    late DjSyncRig rig;

    /// Loads a long-grid pair and returns the rig. Deck A follows deck B, so
    /// deck A is the one every rate assertion is about.
    ///
    /// [durationMs] 0 is the shape a real queue seeds: the API omits the field
    /// for an item with no source row (#425), and the fixture voices report no
    /// duration either, so such a deck genuinely does not know its length.
    Future<void> loadPair({
      double followerBpm = 124.5,
      int durationMs = 245000,
    }) async {
      await rig.session.load(
        DjDeckId.a,
        djSyncDeckSeed(
          id: '90',
          analysis: djSyncLongGridAnalysis(bpm: followerBpm),
          durationMs: durationMs,
        ),
      );
      await rig.session.load(
        DjDeckId.b,
        djSyncDeckSeed(
          id: '91',
          analysis: djSyncLongGridAnalysis(bpm: 128),
          durationMs: durationMs,
        ),
      );
    }

    setUp(() {
      clock = DjSyncFakeClock();
      rig = djSyncRig(clock: clock.read);
    });
    tearDown(() => rig.session.dispose());

    /// Starts both decks. The correction only acts on two running decks - rate
    /// is no authority over a paused deck's phase - so every case that expects
    /// a command has to say so, and the cases that expect silence have to prove
    /// they are seeing their own gate rather than this one.
    ///
    /// Called before `pressSync` on purpose: a follower that is already playing
    /// is never seeked, so the hand-driven positions below stay the test's.
    Future<void> startBothDecks() async {
      await rig.session.togglePlay(DjDeckId.a);
      await rig.session.togglePlay(DjDeckId.b);
    }

    /// One 33ms pass with both decks parked where the caller put them.
    Future<void> tick({int positionA = -1, int positionB = -1}) async {
      if (positionA >= 0) rig.voiceFor(DjDeckId.a).localPositionMs = positionA;
      if (positionB >= 0) rig.voiceFor(DjDeckId.b).localPositionMs = positionB;
      await rig.session.debugTick();
      clock.advance(33);
    }

    test('a half-beat error converges inside the analytic bound', () async {
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final base = rig.session.stateFor(DjDeckId.a).rate;
      expect(base, closeTo(128 / 124.5, 1e-9));

      // 206ms of media on a deck running at 1.0281 is 200ms of wall time: the
      // error the honest 11.7s worst case is quoted against.
      var positionA = 206.0;
      var positionB = 0.0;
      final errors = <double>[];
      final rates = <double>[];
      var settledAt = -1;
      for (var tickIndex = 0; tickIndex < 400; tickIndex++) {
        await tick(
          positionA: positionA.toInt(),
          positionB: positionB.toInt(),
        );
        final error = djSyncPhaseErrorMs(
          leader: rig.session.stateFor(DjDeckId.b),
          follower: rig.session.stateFor(DjDeckId.a),
        );
        expect(error, isNotNull);
        errors.add(error!);
        final rate = rig.session.stateFor(DjDeckId.a).rate;
        rates.add(rate);
        if (settledAt < 0 && error.abs() < kDjSyncPhaseDeadbandMs) {
          settledAt = tickIndex;
        }
        // Both decks advance at their own current rate, as they would on the
        // 33ms pass; only the follower's rate is under control.
        positionA += rate * 33;
        positionB += 33;
      }

      expect(errors.first, closeTo(200, 1));
      expect(settledAt, greaterThan(0),
          reason: 'the loop never reached the deadband');

      // Analytic bound: the cap closes the error at `cap` ms per ms until the
      // proportional term comes off the cap, then the loop is a first-order lag
      // with time constant pulse / gain.
      final pulse = djSyncPhaseReading(
        leader: rig.session.stateFor(DjDeckId.b),
        follower: rig.session.stateFor(DjDeckId.a),
      )!
          .pulseMs;
      const cap = kDjSyncMaxRateOffset;
      final saturatedUntil = cap * pulse / kDjSyncPhaseGain;
      final analyticMs = (errors.first.abs() - saturatedUntil) / cap +
          (pulse / kDjSyncPhaseGain) *
              math.log(saturatedUntil / kDjSyncPhaseDeadbandMs);
      expect(settledAt * 33, closeTo(analyticMs, analyticMs * 0.1));

      // Monotone once the first command has landed, sampled at 528ms.
      //
      // The signal is a staircase, not a ramp: `sinceBeatWall` advances at
      // exactly 1ms per wall ms inside one beat and only steps when the deck
      // crosses the next grid marker, so a sample finer than one beat period
      // reads the same number twice. Sampling from tick 9 also skips the one
      // discontinuity the D5 formula has - re-dividing the *elapsed* part of a
      // beat by a rate that only applies from now on restates the error by up
      // to `cap * period` (about 9ms here) at the instant a command lands.
      final samples = <double>[];
      for (var index = 9; index <= settledAt; index += 16) {
        samples.add(errors[index].abs());
      }
      expect(samples.length, greaterThan(4));
      for (var index = 1; index < samples.length; index++) {
        expect(samples[index], lessThan(samples[index - 1]),
            reason: 'the error grew between samples ${index - 1} and $index');
      }

      // The applied rate never leaves the correction band or the deck window.
      for (final rate in rates) {
        expect(rate, greaterThanOrEqualTo(base * (1 - cap) - 1e-9));
        expect(rate, lessThanOrEqualTo(base * (1 + cap) + 1e-9));
        expect(rate, greaterThanOrEqualTo(kDjDeckMinRate));
        expect(rate, lessThanOrEqualTo(kDjDeckMaxRate));
      }
    });

    test('a follower matched near the deck ceiling stays inside it', () async {
      await loadPair(followerBpm: 103);
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final base = rig.session.stateFor(DjDeckId.a).rate;
      expect(base, closeTo(128 / 103, 1e-9));
      final cap = djSyncCorrectionCap(base);
      expect(cap, lessThan(kDjSyncMaxRateOffset),
          reason: 'this base has less than 2% of headroom left');

      var positionA = 300.0;
      var positionB = 0.0;
      for (var tickIndex = 0; tickIndex < 200; tickIndex++) {
        await tick(positionA: positionA.toInt(), positionB: positionB.toInt());
        final rate = rig.session.stateFor(DjDeckId.a).rate;
        expect((rate / base - 1).abs(), lessThanOrEqualTo(cap + 1e-9));
        expect(rate, lessThanOrEqualTo(kDjDeckMaxRate));
        positionA += rate * 33;
        positionB += 33;
      }
    });

    test('a target that changes every tick is still throttled to 250ms',
        () async {
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final voice = rig.voiceFor(DjDeckId.a);
      final commandsBefore = voice.speeds.length;
      final issuedAtMs = <int>[];
      var previousCommands = commandsBefore;

      // The error flips sign every pass, so the controller wants a new command
      // on every one of the 300 ticks. Only the throttle stops it.
      for (var tickIndex = 0; tickIndex < 300; tickIndex++) {
        final at = clock.nowMs;
        await tick(positionA: tickIndex.isEven ? 62 : 0, positionB: 0);
        if (voice.speeds.length != previousCommands) {
          previousCommands = voice.speeds.length;
          issuedAtMs.add(at);
        }
      }

      final issued = voice.speeds.length - commandsBefore;
      expect(issued, issuedAtMs.length);
      expect(issued, greaterThan(1), reason: 'the loop did issue corrections');
      expect(issued, lessThanOrEqualTo(40),
          reason: '300 ticks is 9.9s, so at most 40 commands at one per 250ms');
      for (var index = 1; index < issuedAtMs.length; index++) {
        expect(issuedAtMs[index] - issuedAtMs[index - 1],
            greaterThanOrEqualTo(kDjSyncCorrectionIntervalMs));
      }
    });

    test('an error inside the deadband issues nothing at all', () async {
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final voice = rig.voiceFor(DjDeckId.a);
      final commandsBefore = voice.speeds.length;

      // 5ms of media at rate 1.028 is under 5ms of wall error.
      for (var tickIndex = 0; tickIndex < 30; tickIndex++) {
        await tick(positionA: 5, positionB: 0);
      }

      expect(voice.speeds.length, commandsBefore);
    });

    test('an untrustworthy grid keeps the match and issues no correction',
        () async {
      await rig.session.load(
        DjDeckId.a,
        djSyncDeckSeed(
          id: '90',
          analysis: djSyncShortGridAnalysis(bpm: 124.5),
        ),
      );
      await rig.session.load(
        DjDeckId.b,
        djSyncDeckSeed(id: '91', analysis: djSyncLongGridAnalysis(bpm: 128)),
      );
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final matched = rig.session.stateFor(DjDeckId.a).rate;
      expect(matched, closeTo(128 / 124.5, 1e-9));
      final voice = rig.voiceFor(DjDeckId.a);
      final commandsBefore = voice.speeds.length;

      for (var tickIndex = 0; tickIndex < 300; tickIndex++) {
        await tick(positionA: 206, positionB: 0);
      }

      expect(voice.speeds.length, commandsBefore,
          reason: 'a correction against an untrustworthy grid is a guess');
      expect(rig.session.stateFor(DjDeckId.a).rate, matched);
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
    });

    test('disengaging puts the deck back on exactly its matched tempo',
        () async {
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final base = rig.session.stateFor(DjDeckId.a).rate;
      final voice = rig.voiceFor(DjDeckId.a);

      var positionA = 206.0;
      var positionB = 0.0;
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: positionA.toInt(), positionB: positionB.toInt());
        positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
        positionB += 33;
      }
      expect(rig.session.stateFor(DjDeckId.a).rate, isNot(closeTo(base, 1e-9)),
          reason: 'the correction has bent the rate away from the base');
      final commandsBefore = voice.speeds.length;

      await rig.session.pressSync(DjDeckId.a);

      expect(voice.speeds.length, commandsBefore + 1,
          reason: 'exactly one restoring command');
      expect(voice.speeds.last, closeTo(base, 1e-9));
      expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(base, 1e-9));
      expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
    });

    test('a paused follower is seeked exactly into the pulse', () async {
      await loadPair();
      await rig.session.seek(DjDeckId.a, 206);
      final voice = rig.voiceFor(DjDeckId.a);
      final seeksBefore = voice.seeks.length;

      await rig.session.pressSync(DjDeckId.a);

      expect(voice.seeks.length, seeksBefore + 1);
      expect(voice.seeks.last, 0,
          reason: '206ms of media at rate 1.0281 is the whole 200ms error');
      final error = djSyncPhaseErrorMs(
        leader: rig.session.stateFor(DjDeckId.b),
        follower: rig.session.stateFor(DjDeckId.a),
      );
      expect(error, closeTo(0, 1));
    });

    test('a paused follower is placed, not driven', () async {
      // The most ordinary DJ move there is: cue a deck up, press SYNC, press
      // PLAY seconds later. Rate is no authority over a paused deck's phase, so
      // a loop that drove it anyway could never converge - it would saturate at
      // the cap, flip sign every half beat and spam a rate command every
      // throttle window forever, leaving the deck up to 2% off its matched
      // tempo at the instant PLAY is pressed.
      await loadPair();
      await rig.session.togglePlay(DjDeckId.b);
      await rig.session.seek(DjDeckId.a, 206);
      await rig.session.pressSync(DjDeckId.a);
      final base = rig.session.stateFor(DjDeckId.a).rate;
      final voice = rig.voiceFor(DjDeckId.a);
      final commandsBefore = voice.speeds.length;

      var positionB = 0.0;
      for (var tickIndex = 0; tickIndex < 300; tickIndex++) {
        await tick(positionB: positionB.toInt());
        positionB += 33;
      }

      expect(voice.speeds.length, commandsBefore,
          reason: 'a paused deck received rate commands it cannot answer');
      expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(base, 1e-12),
          reason: 'PLAY must start the deck on the tempo it was matched to');
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
    });

    test('a paused master hands the follower back and then stays quiet',
        () async {
      // Pausing the master is one ordinary tap and does not disengage sync. Its
      // position then freezes while the follower keeps advancing at exactly one
      // wall ms per wall ms, so the error is a sawtooth no rate can slow: the
      // loop would wobble the deck the user is listening to between +/-2% at
      // about 2Hz, which is the one thing a synced deck must never do.
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final base = rig.session.stateFor(DjDeckId.a).rate;
      final voice = rig.voiceFor(DjDeckId.a);

      var positionA = 206.0;
      var positionB = 0.0;
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: positionA.toInt(), positionB: positionB.toInt());
        positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
        positionB += 33;
      }
      expect(rig.session.stateFor(DjDeckId.a).rate, isNot(closeTo(base, 1e-9)),
          reason: 'the correction has bent the rate away from the base');

      await rig.session.togglePlay(DjDeckId.b);
      final commandsBefore = voice.speeds.length;
      for (var tickIndex = 0; tickIndex < 300; tickIndex++) {
        await tick(positionA: positionA.toInt(), positionB: positionB.toInt());
        positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
      }

      expect(voice.speeds.length, commandsBefore + 1,
          reason: 'exactly one command: the hand-back to the matched tempo');
      expect(voice.speeds.last, closeTo(base, 1e-9));
      expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(base, 1e-9));
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue,
          reason: 'pausing a deck is not disengaging sync');
    });

    test('a pitch bend holds the deck for its whole hold', () async {
      // Two authorities, one rate. While the bend is held the loop watches: an
      // overwrite mid-hold would make the bend silently stop working, and the
      // restore afterwards would then put the deck on a rate the recorded
      // offset disagrees with - after which the loop's "same offset, nothing to
      // do" test parks it at the wrong tempo for good.
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final voice = rig.voiceFor(DjDeckId.a);

      // The error flips every pass, so the loop wants a new command constantly.
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: tickIndex.isEven ? 62 : 0, positionB: 0);
      }
      final rateBeforeBend = rig.session.stateFor(DjDeckId.a).rate;

      await rig.session.nudgePitchStart(DjDeckId.a, 2);
      final commandsDuringHold = voice.speeds.length;
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: tickIndex.isEven ? 62 : 0, positionB: 0);
      }

      expect(voice.speeds.length, commandsDuringHold,
          reason: 'the loop overwrote a bend the user was still holding');
      expect(
        rig.session.stateFor(DjDeckId.a).rate,
        closeTo(rateBeforeBend * 1.02, 1e-9),
        reason: 'the bend is what the deck is on for as long as it is held',
      );

      await rig.session.nudgePitchEnd(DjDeckId.a);
      expect(rig.session.stateFor(DjDeckId.a).rate,
          closeTo(rateBeforeBend, 1e-12),
          reason: 'the bend returns the deck to what sync is holding');

      final commandsAfterRelease = voice.speeds.length;
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: tickIndex.isEven ? 62 : 0, positionB: 0);
      }
      expect(voice.speeds.length, greaterThan(commandsAfterRelease),
          reason: 'the loop must take the rate back once the bend is released');
    });

    test('a refused swap leaves the follower still correcting', () async {
      // Pressing the master is the swap. A swap that refuses moves nothing, so
      // the deck that was following before the press is still following after
      // it - and it must still be a deck the loop can correct. Reachable
      // exactly this way: a hydration pass evicts the master's analysis, the
      // swap press refuses, and the refetch then puts the analysis back.
      await loadPair();
      await startBothDecks();
      await rig.session.pressSync(DjDeckId.a);
      final base = rig.session.stateFor(DjDeckId.a).rate;
      final voice = rig.voiceFor(DjDeckId.a);

      var positionA = 206.0;
      var positionB = 0.0;
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: positionA.toInt(), positionB: positionB.toInt());
        positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
        positionB += 33;
      }
      expect(rig.session.stateFor(DjDeckId.a).rate, isNot(closeTo(base, 1e-9)),
          reason: 'the correction has bent the rate away from the base');

      rig.session.applyAnalysisUpdate([bareQueueTrack('91')]);
      final refused = await rig.session.pressSync(DjDeckId.b);

      expect(refused.isMatched, isFalse);
      expect(rig.session.syncMaster, DjDeckId.b, reason: 'a refusal moves no roles');
      expect(rig.session.syncEngagedOn(DjDeckId.a), isTrue);
      expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(base, 1e-9),
          reason: 'the swap unwound the correction before computing the match');

      // The refetch lands and the gate reopens. Without the base rate the
      // refusal path dropped, the loop would abandon this deck on every pass
      // from here on while the UI kept showing it engaged.
      rig.session.applyAnalysisUpdate([
        djSyncQueueTrack(
          id: '91',
          analysis: djSyncLongGridAnalysis(bpm: 128),
        ),
      ]);
      final commandsBefore = voice.speeds.length;
      for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
        await tick(positionA: positionA.toInt(), positionB: positionB.toInt());
        positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
        positionB += 33;
      }

      expect(voice.speeds.length, greaterThan(commandsBefore),
          reason: 'a refused swap must not silently kill the correction');
    });

    test('a follower released by the master keeps its matched tempo', () async {
      // The deck nobody rewrites next is exactly the one that has to be handed
      // back by hand: moving the *master's* fader or loading over the master
      // leaves the follower playing, and it must not be left holding a
      // mid-correction rate with its base rate forgotten.
      for (final release in <String>['fader', 'load']) {
        // A fresh rig per case; tearDown disposes whichever one is last.
        rig.session.dispose();
        clock = DjSyncFakeClock();
        rig = djSyncRig(clock: clock.read);
        await loadPair();
        await startBothDecks();
        await rig.session.pressSync(DjDeckId.a);
        final base = rig.session.stateFor(DjDeckId.a).rate;
        final voice = rig.voiceFor(DjDeckId.a);

        var positionA = 206.0;
        var positionB = 0.0;
        for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
          await tick(
              positionA: positionA.toInt(), positionB: positionB.toInt());
          positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
          positionB += 33;
        }
        expect(rig.session.stateFor(DjDeckId.a).rate,
            isNot(closeTo(base, 1e-9)),
            reason: 'the correction has bent the rate away from the base');
        final commandsBefore = voice.speeds.length;

        if (release == 'fader') {
          await rig.session.setPitchPercent(DjDeckId.b, 3);
        } else {
          await rig.session.load(
            DjDeckId.b,
            djSyncDeckSeed(id: '92', analysis: djSyncLongGridAnalysis(bpm: 128)),
          );
        }

        expect(rig.session.syncMaster, isNull, reason: release);
        expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse, reason: release);
        expect(voice.speeds.length, commandsBefore + 1,
            reason: 'exactly one restoring command ($release)');
        expect(voice.speeds.last, closeTo(base, 1e-9), reason: release);
        expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(base, 1e-9),
            reason: release);
      }
    });

    test('the placement is retaken when the follower actually starts', () async {
      // Placing a paused follower at press time is only exact for that instant:
      // the leader keeps playing, so by the time PLAY is pressed - seconds
      // later, normally - the deck is an arbitrary fraction of a beat out
      // again and the placement bought nothing.
      await loadPair();
      await rig.session.togglePlay(DjDeckId.b);
      await rig.session.seek(DjDeckId.a, 206);
      await rig.session.pressSync(DjDeckId.a);
      final voice = rig.voiceFor(DjDeckId.a);

      var positionB = 0;
      var leaderAt = 0;
      for (var tickIndex = 0; tickIndex < 60; tickIndex++) {
        leaderAt = positionB;
        await tick(positionB: leaderAt);
        positionB += 33;
      }
      final driftedError = djSyncPhaseErrorMs(
        leader: rig.session.stateFor(DjDeckId.b),
        follower: rig.session.stateFor(DjDeckId.a),
      );
      expect(driftedError!.abs(), greaterThan(kDjSyncPhaseDeadbandMs),
          reason: 'the press-time placement has gone stale, as it must');
      final seeksBefore = voice.seeks.length;

      await rig.session.togglePlay(DjDeckId.a);
      // The leader stays where the placement read it: this fake transport only
      // moves when the test moves it, so advancing it here would measure the
      // 33ms the leader travelled rather than the placement itself.
      await tick(positionB: leaderAt);

      expect(voice.seeks.length, seeksBefore + 1,
          reason: 'the start transition is where the placement has to happen');
      final startedError = djSyncPhaseErrorMs(
        leader: rig.session.stateFor(DjDeckId.b),
        follower: rig.session.stateFor(DjDeckId.a),
      );
      expect(startedError!.abs(), lessThan(kDjSyncPhaseDeadbandMs),
          reason: 'the deck must start its first sample already in phase');
    });

    test('a follower with no known duration is still placed on the pulse',
        () async {
      // The placement was bounded above by `follower.durationMs` with no test
      // for whether that duration was ever known. On a deck a real queue seeds
      // it is 0 (#425), so every positive target was refused and the headline
      // behaviour - "starts its first sample already in phase" - was never once
      // taken in production, only in tests whose fixture carried a duration.
      await loadPair(durationMs: 0);
      expect(rig.session.stateFor(DjDeckId.a).durationMs, 0,
          reason: 'the device shape: the deck knows no duration at all');
      await rig.session.togglePlay(DjDeckId.b);
      await rig.session.seek(DjDeckId.a, 688);
      final voice = rig.voiceFor(DjDeckId.a);
      final seeksBefore = voice.seeks.length;

      await rig.session.pressSync(DjDeckId.a);

      expect(voice.seeks.length, seeksBefore + 1,
          reason: 'the placement was refused against an unknown duration');
      expect(voice.seeks.last, greaterThan(0),
          reason: 'a target of 0 would pass the broken bound by accident');
      final error = djSyncPhaseErrorMs(
        leader: rig.session.stateFor(DjDeckId.b),
        follower: rig.session.stateFor(DjDeckId.a),
      );
      expect(error!.abs(), lessThan(kDjSyncPhaseDeadbandMs));
    });

    test('a placement that leaves a known-length track is still refused',
        () async {
      // Conditioning the bound on a known duration must not weaken it where it
      // is known. A follower sitting just before its beat has to move forward,
      // and on a 400ms track that lands past the end: clamping there would put
      // the deck off the pulse while reporting success, so the shift is simply
      // not taken.
      await loadPair(durationMs: 400);
      await rig.session.togglePlay(DjDeckId.b);
      await rig.session.seek(DjDeckId.a, 400);
      final voice = rig.voiceFor(DjDeckId.a);
      final seeksBefore = voice.seeks.length;

      await rig.session.pressSync(DjDeckId.a);

      expect(voice.seeks.length, seeksBefore,
          reason: 'landing off the pulse while reporting success is worse');

      // The same geometry on a deck long enough to hold the target IS taken,
      // so the refusal above is the bound doing its job rather than a missing
      // alignment signal.
      rig.session.dispose();
      clock = DjSyncFakeClock();
      rig = djSyncRig(clock: clock.read);
      await loadPair();
      await rig.session.togglePlay(DjDeckId.b);
      await rig.session.seek(DjDeckId.a, 400);
      final roomy = rig.voiceFor(DjDeckId.a);
      final roomySeeksBefore = roomy.seeks.length;

      await rig.session.pressSync(DjDeckId.a);

      expect(roomy.seeks.length, roomySeeksBefore + 1);
      expect(roomy.seeks.last, greaterThan(400),
          reason: 'the target the short track had to refuse');
    });

    test('a bend held across a release still lands on the matched tempo',
        () async {
      // Two authorities, one rate, in the other order. The loop already stands
      // down for a held bend, but the three restore paths did not: each wrote
      // the base rate under the user's finger and then deleted the bookkeeping
      // `nudgePitchEnd` reads, so the release fell back to the rate captured
      // when the bend started - a mid-correction rate, up to the 2% cap off the
      // matched tempo, now with nothing left that could ever put it back.
      for (final release in <String>['master fader', 'disengage press']) {
        rig.session.dispose();
        clock = DjSyncFakeClock();
        rig = djSyncRig(clock: clock.read);
        await loadPair();
        await startBothDecks();
        await rig.session.pressSync(DjDeckId.a);
        final base = rig.session.stateFor(DjDeckId.a).rate;
        final voice = rig.voiceFor(DjDeckId.a);

        var positionA = 206.0;
        var positionB = 0.0;
        for (var tickIndex = 0; tickIndex < 40; tickIndex++) {
          await tick(
              positionA: positionA.toInt(), positionB: positionB.toInt());
          positionA += rig.session.stateFor(DjDeckId.a).rate * 33;
          positionB += 33;
        }
        expect(rig.session.stateFor(DjDeckId.a).rate,
            isNot(closeTo(base, 1e-9)),
            reason: 'the correction has bent the rate away from the base');

        await rig.session.nudgePitchStart(DjDeckId.a, -2);
        final commandsUnderHold = voice.speeds.length;

        if (release == 'master fader') {
          await rig.session.setPitchPercent(DjDeckId.b, 3);
        } else {
          await rig.session.pressSync(DjDeckId.a);
        }

        expect(voice.speeds.length, commandsUnderHold,
            reason: 'the restore overwrote a bend the user was holding '
                '($release)');
        expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse, reason: release);

        await rig.session.nudgePitchEnd(DjDeckId.a);

        expect(voice.speeds.last, closeTo(base, 1e-9), reason: release);
        expect(rig.session.stateFor(DjDeckId.a).rate, closeTo(base, 1e-9),
            reason: 'the bend must release onto the matched tempo ($release)');
      }
    });

    test('a playing follower is never seeked', () async {
      await loadPair();
      await rig.session.seek(DjDeckId.a, 206);
      await rig.session.togglePlay(DjDeckId.a);
      final voice = rig.voiceFor(DjDeckId.a);
      final seeksBefore = voice.seeks.length;

      await rig.session.pressSync(DjDeckId.a);

      expect(voice.seeks.length, seeksBefore,
          reason: 'a buffered seek on a playing deck is audible');
    });
  });

  group('the master mark', () {
    late DjSyncRig rig;

    setUp(() async {
      rig = djSyncRig();
      await rig.session.load(DjDeckId.a, djSyncDeckSeed(id: '90', bpm: 124.5));
      await rig.session.load(DjDeckId.b, djSyncDeckSeed(id: '91', bpm: 128));
    });
    tearDown(() => rig.session.dispose());

    test('clears with the last follower', () async {
      await rig.session.pressSync(DjDeckId.a);
      expect(rig.session.syncMaster, DjDeckId.b);

      await rig.session.pressSync(DjDeckId.a);

      expect(rig.session.syncEngagedOn(DjDeckId.a), isFalse);
      expect(rig.session.syncMaster, isNull,
          reason: 'a deck that nothing follows does not set anybody tempo');
      expect(rig.session.isSyncMaster(DjDeckId.b), isFalse);
    });

    test('survives while a follower remains', () async {
      await rig.session.pressSync(DjDeckId.a);

      // The swap is the only reachable two-role transition in a two-deck
      // session: the engaged set never empties across it, so the mark moves
      // rather than clearing. A third deck would exercise the same rule with
      // two simultaneous followers, which this session cannot express.
      await rig.session.pressSync(DjDeckId.b);

      expect(rig.session.syncMaster, DjDeckId.a);
      expect(rig.session.syncEngagedOn(DjDeckId.b), isTrue);
    });

    test('clears when the follower takes its tempo back by hand', () async {
      await rig.session.pressSync(DjDeckId.a);

      await rig.session.setPitchPercent(DjDeckId.a, 3);

      expect(rig.session.syncMaster, isNull);
      expect(rig.session.isSyncMaster(DjDeckId.b), isFalse);
    });
  });
}
