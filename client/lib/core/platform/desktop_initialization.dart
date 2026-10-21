import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Preserve mobile policy and use macOS's private login keychain. The default
/// Data Protection keychain requires an Apple team/application entitlement and
/// fails with -34018 in a locally ad-hoc-signed build. No shared access group,
/// cloud synchronization or plaintext credential fallback is used here.
FlutterSecureStorage applicationSecureStorage() => const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
      mOptions: MacOsOptions(useDataProtectionKeyChain: false),
    );
