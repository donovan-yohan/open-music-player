import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/engine/deck_tempo_target.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';

import '../../support/dj_sync_fixtures.dart';

/// #413 (DJ-3) D8: a typed target BPM resolves to a rate through the shipped
/// octave search, or is **refused with the band named**.
///
/// The rule this file exists to pin: the deck never clamps a typed tempo
/// silently. `DeckController.setRate` clamps (the pitch fader is already range
/// limited), so a resolver that handed it an out-of-range rate would land the
/// deck at 1.25 while the field said 300 and nothing would say otherwise.
void main() {
  DjDeckState deck({double bpm = 124.5, double rate = 1}) =>
      djSyncDeckState(bpm: bpm, rate: rate);

  group('the reachable band', () {
    test('is the deck rate window around the native tempo', () {
      final band = djReachableBpmBand(deck())!;

      // The exact numbers the sheet's helper line renders for the 124.5 BPM
      // fixture: `Reachable tempo: 93.4 to 155.6 BPM`.
      expect(band.minBpm, closeTo(124.5 * kDjDeckMinRate, 1e-9));
      expect(band.maxBpm, closeTo(124.5 * kDjDeckMaxRate, 1e-9));
      expect(band.minBpm, closeTo(93.375, 1e-9));
      expect(band.maxBpm, closeTo(155.625, 1e-9));
      expect(band.minBpm.toStringAsFixed(1), '93.4');
      expect(band.maxBpm.toStringAsFixed(1), '155.6');
    });

    test('is null for a deck with no analyzed tempo', () {
      expect(
        djReachableBpmBand(const DjDeckState(deckId: DjDeckId.a, trackRef: '1')),
        isNull,
      );
    });

    test('every BPM the band names actually resolves, at both ends', () {
      // The regression: the band was the raw deck window and the resolver also
      // gated on the field's 50-200 BPM bounds, so a 174 BPM deck advertised
      // `130.5 to 217.5 BPM` and then refused 205 with "outside what this deck
      // can reach". The floor lied the same way: a 60 BPM deck advertised 45.0
      // and refused 46.
      for (final nativeBpm in <double>[60, 100, 124.5, 174, 190]) {
        final band = djReachableBpmBand(deck(bpm: nativeBpm))!;
        expect(band.minBpm, greaterThanOrEqualTo(kDjTempoFieldMinBpm - 1e-9),
            reason: '$nativeBpm BPM');
        expect(band.maxBpm, lessThanOrEqualTo(kDjTempoFieldMaxBpm + 1e-9),
            reason: '$nativeBpm BPM');
        for (final target in <double>[band.minBpm, band.maxBpm]) {
          expect(
            djResolveTargetBpm(deck: deck(bpm: nativeBpm), targetBpm: target)
                .isResolved,
            isTrue,
            reason: '$nativeBpm BPM deck refused $target, which it advertised',
          );
        }
      }
    });

    test('a 174 BPM deck is capped at the field ceiling, not at 217.5', () {
      final band = djReachableBpmBand(deck(bpm: 174))!;

      expect(band.minBpm, closeTo(130.5, 1e-9));
      expect(band.maxBpm, closeTo(kDjTempoFieldMaxBpm, 1e-9));
      // The `+` chip disables exactly where the line stops promising.
      expect(
        djResolveTargetBpm(deck: deck(bpm: 174), targetBpm: 200.1).isResolved,
        isFalse,
      );
    });

    test('a deck whose tempo the field cannot express has no band', () {
      // Not the same fact as "no analyzed tempo", and the sheet says so with
      // its own copy line.
      expect(djReachableBpmBand(deck(bpm: 300)), isNull);
      expect(djReachableBpmBand(deck(bpm: 30)), isNull);
      expect(djDeckNativeBpm(deck(bpm: 300)), 300);
    });
  });

  group('djResolveTargetBpm', () {
    test('a tempo inside the band resolves at the native octave', () {
      final target = djResolveTargetBpm(deck: deck(), targetBpm: 95);

      expect(target.isResolved, isTrue);
      expect(target.tempoScale, 1);
      expect(target.octaveShifted, isFalse);
      expect(target.rate, closeTo(95 / 124.5, 1e-6));
      expect(target.effectiveBpm, closeTo(95, 1e-6));
    });

    test('a tempo outside the band is refused, never clamped', () {
      for (final targetBpm in <double>[40, 300, 160, 80]) {
        final target = djResolveTargetBpm(deck: deck(), targetBpm: targetBpm);
        expect(target.isResolved, isFalse, reason: '$targetBpm BPM');
        expect(target.refusal, DjTempoTargetRefusal.outOfReach,
            reason: '$targetBpm BPM');
        // A refusal carries no rate a caller could accidentally apply.
        expect(target.rate, 1);
      }
    });

    test('the half-time reading of the same tempo is reachable', () {
      // 62.25 is 124.5 counted in half time. Scale 1 would need rate 0.5 and
      // scale 2 rate 0.25 - both outside the deck window - so the octave search
      // is what makes this input mean anything at all.
      final target = djResolveTargetBpm(deck: deck(), targetBpm: 62.25);

      expect(target.isResolved, isTrue);
      expect(target.tempoScale, 0.5);
      expect(target.octaveShifted, isTrue);
      expect(target.rate, closeTo(1.0, 1e-9));
      // The readout follows the header, which reads native x rate.
      expect(target.effectiveBpm, closeTo(124.5, 1e-9));
    });

    test('the double-time reading of the same tempo is reachable', () {
      final target = djResolveTargetBpm(deck: deck(bpm: 100), targetBpm: 190);

      expect(target.isResolved, isTrue);
      expect(target.tempoScale, 2);
      expect(target.rate, closeTo(0.95, 1e-9));
      expect(target.effectiveBpm, closeTo(95, 1e-9));
    });

    test('the native octave always wins when it is reachable at all', () {
      // The deck window is 0.737 octaves wide, so a rate inside it is always
      // closer to 1 than half or double that rate. Swept across the band.
      for (var bpm = 94.0; bpm <= 155.0; bpm += 0.5) {
        final target = djResolveTargetBpm(deck: deck(), targetBpm: bpm);
        expect(target.isResolved, isTrue, reason: '$bpm BPM');
        expect(target.tempoScale, 1, reason: '$bpm BPM');
        expect(target.effectiveBpm, closeTo(bpm, 1e-6), reason: '$bpm BPM');
      }
    });

    test('every resolved rate is inside the deck window', () {
      for (var bpm = kDjTempoFieldMinBpm; bpm <= kDjTempoFieldMaxBpm; bpm += 1) {
        final target = djResolveTargetBpm(deck: deck(), targetBpm: bpm);
        if (!target.isResolved) continue;
        expect(target.rate, greaterThanOrEqualTo(kDjDeckMinRate - 1e-9),
            reason: '$bpm BPM');
        expect(target.rate, lessThanOrEqualTo(kDjDeckMaxRate + 1e-9),
            reason: '$bpm BPM');
      }
    });

    test('the resolution is taken against the deck, not its current rate', () {
      // A deck already at 1.2 resolves the same target to the same rate: the
      // target is absolute, so re-typing the number the readout shows is a
      // no-op rather than a compounding multiplication.
      final atOne = djResolveTargetBpm(deck: deck(), targetBpm: 130);
      final atTwelve =
          djResolveTargetBpm(deck: deck(rate: 1.2), targetBpm: 130);

      expect(atTwelve.rate, closeTo(atOne.rate, 1e-12));
    });

    test('a deck with no analyzed tempo refuses with noTempo', () {
      final target = djResolveTargetBpm(
        deck: const DjDeckState(deckId: DjDeckId.a, trackRef: '1'),
        targetBpm: 128,
      );

      expect(target.refusal, DjTempoTargetRefusal.noTempo);
    });

    test('an unreachable target and a sync-owned deck are distinct reasons',
        () {
      // Collapsing them would send the user to the wrong action: one is about
      // the number typed, the other about who owns the deck's rate.
      expect(DjTempoTargetRefusal.values, contains(
          DjTempoTargetRefusal.syncControlled));
      expect(
        djResolveTargetBpm(deck: deck(), targetBpm: 300).refusal,
        DjTempoTargetRefusal.outOfReach,
      );
    });

    test('a non-finite target is refused rather than propagated', () {
      for (final bad in <double>[double.nan, double.infinity, 0, -128]) {
        expect(djResolveTargetBpm(deck: deck(), targetBpm: bad).isResolved,
            isFalse,
            reason: '$bad');
      }
    });
  });

  group('the fine steps', () {
    test('step the target BPM to one decimal, not the rate', () {
      expect(djSteppedTargetBpm(deck(), kDjTempoFineStepBpm), 124.6);
      expect(djSteppedTargetBpm(deck(), -kDjTempoFineStepBpm), 124.4);
    });

    test('ten +0.1 taps land exactly on 125.5, not on 125.49999', () {
      var current = deck();
      for (var tap = 0; tap < 10; tap++) {
        final next = djSteppedTargetBpm(current, kDjTempoFineStepBpm)!;
        final target = djResolveTargetBpm(deck: current, targetBpm: next);
        expect(target.isResolved, isTrue, reason: 'tap ${tap + 1}');
        current = djSyncDeckState(bpm: 124.5, rate: target.rate);
      }

      expect(djDeckEffectiveBpm(current)!, closeTo(125.5, 1e-6));
      // The point of stepping the BPM rather than the rate: the readout string
      // is the same number the arithmetic produced.
      expect(djDeckEffectiveBpm(current)!.toStringAsFixed(1), '125.5');
    });

    test('two -0.1 taps land exactly on 124.3', () {
      var current = deck();
      for (var tap = 0; tap < 2; tap++) {
        final next = djSteppedTargetBpm(current, -kDjTempoFineStepBpm)!;
        final target = djResolveTargetBpm(deck: current, targetBpm: next);
        current = djSyncDeckState(bpm: 124.5, rate: target.rate);
      }

      expect(djDeckEffectiveBpm(current)!, closeTo(124.3, 1e-6));
    });

    test('a step past the band edge resolves to a refusal, not a clamp', () {
      // 155.6 is the top of the fixture's band; the next step is not reachable.
      final atCeiling = djSyncDeckState(bpm: 124.5, rate: kDjDeckMaxRate);
      final next = djSteppedTargetBpm(atCeiling, kDjTempoFineStepBpm)!;

      expect(next, closeTo(155.7, 1e-9));
      expect(
        djResolveTargetBpm(deck: atCeiling, targetBpm: next).isResolved,
        isFalse,
      );
    });

    test('a deck with no tempo has nothing to step', () {
      expect(
        djSteppedTargetBpm(
          const DjDeckState(deckId: DjDeckId.a, trackRef: '1'),
          kDjTempoFineStepBpm,
        ),
        isNull,
      );
    });
  });
}
