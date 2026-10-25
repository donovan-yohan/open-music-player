import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/platform/desktop_initialization.dart';

void main() {
  test('secure storage lower bound includes the macOS keychain option', () {
    final manifest = File('pubspec.yaml').readAsStringSync();
    final constraint = RegExp(
            r'^\s+flutter_secure_storage:\s*\^(\d+)\.(\d+)\.(\d+)\s*$',
            multiLine: true)
        .firstMatch(manifest);
    expect(constraint, isNotNull);
    final version = [
      for (var i = 1; i <= 3; i++) int.parse(constraint!.group(i)!)
    ];
    expect(
        version[0] > 9 ||
            (version[0] == 9 && version[1] > 2) ||
            (version[0] == 9 && version[1] == 2 && version[2] >= 3),
        isTrue,
        reason:
            'useDataProtectionKeyChain was added in flutter_secure_storage 9.2.3');
  });

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
