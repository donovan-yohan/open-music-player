import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web/web.dart' as web;

import 'token_storage_backend.dart';

TokenStorageBackend createTokenStorageBackend({FlutterSecureStorage? storage}) {
  return WebSessionTokenStorage();
}

class WebSessionTokenStorage implements TokenStorageBackend {
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _biometricUnlockKey = 'biometric_unlock_enabled';

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    _clearLegacyDurableTokens();
    web.window.sessionStorage.setItem(_accessTokenKey, accessToken);
    web.window.sessionStorage.setItem(_refreshTokenKey, refreshToken);
  }

  @override
  Future<String?> getAccessToken() async {
    _clearLegacyDurableTokens();
    return web.window.sessionStorage.getItem(_accessTokenKey);
  }

  @override
  Future<String?> getRefreshToken() async {
    _clearLegacyDurableTokens();
    return web.window.sessionStorage.getItem(_refreshTokenKey);
  }

  @override
  Future<void> clearTokens() async {
    web.window.sessionStorage.removeItem(_accessTokenKey);
    web.window.sessionStorage.removeItem(_refreshTokenKey);
    web.window.sessionStorage.removeItem(_biometricUnlockKey);
    _clearLegacyDurableTokens();
  }

  @override
  Future<bool> hasTokens() async {
    final refreshToken = await getRefreshToken();
    return refreshToken != null && refreshToken.isNotEmpty;
  }

  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    if (enabled) {
      web.window.sessionStorage.setItem(_biometricUnlockKey, 'true');
    } else {
      web.window.sessionStorage.removeItem(_biometricUnlockKey);
    }
  }

  @override
  Future<bool> isBiometricUnlockEnabled() async {
    return web.window.sessionStorage.getItem(_biometricUnlockKey) == 'true';
  }

  void _clearLegacyDurableTokens() {
    _removeDurableToken(_accessTokenKey);
    _removeDurableToken(_refreshTokenKey);
  }

  void _removeDurableToken(String key) {
    web.window.localStorage.removeItem(key);
    web.window.localStorage.removeItem('flutter.$key');
  }
}
