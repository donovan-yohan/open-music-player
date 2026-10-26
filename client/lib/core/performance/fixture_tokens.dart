import '../storage/token_storage_backend.dart';

const performanceFixtureEnabled = bool.fromEnvironment(
  'SOUNDQ_PERFORMANCE_FIXTURE',
  defaultValue: false,
);

TokenStorageBackend? _fixtureTokens;

/// Every SecureStorage, including route-local construction, shares this backend
/// and therefore the existing SecureStorage epoch/ACK/refresh fences.
TokenStorageBackend fixtureTokenBackend() {
  if (!performanceFixtureEnabled || _fixtureTokens == null) {
    throw StateError('fixture-preflight-required');
  }
  return _fixtureTokens!;
}

void installFixtureTokens() {
  if (!performanceFixtureEnabled || _fixtureTokens != null) {
    throw StateError('fixture-token-install-refused');
  }
  _fixtureTokens = EphemeralFixtureTokens();
}

class EphemeralFixtureTokens implements TokenStorageBackend {
  String? _access, _refresh;
  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    _access = accessToken;
    _refresh = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => _access;
  @override
  Future<String?> getRefreshToken() async => _refresh;
  @override
  Future<void> clearTokens() async {
    _access = null;
    _refresh = null;
  }

  @override
  Future<bool> hasTokens() async => _refresh?.isNotEmpty ?? false;
  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    if (enabled) throw StateError('fixture-biometric-refused');
  }

  @override
  Future<bool> isBiometricUnlockEnabled() async => false;
}
