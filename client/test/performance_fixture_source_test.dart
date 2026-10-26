import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// Complements executed adapter/leg tests. These are startup ordering guards,
// not a native plugin or actual application runtime qualification.
bool ordered(String source, String before, String after) {
  final first = source.indexOf(before);
  final second = source.indexOf(after);
  return first >= 0 && second >= 0 && first < second;
}

void main() {
  test('missing or reversed tokens fail the ordering predicate', () {
    expect(ordered('first second', 'first', 'second'), isTrue);
    expect(ordered('second', 'first', 'second'), isFalse);
    expect(ordered('first', 'first', 'second'), isFalse);
    expect(ordered('second first', 'first', 'second'), isFalse);
  });
  test('fixture gates precede storage and startup errors are observed', () {
    final main = File('lib/main.dart').readAsStringSync();
    final journey = File(
      'integration_test/actual_root_profile_fixture.dart',
    ).readAsStringSync();
    final guards = [
      (
        main,
        'await PerformanceFixture.preflight();',
        'WidgetsFlutterBinding.ensureInitialized();',
      ),
      (
        main,
        'await PerformanceFixture.configureDatabases();',
        'await runApplicationStartup(',
      ),
      (journey, 'FlutterError.onError = (details)', 'await production.main();'),
      (
        journey,
        'ui.PlatformDispatcher.instance.onError = (error, stack)',
        'await production.main();',
      ),
    ];
    for (final guard in guards) {
      expect(ordered(guard.$1, guard.$2, guard.$3), isTrue);
      expect(
        ordered(guard.$1.replaceFirst(guard.$2, ''), guard.$2, guard.$3),
        isFalse,
        reason: 'Missing gate must fail independently',
      );
      expect(
        ordered(guard.$1.replaceFirst(guard.$3, ''), guard.$2, guard.$3),
        isFalse,
        reason: 'Missing consumer must fail independently',
      );
    }
    expect(journey, contains('observation.requireComplete();'));
    expect(journey, contains('fixture ??= PerformanceFixture.active;'));
  });
  test('ephemeral successor has no input files or personal-path fallback', () {
    final fixture = File(
      'lib/core/performance/performance_fixture_io.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final journey = File(
      'integration_test/actual_root_profile_fixture.dart',
    ).readAsStringSync();
    for (final forbidden in [
      'readAsBytes',
      'readAsString',
      'validatePaths',
      'SOUNDQ_FIXTURE_ROOT',
      'SOUNDQ_FIXTURE_OUTPUT',
      'SOUNDQ_FIXTURE_CREDENTIALS',
      'SOUNDQ_FIXTURE_SOURCE_MANIFEST',
    ]) {
      expect(fixture, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(RegExp(r'\b(?:File|Directory)\s*\(').hasMatch(fixture), isFalse);
    expect(fixture, contains('databasePath() async => inMemoryDatabasePath'));
    final storage = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.dart') &&
              !f.path.endsWith('offline_database.dart'),
        )
        .where((f) => f.readAsStringSync().contains('OfflineDatabase('))
        .toList();
    expect(storage.map((f) => f.path).toList(), ['lib/main.dart']);
    expect(main, contains('cacheManager: fixture?.artworkCache'));
    expect(
      fixture,
      contains('CachedNetworkImageProvider.defaultCacheManager ='),
    );
    expect(journey, contains('await fixture.exportReport(report);'));
    expect(journey, isNot(contains('await File(')));
    expect(fixture, contains("findProxy = (_) => 'DIRECT'"));
    expect(fixture, contains('request.followRedirects = false'));
    expect(fixture, contains('http://127.0.0.1:54762/report'));
  });
}
