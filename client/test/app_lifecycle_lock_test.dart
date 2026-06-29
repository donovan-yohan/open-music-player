import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/app.dart';

void main() {
  test('biometric lock is only triggered for durable background states', () {
    expect(
      shouldLockForBiometricLifecycleState(AppLifecycleState.inactive),
      isFalse,
    );
    expect(
      shouldLockForBiometricLifecycleState(AppLifecycleState.resumed),
      isFalse,
    );
    expect(
      shouldLockForBiometricLifecycleState(AppLifecycleState.detached),
      isFalse,
    );
    expect(
      shouldLockForBiometricLifecycleState(AppLifecycleState.paused),
      isTrue,
    );
    expect(
      shouldLockForBiometricLifecycleState(AppLifecycleState.hidden),
      isTrue,
    );
  });
}
