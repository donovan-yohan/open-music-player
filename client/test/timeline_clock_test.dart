import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';

void main() {
  late DateTime now;

  DefaultTimelineClock clock() => DefaultTimelineClock(
        now: () => now,
        uiTickInterval: const Duration(hours: 1),
      )..durationMs = 10000;

  setUp(() {
    now = DateTime.utc(2026, 1, 1);
  });

  test('advances from injectable time while playing', () async {
    final c = clock();

    await c.play();
    now = now.add(const Duration(milliseconds: 1250));
    c.tickForTest();

    expect(c.positionMs, 1250);
    expect(c.isPlaying, isTrue);
    await c.dispose();
  });

  test(
    'holdForBuffering pauses advancement without clearing play intent',
    () async {
      final c = clock();

      await c.play();
      now = now.add(const Duration(milliseconds: 500));
      c.tickForTest();
      c.holdForBuffering();
      now = now.add(const Duration(seconds: 5));
      c.tickForTest();

      expect(c.positionMs, 500);
      expect(c.isPlaying, isTrue);
      expect(c.isBufferingHeld, isTrue);

      c.releaseHold();
      now = now.add(const Duration(milliseconds: 250));
      c.tickForTest();

      expect(c.positionMs, 750);
      expect(c.isBufferingHeld, isFalse);
      await c.dispose();
    },
  );

  test('seek commits a scrub event and clamps to duration', () async {
    final c = clock();
    final committed = <int>[];
    final sub = c.scrubCommittedStream.listen(committed.add);

    await c.seek(12000);

    expect(c.positionMs, 10000);
    expect(committed, [10000]);
    await sub.cancel();
    await c.dispose();
  });

  test('releaseHold can publish UI position without voice sync', () async {
    final c = clock();
    final uiPositions = <int>[];
    final voiceSyncPositions = <int>[];
    final uiSub = c.positionMsStream.listen(uiPositions.add);
    final voiceSub = c.voiceSyncPositionMsStream.listen(voiceSyncPositions.add);

    await c.play();
    now = now.add(const Duration(milliseconds: 500));
    c.tickForTest();
    await Future<void>.delayed(Duration.zero);
    c.holdForBuffering();
    uiPositions.clear();
    voiceSyncPositions.clear();
    c.releaseHold(syncVoices: false);
    await Future<void>.delayed(Duration.zero);

    expect(uiPositions, contains(500));
    expect(voiceSyncPositions, isNot(contains(500)));

    await uiSub.cancel();
    await voiceSub.cancel();
    await c.dispose();
  });

  test('emits completed once when duration is reached', () async {
    final c = clock();
    final completed = expectLater(c.completedStream, emits(isNull));

    await c.play();
    now = now.add(const Duration(seconds: 11));
    c.tickForTest();
    c.tickForTest();

    expect(c.positionMs, 10000);
    expect(c.isPlaying, isFalse);
    await completed;
    await c.dispose();
  });
}
