import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/models/dj_camelot.dart';

/// #413: the per-deck key shift renders `<key> <camelot> -> <shifted camelot>`.
///
/// Camelot numbers are ordered by fifths, so **one semitone is seven wheel
/// steps**. Issue #413 illustrates the control with `8A -> 9A`; that is the
/// arithmetic of +7 semitones, not of +1. One semitone up from `8A` is `3A`,
/// and this file is the pin that keeps the implementation on the wheel rather
/// than on the issue's example.
void main() {
  group('djCamelotShifted', () {
    test('one semitone is seven wheel steps', () {
      expect(djCamelotShifted('8A', 0), '8A');
      expect(djCamelotShifted('8A', 1), '3A');
      expect(djCamelotShifted('8A', 2), '10A');
      expect(djCamelotShifted('8A', -1), '1A');
      expect(djCamelotShifted('8A', 6), '2A');
      expect(djCamelotShifted('8A', -6), '2A');
      expect(djCamelotShifted('12B', 1), '7B');
    });

    test("the issue's 8A -> 9A example is +7 semitones, not +1", () {
      expect(djCamelotShifted('8A', 7), '9A');
      expect(djCamelotShifted('8A', -5), '9A');
      expect(djCamelotShifted('8A', 1), isNot('9A'));
    });

    test('every offset in -6..6 is exact, in both modes', () {
      // The full table, computed by hand from n' = ((n - 1 + 7s) mod 12) + 1.
      const fromEight = <int, int>{
        -6: 2,
        -5: 9,
        -4: 4,
        -3: 11,
        -2: 6,
        -1: 1,
        0: 8,
        1: 3,
        2: 10,
        3: 5,
        4: 12,
        5: 7,
        6: 2,
      };
      for (final entry in fromEight.entries) {
        expect(djCamelotShifted('8A', entry.key), '${entry.value}A',
            reason: '8A + ${entry.key} semitones');
        expect(djCamelotShifted('8B', entry.key), '${entry.value}B',
            reason: '8B + ${entry.key} semitones');
      }
    });

    test('all twelve offsets from every wheel position stay on the wheel', () {
      for (var number = 1; number <= 12; number++) {
        for (final letter in const ['A', 'B']) {
          final seen = <String>{};
          for (var semitones = 0; semitones < 12; semitones++) {
            final shifted = djCamelotShifted('$number$letter', semitones)!;
            expect(shifted.endsWith(letter), isTrue,
                reason: 'transposition never changes mode');
            final parsed = int.parse(shifted.substring(0, shifted.length - 1));
            expect(parsed, inInclusiveRange(1, 12));
            seen.add(shifted);
          }
          // Twelve semitones reach twelve distinct positions: 7 and 12 are
          // coprime, so the wheel is a full cycle rather than a subgroup.
          expect(seen.length, 12,
              reason: '$number$letter did not reach all twelve positions');
          expect(djCamelotShifted('$number$letter', 12), '$number$letter',
              reason: 'an octave returns to the same key');
        }
      }
    });

    test('anything that is not a Camelot key returns null, never throws', () {
      for (final input in <String?>[null, '', 'x', '13A', '0A', '8C', '8', 'A8',
        '8 A', '--', 'A minor']) {
        expect(djCamelotShifted(input, 1), isNull, reason: 'input "$input"');
      }
    });

    test('case and surrounding whitespace are tolerated', () {
      expect(djCamelotShifted('8a', 1), '3A');
      expect(djCamelotShifted(' 12b ', 1), '7B');
    });
  });

  group('djDeckKeySegment', () {
    test('renders the shifted camelot only while the deck is shifted', () {
      expect(
        djDeckKeySegment(musicalKey: 'A minor', camelot: '8A'),
        'A minor 8A',
      );
      // Compact while shifted: the spelled key name is dropped so the shifted
      // segment is never wider than the unshifted one the header already fits.
      expect(
        djDeckKeySegment(musicalKey: 'A minor', camelot: '8A', semitones: 1),
        '8A → 3A',
      );
      expect(
        djDeckKeySegment(musicalKey: 'A minor', camelot: '8A', semitones: -2),
        '8A → 6A',
      );
    });

    test('the shifted form is never wider than the unshifted one', () {
      // The property the header depends on: enabling the key shift must not be
      // able to push the key segment past the give-order's budget and delete
      // the readout the user already had (#413 review).
      for (final key in const ['A minor', 'C# minor', 'F major']) {
        for (final camelot in const ['8A', '12A', '1B']) {
          final plain = djDeckKeySegment(musicalKey: key, camelot: camelot);
          for (var semitones = -6; semitones <= 6; semitones++) {
            if (semitones == 0) continue;
            final shifted = djDeckKeySegment(
              musicalKey: key,
              camelot: camelot,
              semitones: semitones,
            );
            expect(shifted.length, lessThanOrEqualTo(plain.length),
                reason: '$key $camelot $semitones: "$shifted" > "$plain"');
            expect(shifted, contains('→'));
          }
        }
      }
    });

    test('falls back to a semitone label with no camelot value', () {
      expect(
        djDeckKeySegment(musicalKey: 'A minor', semitones: 2),
        'A minor +2 st',
      );
      expect(
        djDeckKeySegment(musicalKey: 'A minor', semitones: -2),
        'A minor -2 st',
      );
    });

    test('a deck with no key at all has no key segment', () {
      expect(djDeckKeySegment(semitones: 3), '');
      expect(djDeckKeySegment(), '');
    });
  });
}
