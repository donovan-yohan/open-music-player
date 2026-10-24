import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/storage/token_storage_secure.dart';

void main() {
  test('native credentials cannot be adopted by a different endpoint build',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'access_token': 'legacy-access',
      'refresh_token': 'legacy-refresh',
      'access_token:https://other.example.test/api/v1': 'other-access',
    });
    final storage = SecureTokenStorage(storage: const FlutterSecureStorage());
    expect(await storage.getAccessToken(), isNull);
    expect(await storage.getRefreshToken(), isNull);
    await storage.saveTokens(
        accessToken: 'new-access', refreshToken: 'new-refresh');
    expect(await storage.getAccessToken(), 'new-access');
    expect(await storage.getRefreshToken(), 'new-refresh');
    await storage.clearTokens();
    expect(await storage.hasTokens(), false);
  });
}
