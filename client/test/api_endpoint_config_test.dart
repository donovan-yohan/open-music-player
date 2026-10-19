import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'support/mock_dio_client.dart';

void main() {
  test('real Dio request retains configured API prefix and nondefault port',
      () async {
    final api = mockQueueApiClient((request) async {
      expect(request.url.toString(), '${ApiClient.baseUrl}/library?limit=2');
      return http.Response('{}', 200);
    });
    await api.get('/library', queryParameters: {'limit': 2});
  });
  test('API endpoint rejects ambiguous or unsafe URLs', () {
    for (final value in [
      '',
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
