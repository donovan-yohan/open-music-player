import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/play_record_decider.dart';

/// Drives the pure decider through position ticks and counts how many "record"
/// signals it emits, so each scenario can assert the exact count.
List<String> _recordsFor(
  PlayRecordDecider decider,
  List<Duration> positions, {
  Duration duration = const Duration(minutes: 3),
}) {
  final records = <String>[];
  for (final p in positions) {
    final id = decider.onPosition(p, duration);
    if (id != null) records.add(id);
  }
  return records;
}

void main() {
  group('PlayRecordDecider threshold + dedup', () {
    test('emits exactly one record after crossing 30s', () {
      final decider = PlayRecordDecider()..onTrackChanged('7');
      final records = _recordsFor(decider, const [
        Duration(seconds: 5),
        Duration(seconds: 20),
        Duration(seconds: 29),
        Duration(seconds: 30),
        Duration(seconds: 31),
      ]);
      expect(records, ['7']);
    });

    test('further ticks / pause / resume / loop of the SAME play post nothing',
        () {
      final decider = PlayRecordDecider()..onTrackChanged('7');
      final records = <String>[];
      void tick(Duration p) {
        final id = decider.onPosition(p, const Duration(minutes: 3));
        if (id != null) records.add(id);
      }

      tick(const Duration(seconds: 31)); // records
      tick(const Duration(seconds: 45)); // later tick
      tick(const Duration(seconds: 20)); // seek back (resume)
      tick(const Duration(seconds: 0)); // loop restart, same track id
      tick(const Duration(seconds: 40)); // crosses again after loop
      expect(records, ['7']);
    });

    test('a skip before 30s records zero', () {
      final decider = PlayRecordDecider()..onTrackChanged('7');
      final records = _recordsFor(decider, const [
        Duration(seconds: 5),
        Duration(seconds: 15),
        Duration(seconds: 29),
      ]);
      expect(records, isEmpty);
      // Skipping to a new track must not retroactively record the old one.
      decider.onTrackChanged('8');
      expect(decider.hasRecorded, isFalse);
    });

    test('records once on completion even below the 30s threshold', () {
      final decider = PlayRecordDecider()..onTrackChanged('short');
      // Sub-threshold ticks alone never record...
      expect(
          decider.onPosition(
              const Duration(seconds: 12), const Duration(seconds: 15)),
          isNull);
      // ...but playing to the end does, exactly once.
      expect(decider.onCompleted(), 'short');
      expect(decider.onCompleted(), isNull);
    });

    test('completion after the threshold already recorded posts nothing', () {
      final decider = PlayRecordDecider()..onTrackChanged('7');
      expect(
          decider.onPosition(
              const Duration(seconds: 31), const Duration(minutes: 3)),
          '7');
      expect(decider.onCompleted(), isNull);
    });

    test('re-arms on track change so each track records once', () {
      final decider = PlayRecordDecider();

      decider.onTrackChanged('7');
      expect(_recordsFor(decider, const [Duration(seconds: 31)]), ['7']);

      decider.onTrackChanged('8');
      expect(_recordsFor(decider, const [Duration(seconds: 31)]), ['8']);

      // Same id repeated is not a re-arm.
      decider.onTrackChanged('8');
      expect(_recordsFor(decider, const [Duration(seconds: 40)]), isEmpty);
    });

    test('reset clears armed state on logout / account switch', () {
      final decider = PlayRecordDecider()..onTrackChanged('7');
      expect(
          decider.onPosition(
              const Duration(seconds: 31), const Duration(minutes: 3)),
          '7');

      decider.reset();
      expect(decider.currentTrackId, isNull);
      expect(decider.hasRecorded, isFalse);

      // After reset, the same track can record again for the new session.
      decider.onTrackChanged('7');
      expect(
          decider.onPosition(
              const Duration(seconds: 31), const Duration(minutes: 3)),
          '7');
    });

    test('no record while no track is armed', () {
      final decider = PlayRecordDecider();
      expect(
          decider.onPosition(
              const Duration(seconds: 31), const Duration(minutes: 3)),
          isNull);
      expect(decider.onCompleted(), isNull);
    });

    test('honours a custom threshold', () {
      final decider = PlayRecordDecider(threshold: const Duration(seconds: 10))
        ..onTrackChanged('7');
      expect(
          decider.onPosition(
              const Duration(seconds: 9), const Duration(minutes: 3)),
          isNull);
      expect(
          decider.onPosition(
              const Duration(seconds: 10), const Duration(minutes: 3)),
          '7');
    });
  });
}
