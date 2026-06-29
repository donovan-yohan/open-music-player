import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

abstract interface class BiometricUnlockService {
  Future<bool> isDeviceUnlockAvailable();

  Future<bool> authenticate({required String reason});
}

class LocalAuthBiometricUnlockService implements BiometricUnlockService {
  LocalAuthBiometricUnlockService({LocalAuthentication? localAuthentication})
      : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> isDeviceUnlockAvailable() async {
    if (kIsWeb) return false;

    try {
      return _localAuthentication.isDeviceSupported();
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate({required String reason}) async {
    if (!await isDeviceUnlockAvailable()) return false;

    try {
      return _localAuthentication.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
