import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/models/dj_beat_grid.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';

import '../../support/dj_analysis_fixtures.dart';

void main() {
  group('DjBeatRuler tiers (docs/dj-deck-spec.md:82-83)', () {
    test('tier A: manual downbeat authority is numbered and labels bar.beat',
        () {
      final ruler = DjBeatRuler.forAnalysis(djNumberedAnalysis())!;

      expect(ruler.numbered, isTrue);
      expect(ruler.beatsPerBar, 4);
      expect(ruler.phraseLengthBars, 4);
      expect(ruler.beatsMs, hasLength(djBeatGridBeats));
      expect(ruler.barStartsMs.first, 0);

      // The first downbeat.
      expect(ruler.positionAt(0)!.label, '1.1 · phrase 1');
      // Bar 3, beat 2 of the first phrase: nine beats in.
      expect(ruler.positionAt(djBeatMs * 9)!.label, '3.2 · phrase 1');
      // The 17th beat opens the second phrase.
      expect(ruler.positionAt(djBeatMs * 16)!.label, '1.1 · phrase 2');
    });

    test('tier A: a manual downbeat phase shifts the counter and leaves a '
        'phrase-free reading before the anchor', () {
      final ruler =
          DjBeatRuler.forAnalysis(djNumberedAnalysis(downbeatPhaseIndex: 2))!;

      expect(ruler.numbered, isTrue);
      // ManualTimingOverride.applyTo rewrites downbeats from beats[phase].
      expect(ruler.barStartsMs.first, djBeatMs * 2);
      expect(ruler.anchorBeatIndex, 2);

      expect(ruler.positionAt(djBeatMs * 2)!.label, '1.1 · phrase 1');
      // One beat before the anchor: exact, not clamped, and unnumbered.
      final before = ruler.positionAt(djBeatMs)!;
      expect(before.isBeforeAnchor, isTrue);
      expect(before.phrase, 0);
      expect(before.label, '4.4');
      // The same reading the unshifted grid gave at beat 0 now sits two beats
      // later, which is the whole point of the override.
      expect(ruler.positionAt(0)!.label, '4.3');
    });

    test('tier B: generated meter and phase give bars but no numbering', () {
      final ruler = DjBeatRuler.forAnalysis(djUnnumberedAnalysis())!;

      expect(ruler.numbered, isFalse);
      expect(ruler.beatsMs, isNotEmpty);
      expect(ruler.barStartsMs, isNotEmpty);
      expect(ruler.positionAt(djBeatMs * 5), isNotNull);
      // Phrase markers are numbered, so an unnumbered ruler still exposes the
      // marker list; the painter is what withholds it.
      expect(ruler.barLinesMs.first, 0);
    });

    test('tier C: no effective beat grid yields no ruler at all', () {
      expect(DjBeatRuler.forAnalysis(djNoGridAnalysis()), isNull);
      expect(DjBeatRuler.forAnalysis(null), isNull);
    });

    test('beatPosition is the display value where beatPhase refuses authority',
        () {
      final track = djAnalysisTrack(analysis: djUnnumberedAnalysis());
      final deck = DjDeckState(
        deckId: DjDeckId.a,
        trackRef: track.id,
        queueTrack: track,
        durationMs: track.durationMs,
        positionMs: djBeatMs * 5,
      );

      // Automation authority refuses generated meter (tempo_automation:117).
      expect(deck.beatPhase, isNull);
      // Display does not, per docs/dj-deck-spec.md:83.
      expect(deck.beatPosition, isNotNull);
      expect(deck.beatPosition!.beatInBar, 2);
    });
  });

  group('DjBeatRuler derivation', () {
    test('bars fall back to meter + phase when downbeats are absent', () {
      final analysis = djNumberedAnalysis(downbeatPhaseIndex: 1);
      final ruler = DjBeatRuler.forAnalysis(analysis)!;
      expect(ruler.anchorBeatIndex, 1);
      expect(ruler.barLinesMs.take(3), [djBeatMs, djBeatMs * 5, djBeatMs * 9]);
    });

    test('phrase markers stop at the anchor rather than numbering backwards',
        () {
      final ruler =
          DjBeatRuler.forAnalysis(djNumberedAnalysis(downbeatPhaseIndex: 2))!;
      expect(ruler.phraseMarkers.first.phrase, 1);
      expect(ruler.phraseMarkers.first.ms, djBeatMs * 2);
      expect(ruler.phraseMarkers.every((marker) => marker.phrase >= 1), isTrue);
      // Bar lines are on the anchor's own stride, so with a phase of 2 the
      // first one is beat 2 and there is no partial bar drawn before it.
      expect(ruler.barLinesMs.first, djBeatMs * 2);
    });

    test('phraseLengthBars honours a manual correction', () {
      final ruler = DjBeatRuler.forAnalysis(
        djNumberedAnalysis(phraseLengthBars: 8),
      )!;
      expect(ruler.phraseLengthBars, 8);
      expect(ruler.positionAt(djBeatMs * 16)!.label, '5.1 · phrase 1');
    });

    test('forAnalysis memoises per analysis identity', () {
      final analysis = djNumberedAnalysis();
      final other = djNumberedAnalysis();
      expect(
        identical(
          DjBeatRuler.forAnalysis(analysis),
          DjBeatRuler.forAnalysis(analysis),
        ),
        isTrue,
      );
      expect(
        identical(
          DjBeatRuler.forAnalysis(analysis),
          DjBeatRuler.forAnalysis(other),
        ),
        isFalse,
      );
    });
  });
}
