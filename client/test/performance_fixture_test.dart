import 'dart:convert';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:open_music_player/core/performance/fixture_tokens.dart';
import 'package:open_music_player/core/performance/performance_fixture_io.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/performance/profile_scroll_leg.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real plugin factory redirects legacy lookup without native dispatch',
    () async {
      var dispatches = 0;
      const channel = MethodChannel('com.tekartik.sqflite');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        dispatches++;
        throw StateError('unexpected-personal-path-lookup');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await PerformanceFixture.configureDatabaseRoot(
        databaseFactorySqflitePlugin,
      );
      expect(
        await databaseFactorySqflitePlugin.getDatabasesPath(),
        PerformanceFixture.refusedDatabaseRoot,
      );
      expect(dispatches, 0);
    },
  );
  test(
    'legacy root is fixed and refuses a factory that ignores the fence',
    () async {
      final factory = _DatabasePaths();
      await PerformanceFixture.configureDatabaseRoot(factory);
      expect(factory.calls, [
        'set:${PerformanceFixture.refusedDatabaseRoot}',
        'get',
      ]);
      factory.path = '/personal';
      factory.ignoreSet = true;
      await expectLater(
        PerformanceFixture.configureDatabaseRoot(factory),
        throwsStateError,
      );
    },
  );
  test(
    'every filesystem destination refuses; memory cache needs no paths',
    () async {
      final oldPaths = PathProviderPlatform.instance;
      final paths = FixturePaths();
      PathProviderPlatform.instance = paths;
      addTearDown(() => PathProviderPlatform.instance = oldPaths);
      for (final request in [
        paths.getTemporaryPath,
        paths.getApplicationSupportPath,
        paths.getApplicationDocumentsPath,
        paths.getApplicationCachePath,
        paths.getLibraryPath,
        paths.getDownloadsPath,
        paths.getExternalStoragePath,
        paths.getExternalCachePaths,
        () => paths.getExternalStoragePaths(),
      ]) {
        await expectLater(
          request(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'fixture-filesystem-refused',
            ),
          ),
        );
      }
      final cache = CacheManager(
        Config(
          'unit-memory-only',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
        ),
      );
      addTearDown(cache.dispose);
      final file = await cache.putFile(
          'https://invalid.example/image', Uint8List.fromList([1, 2, 3]));
      expect(await file.readAsBytes(), [1, 2, 3]);
    },
  );
  test('interrupted or shortened scroll legs cannot satisfy workload', () {
    const ProfileScrollLeg(
      target: 500,
      offset: 500,
      elapsedUs: 2000000,
      requestedUs: 2000000,
    ).requireComplete();
    for (final observation in [
      const ProfileScrollLeg(
        target: double.nan,
        offset: 500,
        elapsedUs: 2000000,
        requestedUs: 2000000,
      ),
      const ProfileScrollLeg(
        target: 500,
        offset: double.infinity,
        elapsedUs: 2000000,
        requestedUs: 2000000,
      ),
      const ProfileScrollLeg(
        target: 500,
        offset: 100,
        elapsedUs: 2000000,
        requestedUs: 2000000,
      ),
      const ProfileScrollLeg(
        target: 500,
        offset: 500,
        elapsedUs: 100,
        requestedUs: 2000000,
      ),
    ]) {
      expect(observation.requireComplete, throwsStateError);
    }
  });
  void validate({
    String endpoint = 'http://127.0.0.1:54761/api/v1',
    String resolved = 'http://127.0.0.1:54761/api/v1',
    String? commit,
    String? tree,
    String? manifest,
    String run = 'run-01',
  }) {
    PerformanceFixture.validateIdentity(
      endpoint: endpoint,
      resolvedEndpoint: resolved,
      commit: commit ?? 'a' * 40,
      tree: tree ?? 'b' * 40,
      manifestHash: manifest ?? 'c' * 64,
      run: run,
    );
  }

  test('strict endpoint and source/run identities fail closed', () {
    validate();
    for (final endpoint in [
      'http://localhost:54761/api/v1',
      'http://127.0.0.1:54761/api/v1/',
      'https://127.0.0.1:54761/api/v1',
      'http://127.0.0.1:8080/api/v1',
      'http://127.0.0.1:54761/api/v1?x=1',
    ]) {
      expect(() => validate(endpoint: endpoint), throwsStateError);
    }
    expect(
      () => validate(resolved: 'http://localhost:8080/api/v1'),
      throwsStateError,
    );
    expect(() => validate(commit: 'HEAD'), throwsStateError);
    expect(() => validate(tree: 'B' * 40), throwsStateError);
    expect(() => validate(manifest: '0' * 63), throwsStateError);
    for (final run in ['', '../run', 'run/path', 'run\n']) {
      expect(() => validate(run: run), throwsStateError);
    }
  });
  Map<String, Object?> descriptor() => {
        'schema': 'soundq.flutter.fixture.process.v1',
        'endpoint': 'http://127.0.0.1:54761/api/v1',
        'email': 'disposable@example.invalid',
        'password': 'private',
        'run_id': 'run-01',
        'source_commit': 'a' * 40,
        'source_tree': 'b' * 40,
        'source_manifest_sha256': 'c' * 64,
        'report_token': 'd' * 64,
      };
  Map<String, String> admit(String raw) =>
      PerformanceFixture.validateDescriptor(
        raw,
        endpoint: 'http://127.0.0.1:54761/api/v1',
        resolvedEndpoint: 'http://127.0.0.1:54761/api/v1',
        commit: 'a' * 40,
        tree: 'b' * 40,
        manifestHash: 'c' * 64,
      );
  test(
    'bounded process descriptor requires exact keys types pins credentials token',
    () {
      expect(admit(jsonEncode(descriptor()))['run_id'], 'run-01');
      final encoded = jsonEncode(descriptor());
      expect(() => admit(encoded.replaceFirst('{', '{"email":"duplicate",')),
          throwsStateError);
      expect(
          admit(jsonEncode({
            ...descriptor(),
            'password': 'quote " : , unicode é'
          }))['password'],
          'quote " : , unicode é');
      for (final mutation in <Map<String, Object?>>[
        {'schema': 'soundq.flutter.fixture.credentials.v1'},
        {'endpoint': 'http://localhost:54761/api/v1'},
        {'endpoint': 'http://127.0.0.1:54762/report'},
        {'source_commit': 'b' * 40},
        {'source_tree': 'a' * 40},
        {'source_manifest_sha256': 'e' * 64},
        {'source_commit': 'A' * 40},
        {'run_id': '../run'},
        {'run_id': 'x' * 81},
        {'run_id': 'run\n'},
        {'email': ''},
        {'email': 'é' * 161},
        {'email': 2},
        {'password': ''},
        {'password': 'é' * 2049},
        {'password': null},
        {'report_token': 'D' * 64},
        {'report_token': 'd' * 63},
        {'report_token': 'd' * 64 + '\n'},
        {'extra': 'unknown'},
        {'root': '/personal'},
        {'output': '/tmp/output'},
      ]) {
        expect(
          () => admit(jsonEncode({...descriptor(), ...mutation})),
          throwsStateError,
          reason: mutation.keys.join(','),
        );
      }
      for (final key in descriptor().keys) {
        final missing = descriptor()..remove(key);
        expect(() => admit(jsonEncode(missing)), throwsStateError);
      }
      final boundary = descriptor()
        ..['email'] = 'é' * 160
        ..['password'] = 'é' * 2048;
      expect(admit(jsonEncode(boundary))['email'], 'é' * 160);
      for (final raw in [
        '',
        '[]',
        'NaN',
        'Infinity',
        '{"run_id":NaN}',
        ' ' * 16385,
      ]) {
        expect(() => admit(raw), throwsStateError);
      }
    },
  );
  test('report acknowledgement binds persisted bytes and run exactly', () {
    final ack = {'run_id': 'run-01', 'sha256': 'a' * 64, 'persisted': true};
    void validate(Map<String, Object?> value) =>
        PerformanceFixture.validateAcknowledgement(
          utf8.encode(jsonEncode(value)),
          'run-01',
          'a' * 64,
        );
    validate(ack);
    for (final mutation in [
      {'run_id': 'other'},
      {'sha256': 'b' * 64},
      {'persisted': false},
      {'persisted': 1},
      {'extra': true},
    ]) {
      expect(() => validate({...ack, ...mutation}), throwsStateError);
    }
    expect(
      () => PerformanceFixture.validateAcknowledgement(
        List.filled(4097, 32),
        'run-01',
        'a' * 64,
      ),
      throwsStateError,
    );
  });
  test('default off; opted-in debug preflight cannot reach storage', () async {
    if (performanceFixtureEnabled) {
      await expectLater(PerformanceFixture.preflight(), throwsStateError);
      expect(() => SecureStorage(), throwsStateError);
      expect(
        () => SecureStorage(tokenStorage: EphemeralFixtureTokens()),
        throwsStateError,
      );
    } else {
      await PerformanceFixture.preflight();
      expect(PerformanceFixture.active, isNull);
      expect(fixtureTokenBackend, throwsStateError);
    }
  });
  test(
    'fixture construction shares credentials and retirement fences',
    () async {
      if (!performanceFixtureEnabled) return;
      installFixtureTokens();
      final first = SecureStorage();
      // Explicit caller backends cannot escape the fixture process backend.
      final second = SecureStorage(tokenStorage: EphemeralFixtureTokens());
      await first.saveTokens(accessToken: 'access', refreshToken: 'refresh');
      expect(await second.getAccessToken(), 'access');
      final scope = second.captureSession();
      expect(first.accepts(scope), isTrue);
      await second.clearTokens();
      expect(first.accepts(scope), isFalse);
      expect(await first.getRefreshToken(), isNull);
      expect(await first.isBiometricUnlockEnabled(), isFalse);
      await expectLater(
        first.setBiometricUnlockEnabled(true),
        throwsStateError,
      );
    },
  );
}

class _DatabasePaths implements DatabaseFactory {
  final calls = <String>[];
  String path = '/personal';
  bool ignoreSet = false;
  @override
  Future<void> setDatabasesPath(String value) async {
    calls.add('set:$value');
    if (!ignoreSet) path = value;
  }

  @override
  Future<String> getDatabasesPath() async {
    calls.add('get');
    return path;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
