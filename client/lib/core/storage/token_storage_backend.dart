abstract interface class TokenStorageBackend {
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  });

  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> clearTokens();
  Future<bool> hasTokens();
  Future<void> setBiometricUnlockEnabled(bool enabled);
  Future<bool> isBiometricUnlockEnabled();
}
