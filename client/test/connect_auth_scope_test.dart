import 'dart:async';
import 'dart:convert';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:flutter/services.dart';
import 'package:open_music_player/core/platform/desktop_initialization.dart';
import 'package:open_music_player/core/auth/biometric_unlock_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/token_storage_backend.dart';

class NoBiometrics implements BiometricUnlockService {
  @override
  Future<bool> isDeviceUnlockAvailable() async => false;
  @override
  Future<bool> authenticate({required String reason}) async => false;
}

class MemoryTokens implements TokenStorageBackend {
  String? access = 'old';
  String? refresh = 'old-refresh';
  Completer<void>? readGate;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  @override
  Future<String?> getAccessToken() async {
    await readGate?.future;
    return access;
  }

  @override
  Future<String?> getRefreshToken() async => refresh;
  @override
  Future<void> saveTokens(
      {required String accessToken, required String refreshToken}) async {
    writeStarted?.complete();
    await writeGate?.future;
    access = accessToken;
    refresh = refreshToken;
  }

  @override
  Future<void> clearTokens() async {
    access = null;
    refresh = null;
  }

  @override
  Future<bool> hasTokens() async => refresh != null;
  @override
  Future<bool> isBiometricUnlockEnabled() async => false;
  @override
  Future<void> setBiometricUnlockEnabled(bool enabled) async {}
}

class Wire implements HttpClientAdapter {
  Wire(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    requests.add(o);
    return respond(o);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody reply(Object data, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(data), status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType]
    });
ApiClient client(SecureStorage storage, Wire wire) =>
    ApiClient(storage: storage, dio: Dio()..httpClientAdapter = wire);
Future<void> turn() => Future<void>.delayed(Duration.zero);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('login intent revokes scopes before notifying auth listeners', () async {
    final storage = SecureStorage(tokenStorage: MemoryTokens());
    final gate = Completer<void>();
    final api = client(storage, Wire((_) async {
      await gate.future;
      return reply({}, 401);
    }));
    final state =
        AuthState(authService: AuthService(api: api, storage: storage));
    final scope = api.captureAuthSession();
    state.addListener(() => expect(scope.isCurrent, isFalse));
    final login = state.login(email: 'test', password: 'test');
    expect(scope.isCurrent, isFalse);
    gate.complete();
    await login;
    state.dispose();
  });
  test('default native API storage uses application keychain policy', () async {
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final wire = Wire((_) => reply({}));
    await ApiClient(dio: Dio()..httpClientAdapter = wire).get('/library');
    expect(
        calls.single.arguments['options']['useDataProtectionKeyChain'],
        applicationSecureStorage()
            .mOptions
            .toMap()['useDataProtectionKeyChain']);
  });
  test('captured account payload cannot send after auth intent', () async {
    final backend = MemoryTokens();
    final storage = SecureStorage(tokenStorage: backend);
    final wire = Wire((_) => reply({}));
    final api = client(storage, wire);
    final scope = api.captureAuthSession();
    storage.beginAuthIntent();
    await expectLater(
        api.sessionRequest(scope, '/me/devices',
            method: 'POST', data: {'old': true}),
        throwsA(isA<DioException>()));
    expect(wire.requests, isEmpty);
  });
  test('account switch while reading token cannot dispatch old payload',
      () async {
    final backend = MemoryTokens()..readGate = Completer<void>();
    final storage = SecureStorage(tokenStorage: backend);
    final wire = Wire((_) => reply({}));
    final api = client(storage, wire);
    final request = api.get('/library');
    final checked = expectLater(request, throwsA(isA<DioException>()));
    await turn();
    final saved =
        storage.saveTokens(accessToken: 'new', refreshToken: 'new-refresh');
    backend.readGate!.complete();
    await saved;
    await checked;
    expect(wire.requests, isEmpty);
  });
  test('old 401 cannot retry with newly signed in bearer', () async {
    final storage = SecureStorage(tokenStorage: MemoryTokens());
    final arrived = Completer<void>(), release = Completer<void>();
    final wire = Wire((o) async {
      arrived.complete();
      await release.future;
      return reply({}, 401);
    });
    final api = client(storage, wire);
    final checked =
        expectLater(api.get('/library'), throwsA(isA<DioException>()));
    await arrived.future;
    await storage.saveTokens(accessToken: 'new', refreshToken: 'new-refresh');
    release.complete();
    await checked;
    expect(wire.requests, hasLength(1));
  });
  test('revocation between interceptor and adapter prevents network exchange',
      () async {
    final storage = SecureStorage(tokenStorage: MemoryTokens());
    final wire = Wire((_) => reply({}));
    final dio = Dio()..httpClientAdapter = wire;
    final api = ApiClient(storage: storage, dio: dio);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      storage.beginAuthIntent();
      h.next(o);
    }));
    await expectLater(api.get('/library'), throwsA(isA<DioException>()));
    expect(wire.requests, isEmpty);
  });
  test('logout completion cannot overwrite a newer login status or credentials',
      () async {
    final storage = SecureStorage(tokenStorage: MemoryTokens());
    final arrived = Completer<void>(), release = Completer<void>();
    final api = client(storage, Wire((o) async {
      if (o.path == '/auth/logout') {
        arrived.complete();
        await release.future;
        return reply({});
      }
      return reply({'accessToken': 'new', 'refreshToken': 'new-refresh'});
    }));
    final state = AuthState(
        authService: AuthService(
            api: api,
            storage: storage,
            biometricUnlockService: NoBiometrics()));
    final logout = state.logout();
    await arrived.future;
    expect(await state.login(email: 'new', password: 'password'), isTrue);
    release.complete();
    await logout;
    expect(state.isAuthenticated, isTrue);
    expect(await storage.getAccessToken(), 'new');
    state.dispose();
  });
  test(
      'refresh write interrupted by auth intent cannot persist retired credentials',
      () async {
    final backend = MemoryTokens()
      ..writeGate = Completer<void>()
      ..writeStarted = Completer<void>();
    final storage = SecureStorage(tokenStorage: backend);
    final api = client(
        storage,
        Wire((_) => reply(
            {'accessToken': 'retired', 'refreshToken': 'retired-refresh'})));
    final refreshing = api.refreshSession();
    await backend.writeStarted!.future;
    storage.beginAuthIntent();
    backend.writeGate!.complete();
    expect(await refreshing, isFalse);
    expect(await storage.getAccessToken(), isNull);
  });
  test(
      'ordinary authoring mutation captures account before interceptor scheduling',
      () async {
    final storage = SecureStorage(tokenStorage: MemoryTokens());
    final wire = Wire((_) => reply({}));
    final api = client(storage, wire);
    final saving = api.clearQueue();
    final checked = expectLater(saving, throwsA(isA<Object>()));
    await storage.saveTokens(accessToken: 'new', refreshToken: 'new-refresh');
    await checked;
    expect(wire.requests, isEmpty);
  });
  test('multi-item queue request cannot continue under next account', () async {
    final storage = SecureStorage(tokenStorage: MemoryTokens());
    final wire = Wire((_) async {
      await storage.saveTokens(accessToken: 'new', refreshToken: 'new-refresh');
      return reply({'items': []});
    });
    final api = client(storage, wire);
    await expectLater(
        api.addToQueue(trackIds: ['1', '2']), throwsA(isA<Object>()));
    expect(wire.requests, hasLength(1));
  });
  test('late successful refresh cannot replace newer account credentials',
      () async {
    final backend = MemoryTokens();
    final storage = SecureStorage(tokenStorage: backend);
    final arrived = Completer<void>(), release = Completer<void>();
    final api = client(storage, Wire((o) async {
      arrived.complete();
      await release.future;
      return reply(
          {'accessToken': 'obsolete', 'refreshToken': 'obsolete-refresh'});
    }));
    final refreshing = api.refreshSession();
    await arrived.future;
    await storage.saveTokens(
        accessToken: 'new-account', refreshToken: 'new-refresh');
    release.complete();
    expect(await refreshing, isFalse);
    expect(await storage.getAccessToken(), 'new-account');
  });
  test('clients sharing storage coalesce refresh rotation', () async {
    final backend = MemoryTokens();
    final storage = SecureStorage(tokenStorage: backend);
    final arrived = Completer<void>(), release = Completer<void>();
    var count = 0;
    final wire = Wire((o) async {
      count++;
      if (!arrived.isCompleted) arrived.complete();
      await release.future;
      return reply({'accessToken': 'fresh', 'refreshToken': 'fresh-refresh'});
    });
    final a = client(storage, wire).refreshSession();
    await arrived.future;
    final b = client(storage, wire).refreshSession();
    await turn();
    release.complete();
    expect(await Future.wait([a, b]), [true, true]);
    expect(count, 1);
  });
}
