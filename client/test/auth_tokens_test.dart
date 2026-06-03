import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/auth/auth_tokens.dart';

void main() {
  group('parseAuthTokens', () {
    test('parses backend camelCase response fields', () {
      final tokens = parseAuthTokens({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
      });

      expect(tokens.accessToken, 'access-token');
      expect(tokens.refreshToken, 'refresh-token');
    });

    test('falls back to legacy snake_case response fields', () {
      final tokens = parseAuthTokens({
        'access_token': 'legacy-access-token',
        'refresh_token': 'legacy-refresh-token',
      });

      expect(tokens.accessToken, 'legacy-access-token');
      expect(tokens.refreshToken, 'legacy-refresh-token');
    });
  });

  test('refreshTokenPayload uses backend camelCase request field', () {
    expect(refreshTokenPayload('refresh-token'), {
      'refreshToken': 'refresh-token',
    });
  });
}
