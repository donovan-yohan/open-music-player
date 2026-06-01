import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/trim_range.dart';

void main() {
  const dur = 214000; // 214s track, in ms

  group('TrimRange.full', () {
    test('spans the whole track with nothing skipped or cut', () {
      final r = TrimRange.full(dur);
      expect(r.startOffsetMs, 0);
      expect(r.endOffsetMs, dur);
      expect(r.skippedIntroMs, 0);
      expect(r.cutTailMs, 0);
      expect(r.selectedDurationMs, dur);
    });
  });

  group('clamping', () {
    test('entry cannot go below zero', () {
      final r = TrimRange.clamped(
        trackDurationMs: dur,
        startOffsetMs: -5000,
        endOffsetMs: dur,
      );
      expect(r.startOffsetMs, 0);
    });

    test('exit cannot exceed track duration', () {
      final r = TrimRange.clamped(
        trackDurationMs: dur,
        startOffsetMs: 0,
        endOffsetMs: dur + 10000,
      );
      expect(r.endOffsetMs, dur);
    });

    test('enforces min playable duration when entry crowds exit', () {
      final r = TrimRange.clamped(
        trackDurationMs: dur,
        startOffsetMs: 100000,
        endOffsetMs: 100500, // only 500ms < minPlayable
      );
      expect(
          r.selectedDurationMs, greaterThanOrEqualTo(TrimRange.minPlayableMs));
    });

    test('min playable near the tail pulls entry back', () {
      final r = TrimRange.clamped(
        trackDurationMs: dur,
        startOffsetMs: dur - 200, // 200ms before end
        endOffsetMs: dur,
      );
      expect(r.endOffsetMs, dur);
      expect(r.startOffsetMs, lessThanOrEqualTo(dur - TrimRange.minPlayableMs));
      expect(
          r.selectedDurationMs, greaterThanOrEqualTo(TrimRange.minPlayableMs));
    });

    test('snaps offsets to the snap grid', () {
      final r = TrimRange.clamped(
        trackDurationMs: dur,
        startOffsetMs: 1234,
        endOffsetMs: 98765,
      );
      expect(r.startOffsetMs % TrimRange.snapMs, 0);
      expect(r.endOffsetMs % TrimRange.snapMs, 0);
    });
  });

  group('withStart / withEnd', () {
    test('withStart keeps min playable gap from exit', () {
      final r = TrimRange.full(dur).withEnd(50000);
      final moved = r.withStart(49900); // would crowd exit
      expect(moved.endOffsetMs - moved.startOffsetMs,
          greaterThanOrEqualTo(TrimRange.minPlayableMs));
    });

    test('withEnd keeps min playable gap from entry', () {
      final r = TrimRange.full(dur).withStart(10000);
      final moved = r.withEnd(10100); // would crowd entry
      expect(moved.endOffsetMs - moved.startOffsetMs,
          greaterThanOrEqualTo(TrimRange.minPlayableMs));
    });

    test('withStart clamps negative to zero', () {
      final r = TrimRange.full(dur).withStart(-1000);
      expect(r.startOffsetMs, 0);
    });

    test('withEnd clamps beyond duration to duration', () {
      final r = TrimRange.full(dur).withEnd(dur + 5000);
      expect(r.endOffsetMs, dur);
    });
  });

  group('derived segments', () {
    test('reports skipped intro and cut tail', () {
      final r = TrimRange.clamped(
        trackDurationMs: dur,
        startOffsetMs: 5000,
        endOffsetMs: 200000,
      );
      expect(r.skippedIntroMs, 5000);
      expect(r.cutTailMs, dur - 200000);
    });

    test('isFullTrack only when nothing trimmed', () {
      expect(TrimRange.full(dur).isFullTrack, isTrue);
      expect(TrimRange.full(dur).withStart(1000).isFullTrack, isFalse);
    });
  });
}
