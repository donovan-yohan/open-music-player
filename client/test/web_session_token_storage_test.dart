@TestOn('browser')

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/storage/token_storage_web.dart';
import 'package:web/web.dart' as web;

void main() {
  const accessTokenKey = 'access_token';
  const refreshTokenKey = 'refresh_token';

  setUp(() {
    web.window.sessionStorage.clear();
    web.window.localStorage.clear();
  });

  tearDown(() {
    web.window.sessionStorage.clear();
    web.window.localStorage.clear();
  });

  test('stores bearer tokens in sessionStorage without durable localStorage',
      () async {
    web.window.localStorage.setItem(accessTokenKey, 'legacy-access');
    web.window.localStorage.setItem(refreshTokenKey, 'legacy-refresh');
    web.window.localStorage.setItem('flutter.$accessTokenKey', 'legacy-access');
    web.window.localStorage.setItem(
      'flutter.$refreshTokenKey',
      'legacy-refresh',
    );

    final storage = WebSessionTokenStorage();

    await storage.saveTokens(
      accessToken: 'session-access',
      refreshToken: 'session-refresh',
    );

    expect(web.window.sessionStorage.getItem(accessTokenKey), 'session-access');
    expect(
      web.window.sessionStorage.getItem(refreshTokenKey),
      'session-refresh',
    );
    expect(web.window.localStorage.getItem(accessTokenKey), isNull);
    expect(web.window.localStorage.getItem(refreshTokenKey), isNull);
    expect(web.window.localStorage.getItem('flutter.$accessTokenKey'), isNull);
    expect(web.window.localStorage.getItem('flutter.$refreshTokenKey'), isNull);
    expect(await storage.getAccessToken(), 'session-access');
    expect(await storage.getRefreshToken(), 'session-refresh');
    expect(await storage.hasTokens(), isTrue);
  });

  test('clearTokens removes session tokens and legacy durable web tokens',
      () async {
    web.window.sessionStorage.setItem(accessTokenKey, 'session-access');
    web.window.sessionStorage.setItem(refreshTokenKey, 'session-refresh');
    web.window.localStorage.setItem(accessTokenKey, 'legacy-access');
    web.window.localStorage.setItem(refreshTokenKey, 'legacy-refresh');
    web.window.localStorage.setItem('flutter.$accessTokenKey', 'legacy-access');
    web.window.localStorage.setItem(
      'flutter.$refreshTokenKey',
      'legacy-refresh',
    );

    final storage = WebSessionTokenStorage();

    await storage.clearTokens();

    expect(web.window.sessionStorage.getItem(accessTokenKey), isNull);
    expect(web.window.sessionStorage.getItem(refreshTokenKey), isNull);
    expect(web.window.localStorage.getItem(accessTokenKey), isNull);
    expect(web.window.localStorage.getItem(refreshTokenKey), isNull);
    expect(web.window.localStorage.getItem('flutter.$accessTokenKey'), isNull);
    expect(web.window.localStorage.getItem('flutter.$refreshTokenKey'), isNull);
    expect(await storage.hasTokens(), isFalse);
  });
}
