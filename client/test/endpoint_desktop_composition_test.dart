import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_endpoint.dart';
import 'package:open_music_player/core/storage/token_storage_secure.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('endpoint-bound native factory retains platform policy and foreign keys',
      () async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final values = <String, String>{
      'access_token': 'legacy-access',
      'refresh_token:https://other.example.test/api/v1': 'foreign-refresh',
    };
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final args = call.arguments as Map;
      final key = args['key'] as String;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          values[key] = args['value'] as String;
          return null;
        case 'delete':
          values.remove(key);
          return null;
      }
      throw StateError('Unexpected method ${call.method}');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final backend = createTokenStorageBackend();
    expect(await backend.getAccessToken(), isNull);
    await backend.saveTokens(
        accessToken: 'new-access', refreshToken: 'new-refresh');
    await backend.setBiometricUnlockEnabled(true);
    expect(await backend.getAccessToken(), 'new-access');
    expect(await backend.getRefreshToken(), 'new-refresh');
    expect(await backend.isBiometricUnlockEnabled(), isTrue);
    expect(values['access_token:${ApiEndpoint.baseUrl}'], 'new-access');
    expect(values['refresh_token:${ApiEndpoint.baseUrl}'], 'new-refresh');
    expect(values['biometric_unlock_enabled:${ApiEndpoint.baseUrl}'], 'true');
    if (Platform.isMacOS) {
      for (final call in calls) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['useDataProtectionKeyChain'], 'false');
      }
    }
    await backend.clearTokens();
    expect(await backend.hasTokens(), isFalse);
    expect(await backend.isBiometricUnlockEnabled(), isFalse);
    expect(values, {
      'access_token': 'legacy-access',
      'refresh_token:https://other.example.test/api/v1': 'foreign-refresh',
    });
  });
}
