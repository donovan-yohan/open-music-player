import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/router.dart';

void main() {
  test('safeLoginRedirectNext preserves shared import deep links', () {
    final shared = Uri(
      path: '/share',
      queryParameters: {
        'text': 'https://youtu.be/test-video',
        'auto': '1',
      },
    ).toString();

    expect(safeLoginRedirectNext(shared), shared);
  });

  test('safeLoginRedirectNext rejects unsafe or looping redirects', () {
    expect(safeLoginRedirectNext(null), isNull);
    expect(safeLoginRedirectNext('https://evil.test/share'), isNull);
    expect(safeLoginRedirectNext('//evil.test/share'), isNull);
    expect(safeLoginRedirectNext('/login?next=/share'), isNull);
    expect(safeLoginRedirectNext('/register'), isNull);
  });
}
