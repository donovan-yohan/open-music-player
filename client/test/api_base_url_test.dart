import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/mock_dio_client.dart';

const _expectedBaseUrl = String.fromEnvironment(
  'OMP_API_BASE_URL',
  defaultValue: 'https://soundq.fish-rattlesnake.ts.net/api/v1',
);

void main() {
  test('canonical API transport uses the configured home-lab destination',
      () async {
    Uri? requestUrl;
    final client = mockQueueApiClient((request) async {
      requestUrl = request.url;
      return http.Response('{}', 200);
    });

    await client.get<Map<String, dynamic>>(
      '/tracks',
      queryParameters: {'limit': 10},
    );

    expect(requestUrl, Uri.parse('$_expectedBaseUrl/tracks?limit=10'));
  });
}
