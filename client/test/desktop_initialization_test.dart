import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/platform/desktop_initialization.dart';

void main() {
  test(
      'macOS uses private login keychain without a distribution team entitlement',
      () {
    final storage = applicationSecureStorage();
    expect(storage.mOptions.toMap()['useDataProtectionKeyChain'], 'false');
    // Preserve the existing mobile storage security policy.
    expect(storage.aOptions.toMap()['encryptedSharedPreferences'], 'true');
    expect(storage.iOptions.toMap()['accessibility'], 'first_unlock');
  });
}
