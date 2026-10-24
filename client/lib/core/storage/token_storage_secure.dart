import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_storage_backend.dart';
import '../api/api_endpoint.dart';

TokenStorageBackend createTokenStorageBackend({FlutterSecureStorage? storage}) {
  return SecureTokenStorage(
    storage: storage ??
        const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock,
          ),
        ),
  );
}

class SecureTokenStorage implements TokenStorageBackend {
  // Never adopt unbound credentials from a prior host/build. First upgrade
  // requires sign-in; each endpoint then keeps its own secure session.
  static final _accessTokenKey = 'access_token:${ApiEndpoint.baseUrl}';
  static final _refreshTokenKey = 'refresh_token:${ApiEndpoint.baseUrl}';
  static final _biometricUnlockKey =
      'biometric_unlock_enabled:${ApiEndpoint.baseUrl}';

  final FlutterSecureStorage _storage;

  SecureTokenStorage({required FlutterSecureStorage storage})
      : _storage = storage;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await Future.wait([
      _storage.write(key: _accessTokenKey, value: accessToken),
      _storage.write(key: _refreshTokenKey, value: refreshToken),
    ]);
  }

  @override
  Future<String?> getAccessToken() {
    return _storage.read(key: _accessTokenKey);
  }

  @override
  Future<String?> getRefreshToken() {
    return _storage.read(key: _refreshTokenKey);
  }

  @override
  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: _accessTokenKey),
      _storage.delete(key: _refreshTokenKey),
      _storage.delete(key: _biometricUnlockKey),
    ]);
  }

  @override
  Future<bool> hasTokens() async {
    final refreshToken = await getRefreshToken();
    return refreshToken != null && refreshToken.isNotEmpty;
  }

  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    if (enabled) {
      await _storage.write(key: _biometricUnlockKey, value: 'true');
    } else {
      await _storage.delete(key: _biometricUnlockKey);
    }
  }

  @override
  Future<bool> isBiometricUnlockEnabled() async {
    return await _storage.read(key: _biometricUnlockKey) == 'true';
  }
}
