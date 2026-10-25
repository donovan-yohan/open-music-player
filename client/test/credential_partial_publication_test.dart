import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/api/api_endpoint.dart';
import 'package:open_music_player/core/platform/desktop_initialization.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/token_storage_secure.dart';

import 'connect_auth_scope_test.dart' as support;

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final _accessKey = 'access_token:${ApiEndpoint.baseUrl}';
final _refreshKey = 'refresh_token:${ApiEndpoint.baseUrl}';
final _biometricKey = 'biometric_unlock_enabled:${ApiEndpoint.baseUrl}';

/// Exercise the real two-write backend, mocking only the hardware boundary.
class _PartialKeychain {
  final values = <String, String>{
    _accessKey: 'old',
    _refreshKey: 'old-refresh',
    _biometricKey: 'true',
  };
  final started = Completer<void>();
  final failAccess = Completer<void>();
  final releaseRefresh = Completer<void>();
  final events = <String>[];
  final acceptedRefreshWrites = <String>[];
  int writes = 0;
  int deletes = 0;
  bool failCleanup = false;
  Completer<void>? cleanupGate;
  final cleanupStarted = Completer<void>();

  SecureStorage install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          writes++;
          if (writes == 2) started.complete();
          if (args['value'] == 'partial-access') {
            await failAccess.future;
            events.add('access-failed');
            throw PlatformException(code: 'keychain_write_failed');
          }
          if (args['value'] == 'partial-refresh') {
            await releaseRefresh.future;
            acceptedRefreshWrites.add(args['value'] as String);
            events.add('partial-refresh-written');
          }
          values[key] = args['value'] as String;
          events.add('write:$key:${args['value']}');
          return null;
        case 'delete':
          deletes++;
          events.add('delete:$key');
          if (!cleanupStarted.isCompleted) cleanupStarted.complete();
          await cleanupGate?.future;
          if (failCleanup) {
            throw PlatformException(code: 'keychain_delete_failed');
          }
          values.remove(key);
          return null;
      }
      throw StateError('Unexpected keychain method ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null));
    return SecureStorage(
        tokenStorage: SecureTokenStorage(storage: applicationSecureStorage()));
  }

  void release() {
    failAccess.complete();
    releaseRefresh.complete();
  }
}

class _PartialMemory extends support.MemoryTokens {
  final started = Completer<void>();
  final release = Completer<void>();
  final cleanupStarted = Completer<void>();
  Completer<void>? cleanupGate;
  bool failCleanup = false;
  int saves = 0;
  int clears = 0;

  @override
  Future<void> saveTokens(
      {required String accessToken, required String refreshToken}) async {
    saves++;
    if (accessToken != 'partial-access') {
      return super
          .saveTokens(accessToken: accessToken, refreshToken: refreshToken);
    }
    started.complete();
    await release.future;
    refresh = refreshToken;
    throw StateError('partial publication');
  }

  @override
  Future<void> clearTokens() async {
    clears++;
    cleanupStarted.complete();
    await cleanupGate?.future;
    if (failCleanup) throw StateError('cleanup failed');
    await super.clearTokens();
  }
}

enum _Publication { refresh, login }

Future<bool> _publish(SecureStorage storage, _Publication publication) {
  final api = support.client(
      storage,
      support.Wire((_) => support.reply({
            'accessToken': 'partial-access',
            'refreshToken': 'partial-refresh',
          })));
  if (publication == _Publication.refresh) return api.refreshSession();
  return AuthService(api: api, storage: storage)
      .login(email: 'account-b@example.test', password: 'test')
      .then((result) => result.success);
}

void _expectFailure(Object? outcome, _Publication publication,
    {String code = 'keychain_write_failed'}) {
  if (publication == _Publication.login) {
    expect(outcome, isFalse);
  } else {
    expect(
        outcome, isA<PlatformException>().having((e) => e.code, 'code', code));
  }
}

Future<Object?> _outcome(Future<Object?> operation) =>
    operation.then<Object?>((value) => value, onError: (Object e) => e);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('native revoked refresh cleans a partial rotated publication', () async {
    final keychain = _PartialKeychain();
    final storage = keychain.install();
    final scope = storage.captureSession();
    final api = support.client(
        storage,
        support.Wire((_) => support.reply({
              'accessToken': 'partial-access',
              'refreshToken': 'partial-refresh',
            })));
    final outcome = _outcome(api.refreshSession());
    await keychain.started.future;
    storage.beginAuthIntent();
    keychain.release();
    expect(await outcome, isA<PlatformException>());
    // Positive evidence that refresh publication reached the channel before
    // cleanup; do not assert a contradictory intermediate durable value.
    expect(keychain.acceptedRefreshWrites, ['partial-refresh']);
    expect(keychain.writes, 2);
    expect(keychain.deletes, 3);
    expect(keychain.values, isEmpty);
    expect(scope.isCurrent, isFalse);
  });

  test('native revoked login cleans a partial publication', () async {
    final keychain = _PartialKeychain();
    final storage = keychain.install();
    final api = support.client(
        storage,
        support.Wire((_) => support.reply({
              'accessToken': 'partial-access',
              'refreshToken': 'partial-refresh',
            })));
    final auth = AuthService(api: api, storage: storage);
    final login = auth.login(email: 'account-b@example.test', password: 'test');
    await keychain.started.future;
    storage.beginAuthIntent();
    keychain.release();
    expect((await login).success, isFalse);
    expect(keychain.acceptedRefreshWrites, ['partial-refresh']);
    expect(keychain.writes, 2);
    expect(keychain.deletes, 3);
    expect(keychain.values, isEmpty);
    expect(storage.captureSession().isCurrent, isFalse);
  });

  for (final publication in _Publication.values) {
    test('native ${publication.name} failure retires a nonrevoked scope',
        () async {
      final keychain = _PartialKeychain();
      final storage = keychain.install();
      final oldScope = storage.captureSession();
      final outcome = _outcome(_publish(storage, publication));
      await keychain.started.future;
      final publicationEpoch = storage.sessionEpoch;
      keychain.release();
      _expectFailure(await outcome, publication);
      expect(storage.sessionEpoch, greaterThan(publicationEpoch));
      expect(keychain.acceptedRefreshWrites, ['partial-refresh']);
      expect(keychain.values, isEmpty);
      expect(keychain.deletes, 3);
      expect(oldScope.isCurrent, isFalse);
      expect(storage.captureSession().isCurrent, isFalse);
      expect(await storage.accessTokenFor(oldScope), isNull);
    });

    test('native ${publication.name} waits for sibling write before cleanup',
        () async {
      final keychain = _PartialKeychain();
      final storage = keychain.install();
      var settled = false;
      final outcome = _outcome(_publish(storage, publication))
          .whenComplete(() => settled = true);
      await keychain.started.future;
      keychain.failAccess.complete();
      await support.turn();
      expect(keychain.events, contains('access-failed'));
      expect(keychain.deletes, 0);
      expect(settled, isFalse);
      keychain.releaseRefresh.complete();
      _expectFailure(await outcome, publication);
      expect(keychain.acceptedRefreshWrites, ['partial-refresh']);
      expect(keychain.values, isEmpty);
      expect(keychain.events.indexOf('partial-refresh-written'),
          lessThan(keychain.events.indexOf('delete:$_refreshKey')));
    });

    for (final revoked in [false, true]) {
      test(
          'memory ${publication.name} partial failure cleans tokens '
          '(revoked: $revoked)', () async {
        final backend = _PartialMemory();
        final storage = SecureStorage(tokenStorage: backend);
        final outcome = _outcome(_publish(storage, publication));
        await backend.started.future;
        if (revoked) storage.beginAuthIntent();
        backend.release.complete();
        final result = await outcome;
        expect(result,
            publication == _Publication.login ? isFalse : isA<StateError>());
        expect(backend.saves, 1);
        expect(backend.clears, 1);
        expect(backend.access, isNull);
        expect(backend.refresh, isNull);
        expect(storage.captureSession().isCurrent, isFalse);
      });

      test(
          'native ${publication.name} cleanup failure stays locally revoked '
          '(revoked: $revoked)', () async {
        final keychain = _PartialKeychain()..failCleanup = true;
        final storage = keychain.install();
        final oldScope = storage.captureSession();
        final outcome = _outcome(_publish(storage, publication));
        await keychain.started.future;
        if (revoked) storage.beginAuthIntent();
        keychain.release();
        _expectFailure(await outcome, publication,
            code: 'keychain_delete_failed');
        expect(keychain.acceptedRefreshWrites, ['partial-refresh']);
        expect(keychain.values[_refreshKey], 'partial-refresh',
            reason: 'Deletion failed; do not claim durable cleanup succeeded');
        expect(keychain.deletes, 3);
        expect(oldScope.isCurrent, isFalse);
        expect(storage.captureSession().isCurrent, isFalse);
        expect(await storage.accessTokenFor(oldScope), isNull);
        final wire = support.Wire((_) => support.reply({}));
        expect(await support.client(storage, wire).refreshSession(), isFalse);
        expect(wire.requests, isEmpty);
      });

      test(
          'memory ${publication.name} cleanup failure stays locally revoked '
          '(revoked: $revoked)', () async {
        final backend = _PartialMemory()..failCleanup = true;
        final storage = SecureStorage(tokenStorage: backend);
        final oldScope = storage.captureSession();
        final outcome = _outcome(_publish(storage, publication));
        await backend.started.future;
        if (revoked) storage.beginAuthIntent();
        backend.release.complete();
        final result = await outcome;
        if (publication == _Publication.login) {
          expect(result, isFalse);
        } else {
          expect(
              result,
              isA<StateError>()
                  .having((e) => e.message, 'message', 'cleanup failed'));
        }
        expect(backend.clears, 1);
        expect(backend.refresh, 'partial-refresh');
        expect(oldScope.isCurrent, isFalse);
        expect(storage.captureSession().isCurrent, isFalse);
        expect(await storage.accessTokenFor(oldScope), isNull);
      });
    }

    for (final failCleanup in [false, true]) {
      test(
          'native ${publication.name} holds lane through cleanup and preserves '
          'queued replacement (cleanup fails: $failCleanup)', () async {
        final keychain = _PartialKeychain()
          ..cleanupGate = Completer<void>()
          ..failCleanup = failCleanup;
        final storage = keychain.install();
        final outcome = _outcome(_publish(storage, publication));
        await keychain.started.future;
        final intent = storage.beginAuthIntent();
        final newer = storage.saveTokensForIntent(intent,
            accessToken: 'new-access', refreshToken: 'new-refresh');
        keychain.release();
        await keychain.cleanupStarted.future;
        await support.turn();
        expect(keychain.writes, 2,
            reason: 'Replacement may not publish while deletion is pending');
        expect(storage.ownsIntent(intent), isTrue,
            reason:
                'Failure must not revoke an independently newer auth intent');
        keychain.cleanupGate!.complete();
        _expectFailure(await outcome, publication,
            code: failCleanup
                ? 'keychain_delete_failed'
                : 'keychain_write_failed');
        expect(await newer, isTrue);
        expect(keychain.writes, 4);
        expect(keychain.deletes, 3);
        expect(keychain.values[_accessKey], 'new-access');
        expect(keychain.values[_refreshKey], 'new-refresh');
        expect(storage.captureSession().isCurrent, isTrue);
        expect(
            keychain.events.indexOf('delete:$_refreshKey'),
            lessThan(
                keychain.events.indexOf('write:$_refreshKey:new-refresh')));
      });

      test(
          'memory ${publication.name} preserves newer save after cleanup '
          '(cleanup fails: $failCleanup)', () async {
        final backend = _PartialMemory()
          ..cleanupGate = Completer<void>()
          ..failCleanup = failCleanup;
        final storage = SecureStorage(tokenStorage: backend);
        final outcome = _outcome(_publish(storage, publication));
        await backend.started.future;
        final newer = storage.saveTokens(
            accessToken: 'new-access', refreshToken: 'new-refresh');
        backend.release.complete();
        await backend.cleanupStarted.future;
        await support.turn();
        expect(backend.saves, 1);
        backend.cleanupGate!.complete();
        expect(await outcome,
            publication == _Publication.login ? isFalse : isA<StateError>());
        await newer;
        expect(backend.saves, 2);
        expect(backend.clears, 1);
        expect(backend.access, 'new-access');
        expect(backend.refresh, 'new-refresh');
        expect(storage.captureSession().isCurrent, isTrue);
      });
    }
  }

  test('failed account-B login cannot leave partial account-A refresh durable',
      () async {
    final keychain = _PartialKeychain();
    final storage = keychain.install();
    final api = support.client(
        storage,
        support.Wire((o) => o.path == '/auth/login'
            ? support.reply({'code': 'INVALID_CREDENTIALS'}, 401)
            : support.reply({
                'accessToken': 'partial-access',
                'refreshToken': 'partial-refresh',
              })));
    final outcome = _outcome(api.refreshSession());
    await keychain.started.future;
    final switched = await AuthService(api: api, storage: storage)
        .login(email: 'account-b@example.test', password: 'wrong');
    expect(switched.success, isFalse);
    keychain.release();
    expect(await outcome, isA<PlatformException>());
    expect(keychain.writes, 2,
        reason: 'No newer successful save masked cleanup');
    expect(keychain.acceptedRefreshWrites, ['partial-refresh']);
    expect(keychain.deletes, 3);
    expect(keychain.values, isEmpty);
    expect(storage.captureSession().isCurrent, isFalse);
  });
}
