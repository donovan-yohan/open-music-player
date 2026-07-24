import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/formatters/byte_formatter.dart';

void main() {
  test('formatBytes preserves unit thresholds and formats gigabytes', () {
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    expect(formatBytes(5 * 1024 * 1024 * 1024 ~/ 4), '1.25 GB');
  });
}
