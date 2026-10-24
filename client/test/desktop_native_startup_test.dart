import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/engine/native_playback_backend_io.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';

void main() {
  test('macOS offers prepared playback without loading or starting a device',
      () {
    // Merely constructing the factory must be safe before authentication/play.
    // No dylib is available beside flutter_tester and no OS audio may be opened.
    expect(Platform.environment['SOUNDQ_NATIVE_DEVICE_LIBRARY'], isNull);
    final factory = applicationNativePlaybackFactory(
      ApiClient(storage: SecureStorage()),
      accountIdProvider: () async => null,
    );
    expect(factory, isNotNull);
  }, skip: !Platform.isMacOS);
}
