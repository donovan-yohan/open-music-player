import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'support/mock_dio_client.dart';

void main() {
  test('real Dio request retains configured API prefix and nondefault port',
      () async {
    const configured = String.fromEnvironment('OMP_API_BASE_URL',
        defaultValue: 'http://localhost:8080/api/v1');
    final expectedBase = configured.replaceFirst(RegExp(r'/$'), '');
    expect(Uri.parse(expectedBase).path, endsWith('/api/v1'));
    var requests = 0;
    final api = mockQueueApiClient((request) async {
      requests++;
      expect(request.url.toString(), '$expectedBase/library?limit=2');
      return http.Response('{}', 200);
    });
    await api.get('/library', queryParameters: {'limit': 2});
    expect(requests, 1);
  });
  test('API endpoint rejects ambiguous or unsafe URLs', () {
    for (final value in [
      '',
      'https://host.test',
      'https://host.test/',
      'https://host.test/music',
      'https://host.test/api/v2',
      'https://host.test/api/v1/library',
      'https://host.test/music/api/v10',
      'ftp://host.test/api',
      'https://u:p@api.example.test/api',
      'https://host.test/api?q=1',
      'https://host.test/api#x',
      'https://host.test/a//b',
      'https://host.test/a/../b',
      'https://host.test/a%2fb',
      'https://host.test:99999/api',
      'https://host.test/a%xx',
      ' https://host.test/api',
      'https://host.test/a\\b'
    ]) {
      expect(() => ApiClient.validateBaseUrl(value), throwsFormatException,
          reason: value);
    }
    expect(ApiClient.validateBaseUrl('https://host.test:9443/prefix/api/v1/'),
        'https://host.test:9443/prefix/api/v1');
  });
  for (final code in [...List.generate(32, (index) => index), 127]) {
    test(
        'literal ASCII control U+${code.toRadixString(16).padLeft(4, '0')} '
        'rejects before URI normalization', () {
      final control = String.fromCharCode(code);
      const url = 'https://api.example.test/prefix/api/v1';
      for (final value in [
        '$control$url',
        '$url$control',
        'https://${control}api.example.test/prefix/api/v1',
        'https://api.example.test/a${control}b/api/v1',
      ]) {
        expect(() => ApiClient.validateBaseUrl(value), throwsFormatException,
            reason: 'literal control $code');
      }
      final encoded = code.toRadixString(16).padLeft(2, '0');
      expect(
          () => ApiClient.validateBaseUrl(
              'https://api.example.test/a%${encoded}b/api/v1'),
          throwsFormatException);
    });
  }
  test('spaces and malformed authorities reject without being repaired', () {
    for (final value in [
      ' https://api.example.test/api/v1',
      'https://api.example.test/api/v1 ',
      'https://api.example.test/a b/api/v1',
      'https:///api.example.test/api/v1',
    ]) {
      expect(() => ApiClient.validateBaseUrl(value), throwsFormatException,
          reason: value);
    }
  });
  test('API endpoint rejects percent-encoded ASCII control characters', () {
    for (final value in [
      'https://host.test/a%00b',
      'https://host.test/a%09b',
      'https://host.test/a%0Ab',
      'https://host.test/a%1fb',
      'https://host.test/a%7Fb',
    ]) {
      expect(() => ApiClient.validateBaseUrl(value), throwsFormatException,
          reason: value);
    }
  });
  test(
      'compile-time API URL preserves prefix and port and normalizes trailing slash',
      () {
    const configured = String.fromEnvironment('OMP_API_BASE_URL',
        defaultValue: 'http://localhost:8080/api/v1');
    expect(ApiClient.baseUrl, configured.replaceFirst(RegExp(r'/+$'), ''));
  });
}
