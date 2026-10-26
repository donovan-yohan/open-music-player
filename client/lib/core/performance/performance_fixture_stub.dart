import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'fixture_tokens.dart';

class PerformanceFixture {
  static PerformanceFixture? active;
  static Future<void> preflight() async {
    if (performanceFixtureEnabled) {
      throw StateError('fixture-macos-profile-required');
    }
  }

  static void verifyIsolation() {
    if (performanceFixtureEnabled) {
      throw StateError('fixture-macos-profile-required');
    }
  }

  BaseCacheManager get artworkCache => throw UnsupportedError('fixture');
  String get email => throw UnsupportedError('fixture');
  static Future<void> configureDatabases() async {
    if (performanceFixtureEnabled) {
      throw StateError('fixture-macos-profile-required');
    }
  }

  String get password => throw UnsupportedError('fixture');
  Future<String> databasePath() async => throw UnsupportedError('fixture');
  Future<String> downloadDirectory() async => throw UnsupportedError('fixture');
  Future<String> cacheDirectory() async => throw UnsupportedError('fixture');
}
