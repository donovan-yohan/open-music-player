/// Camelot wheel arithmetic for the per-deck key shift (#413, DJ-3).
///
/// Adjacent Camelot numbers are a perfect fifth apart, so **one semitone is
/// seven steps around the wheel**: `n' = ((n - 1 + 7 * semitones) mod 12) + 1`,
/// with the letter (A = minor, B = major) unchanged because transposition never
/// changes mode.
///
/// Issue #413 illustrates the control with `8A -> 9A`. That is the arithmetic
/// of **+7 semitones** (or -5), not of +1: one semitone up from `8A` is `3A`.
/// The implementation follows the wheel, and the issue's example is recorded as
/// the error it is rather than reproduced.
library;

/// Semitone offsets outside this are not representable on the deck; see
/// `DeckController.setKeySemitones`, which clamps to the same range.
const int kDjMaxKeySemitones = 6;

/// Wheel steps one semitone moves. A perfect fifth is seven semitones, and the
/// wheel is ordered by fifths, so the two are inverse: stepping the wheel by 7
/// is stepping the pitch by 1.
const int _camelotStepsPerSemitone = 7;

final RegExp _camelotPattern = RegExp(r'^([1-9]|1[0-2])([AB])$');

/// [camelot] transposed by [semitones], or null when [camelot] is not a Camelot
/// key.
///
/// Total: never throws, and returns null rather than guessing for anything that
/// is not `<1..12><A|B>` (case-insensitively, surrounding whitespace ignored).
/// A null return is the caller's signal to fall back to a semitone label — the
/// deck has exactly one key-name parser and this is it.
String? djCamelotShifted(String? camelot, int semitones) {
  if (camelot == null) return null;
  final match = _camelotPattern.firstMatch(camelot.trim().toUpperCase());
  if (match == null) return null;
  final number = int.parse(match.group(1)!);
  final letter = match.group(2)!;
  final shifted =
      (number - 1 + _camelotStepsPerSemitone * semitones) % 12 + 1;
  return '$shifted$letter';
}

/// `+2 st` / `-2 st`, the fallback readout for a track with no Camelot value.
///
/// Deliberately not a second key-name parser: a deck that only knows `F# minor`
/// says how far it has been moved rather than inventing a transposed name.
String djKeySemitoneLabel(int semitones) =>
    '${semitones >= 0 ? '+' : '-'}${semitones.abs()} st';

/// How far [camelot] has been moved, as a suffix: `→ 3A` while the wheel can
/// name the destination and `+2 st` while it cannot. Empty at zero.
///
/// The one place the shift is turned into text. Both the header's key segment
/// and the sheet's key readout call it, so they cannot drift apart.
String djCamelotShiftSuffix(String? camelot, int semitones) {
  if (semitones == 0) return '';
  final shifted = djCamelotShifted(camelot, semitones);
  return shifted == null ? djKeySemitoneLabel(semitones) : '→ $shifted';
}

/// The deck header's key segment: `A minor 8A → 3A` while shifted, and the
/// plain `A minor 8A` at zero.
///
/// Returns an empty string when the deck knows neither a key name nor a
/// Camelot value, which is what the header treats as "no key segment".
String djDeckKeySegment({
  String? musicalKey,
  String? camelot,
  int semitones = 0,
}) {
  final base = [musicalKey, camelot].whereType<String>().join(' ');
  final suffix = base.isEmpty ? '' : djCamelotShiftSuffix(camelot, semitones);
  return suffix.isEmpty ? base : '$base $suffix';
}
