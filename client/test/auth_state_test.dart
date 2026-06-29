import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/auth/biometric_unlock_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/token_storage_backend.dart';

void main() {
  group('AuthState.login', () {
    test('clears loading and shows nested backend invalid credentials',
        () async {
      final storage = _MemoryTokenStorage();
      final adapter = _DioAdapter((options) {
        expect(options.uri.path, endsWith('/auth/login'));
        return const _JsonReply(
          {
            'error': {'message': 'invalid email or password'},
          },
          401,
        );
      });
      final authState = _authState(storage: storage, adapter: adapter);

      final success = await authState.login(
        email: 'user@example.com',
        password: 'wrong-password',
      );

      expect(success, isFalse);
      expect(authState.isLoading, isFalse);
      expect(authState.error, 'invalid email or password');
      expect(adapter.requests.where((path) => path.endsWith('/auth/refresh')),
          isEmpty);
    });
  });

  group('AuthState.checkAuthStatus', () {
    test('restores a session by refreshing the stored refresh token', () async {
      final storage = _MemoryTokenStorage(
        accessToken: 'expired-access-token',
        refreshToken: 'valid-refresh-token',
      );
      final adapter = _DioAdapter((options) {
        expect(options.uri.path, endsWith('/auth/refresh'));
        expect(options.data, {'refreshToken': 'valid-refresh-token'});
        return const _JsonReply({
          'accessToken': 'fresh-access-token',
          'refreshToken': 'fresh-refresh-token',
        });
      });
      final authState = _authState(storage: storage, adapter: adapter);

      await authState.checkAuthStatus();

      expect(authState.status, AuthStatus.authenticated);
      expect(storage.accessToken, 'fresh-access-token');
      expect(storage.refreshToken, 'fresh-refresh-token');
      expect(adapter.requests.where((path) => path.endsWith('/auth/refresh')),
          hasLength(1));
    });

    test('clears tokens and stays unauthenticated when startup refresh fails',
        () async {
      final storage = _MemoryTokenStorage(
        accessToken: 'expired-access-token',
        refreshToken: 'invalid-refresh-token',
      );
      final adapter = _DioAdapter((options) {
        expect(options.uri.path, endsWith('/auth/refresh'));
        return const _JsonReply(
          {
            'error': {'message': 'refresh token invalid'},
          },
          401,
        );
      });
      final authState = _authState(storage: storage, adapter: adapter);

      await authState.checkAuthStatus();

      expect(authState.status, AuthStatus.unauthenticated);
      expect(storage.accessToken, isNull);
      expect(storage.refreshToken, isNull);
    });

    test('does not call the API on a fresh install with no refresh token',
        () async {
      final storage = _MemoryTokenStorage();
      final adapter = _DioAdapter((options) {
        fail('fresh installs should not call ${options.uri}');
      });
      final authState = _authState(storage: storage, adapter: adapter);

      await authState.checkAuthStatus();

      expect(authState.status, AuthStatus.unauthenticated);
      expect(adapter.requests, isEmpty);
    });

    test('gates a restored session when biometric unlock is enabled', () async {
      final storage = _MemoryTokenStorage(
        accessToken: 'expired-access-token',
        refreshToken: 'valid-refresh-token',
        biometricUnlockEnabled: true,
      );
      final biometric = _FakeBiometricUnlockService(authenticates: true);
      final adapter = _DioAdapter((options) {
        return const _JsonReply({
          'accessToken': 'fresh-access-token',
          'refreshToken': 'fresh-refresh-token',
        });
      });
      final authState = _authState(
        storage: storage,
        adapter: adapter,
        biometricUnlockService: biometric,
      );

      await authState.checkAuthStatus();

      expect(authState.status, AuthStatus.biometricLocked);
      expect(authState.hasLocalSession, isTrue);

      final unlocked = await authState.unlockWithBiometrics();

      expect(unlocked, isTrue);
      expect(authState.status, AuthStatus.authenticated);
      expect(biometric.authenticateCalls, 1);
    });

    test('password fallback clears tokens and biometric enrollment', () async {
      final storage = _MemoryTokenStorage(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        biometricUnlockEnabled: true,
      );
      final authState = _authState(
        storage: storage,
        adapter: _DioAdapter((_) {
          fail('fallback should not call the API');
        }),
      );

      await authState.usePasswordLoginFallback();

      expect(authState.status, AuthStatus.unauthenticated);
      expect(storage.accessToken, isNull);
      expect(storage.refreshToken, isNull);
      expect(storage.biometricUnlockEnabled, isFalse);
    });
  });
}

AuthState _authState({
  required _MemoryTokenStorage storage,
  required HttpClientAdapter adapter,
  BiometricUnlockService? biometricUnlockService,
}) {
  final secureStorage = SecureStorage(tokenStorage: storage);
  final apiClient = ApiClient(
    storage: secureStorage,
    dio: Dio()..httpClientAdapter = adapter,
  );
  final authService = AuthService(
    api: apiClient,
    storage: secureStorage,
    biometricUnlockService:
        biometricUnlockService ?? _FakeBiometricUnlockService(),
  );
  return AuthState(authService: authService);
}

class _MemoryTokenStorage implements TokenStorageBackend {
  _MemoryTokenStorage({
    this.accessToken,
    this.refreshToken,
    this.biometricUnlockEnabled = false,
  });

  String? accessToken;
  String? refreshToken;
  bool biometricUnlockEnabled;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }

  @override
  Future<String?> getAccessToken() async => accessToken;

  @override
  Future<String?> getRefreshToken() async => refreshToken;

  @override
  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
    biometricUnlockEnabled = false;
  }

  @override
  Future<bool> hasTokens() async {
    return refreshToken != null && refreshToken!.isNotEmpty;
  }

  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {
    biometricUnlockEnabled = enabled;
  }

  @override
  Future<bool> isBiometricUnlockEnabled() async {
    return biometricUnlockEnabled;
  }
}

class _FakeBiometricUnlockService implements BiometricUnlockService {
  _FakeBiometricUnlockService({
    this.authenticates = true,
  });

  final bool authenticates;
  int authenticateCalls = 0;

  @override
  Future<bool> isDeviceUnlockAvailable() async => true;

  @override
  Future<bool> authenticate({required String reason}) async {
    authenticateCalls += 1;
    return authenticates;
  }
}

class _JsonReply {
  const _JsonReply(this.body, [this.statusCode = 200]);

  final Map<String, dynamic> body;
  final int statusCode;
}

class _DioAdapter implements HttpClientAdapter {
  _DioAdapter(this.responder);

  final _JsonReply Function(RequestOptions options) responder;
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.path);
    final reply = responder(options);
    return ResponseBody.fromString(
      jsonEncode(reply.body),
      reply.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
