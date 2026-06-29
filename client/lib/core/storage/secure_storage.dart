import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_storage_backend.dart';
import 'token_storage_platform.dart';

class SecureStorage {
  final TokenStorageBackend _tokens;

  SecureStorage({
    FlutterSecureStorage? storage,
    TokenStorageBackend? tokenStorage,
  }) : _tokens = tokenStorage ?? createTokenStorageBackend(storage: storage);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) {
    return _tokens.saveTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
    );
  }

  Future<String?> getAccessToken() {
    return _tokens.getAccessToken();
  }

  Future<String?> getRefreshToken() {
    return _tokens.getRefreshToken();
  }

  Future<void> clearTokens() {
    return _tokens.clearTokens();
  }

  Future<bool> hasTokens() {
    return _tokens.hasTokens();
  }

  Future<void> setBiometricUnlockEnabled(bool enabled) {
    return _tokens.setBiometricUnlockEnabled(enabled);
  }

  Future<bool> isBiometricUnlockEnabled() {
    return _tokens.isBiometricUnlockEnabled();
  }
}
