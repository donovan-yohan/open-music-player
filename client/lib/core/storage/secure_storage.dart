import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_storage_backend.dart';
import 'token_storage_platform.dart';
import '../platform/desktop_initialization.dart';

/// An explicit capability for one local authenticated lifetime, not a JWT.
/// Refresh rotation preserves it; account intent/replacement revokes it.
class AuthSessionScope {
  AuthSessionScope._(this._owner, this.epoch, this._admitted);
  final _TokenSession _owner;
  final int epoch;
  final bool _admitted;
  bool get isCurrent => _admitted && _owner.ready && epoch == _owner.epoch;
}

class _TokenSession extends ChangeNotifier {
  int epoch = 0;
  int credentials = 0;
  bool ready = true;
  Future<void>? tail;
  Future<bool>? refresh;
  int? refreshEpoch;
  Future<T> serial<T>(Future<T> Function() action) {
    final previous = tail;
    final result = previous == null
        ? Future<T>.sync(action)
        : previous.then((_) => action());
    late final Future<void> barrier;
    barrier = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
      if (identical(tail, barrier)) tail = null;
    });
    tail = barrier;
    return result;
  }

  void changed() => notifyListeners();
  void revoke() {
    epoch++;
    credentials++;
    ready = false;
    notifyListeners();
  }
}

class SecureStorage {
  static final _defaultSession = _TokenSession();
  static final _sessions = Expando<_TokenSession>();
  final TokenStorageBackend _tokens;
  final _TokenSession _session;

  SecureStorage(
      {FlutterSecureStorage? storage, TokenStorageBackend? tokenStorage})
      : _tokens = tokenStorage ?? createTokenStorageBackend(storage: storage),
        _session = tokenStorage != null
            ? (_sessions[tokenStorage] ??= _TokenSession())
            : storage != null && !identical(storage, applicationSecureStorage())
                ? (_sessions[storage] ??= _TokenSession())
                : _defaultSession;

  Listenable get sessionChanges => _session;
  int get sessionEpoch => _session.epoch;
  AuthSessionScope captureSession() =>
      AuthSessionScope._(_session, _session.epoch, _session.ready);
  AuthSessionScope beginAuthIntent() {
    _session.revoke();
    return AuthSessionScope._(_session, _session.epoch, true);
  }

  bool ownsIntent(AuthSessionScope scope) =>
      identical(scope._owner, _session) && scope.epoch == _session.epoch;
  bool accepts(AuthSessionScope scope) => ownsIntent(scope) && scope.isCurrent;

  Future<void> saveTokens(
      {required String accessToken, required String refreshToken}) async {
    final scope = beginAuthIntent();
    await saveTokensForIntent(scope,
        accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<bool> saveTokensForIntent(AuthSessionScope scope,
          {required String accessToken, required String refreshToken}) =>
      _session.serial(() async {
        if (!ownsIntent(scope)) return false;
        if (!await _publishTokens(scope,
            accessToken: accessToken, refreshToken: refreshToken)) {
          return false;
        }
        _session.credentials++;
        _session.ready = true;
        _session.changed();
        return true;
      });

  /// Called only inside the credential lane. A backend may publish one token
  /// before another write fails, so every failed save must finish cleanup before
  /// a queued replacement can run. Revoke locally even if deletion also fails.
  Future<bool> _publishTokens(AuthSessionScope scope,
      {required String accessToken, required String refreshToken}) async {
    try {
      await _tokens.saveTokens(
          accessToken: accessToken, refreshToken: refreshToken);
    } catch (_) {
      if (ownsIntent(scope)) _session.revoke();
      await _tokens.clearTokens();
      rethrow;
    }
    if (!ownsIntent(scope)) {
      await _tokens.clearTokens();
      return false;
    }
    return true;
  }

  Future<String?> accessTokenFor(AuthSessionScope scope) =>
      _session.serial(() async {
        if (!accepts(scope)) return null;
        final token = await _tokens.getAccessToken();
        return accepts(scope) ? token : null;
      });
  Future<String?> getAccessToken() => _session.serial(_tokens.getAccessToken);
  Future<String?> getRefreshToken() => _session.serial(_tokens.getRefreshToken);

  /// Rotation is shared by every API client using this credential store.
  Future<bool> refreshSession(
      AuthSessionScope scope,
      Future<({String accessToken, String refreshToken})?> Function(String)
          exchange) {
    if (!accepts(scope)) return Future.value(false);
    if (_session.refresh != null && _session.refreshEpoch == scope.epoch) {
      return _session.refresh!;
    }
    final revision = _session.credentials;
    late final Future<bool> result;
    result = (() async {
      final attempted = await getRefreshToken();
      if (!accepts(scope) || revision != _session.credentials) return false;
      ({String accessToken, String refreshToken})? tokens;
      try {
        if (attempted != null && attempted.isNotEmpty) {
          tokens = await exchange(attempted);
        }
      } catch (_) {/* Conditional retirement below. */}
      return _session.serial(() async {
        if (!accepts(scope) || revision != _session.credentials) return false;
        final current = await _tokens.getRefreshToken();
        if (!accepts(scope) || current != attempted) return false;
        if (tokens == null) {
          _session.revoke();
          final retiredEpoch = _session.epoch;
          await _tokens.clearTokens();
          // Legacy callers without tokens may still make an unauthenticated
          // request. Old scopes stay revoked; a new explicit auth intent must
          // not be reopened by this completion.
          if (_session.epoch == retiredEpoch) _session.ready = true;
          return false;
        }
        if (!await _publishTokens(scope,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken)) {
          return false;
        }
        _session.credentials++;
        return true;
      });
    })()
        .whenComplete(() {
      if (identical(_session.refresh, result)) {
        _session.refresh = null;
        _session.refreshEpoch = null;
      }
    });
    _session.refresh = result;
    _session.refreshEpoch = scope.epoch;
    return result;
  }

  Future<void> clearTokens() {
    final scope = beginAuthIntent();
    return clearTokensForIntent(scope);
  }

  Future<void> clearTokensForIntent(AuthSessionScope scope) =>
      _session.serial(() async {
        if (!ownsIntent(scope)) return;
        await _tokens.clearTokens();
        if (ownsIntent(scope)) await _tokens.setBiometricUnlockEnabled(false);
      });
  Future<bool> hasTokens() => _session.serial(_tokens.hasTokens);
  Future<void> setBiometricUnlockEnabled(bool enabled) =>
      _session.serial(() => _tokens.setBiometricUnlockEnabled(enabled));
  Future<bool> isBiometricUnlockEnabled() =>
      _session.serial(_tokens.isBiometricUnlockEnabled);
}
