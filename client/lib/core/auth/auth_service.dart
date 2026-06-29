import 'package:dio/dio.dart';
import '../api/api_client.dart';
import '../storage/secure_storage.dart';
import 'auth_tokens.dart';

class AuthResult {
  final bool success;
  final String? error;

  const AuthResult.success()
      : success = true,
        error = null;
  const AuthResult.failure(this.error) : success = false;
}

class AuthService {
  final ApiClient _api;
  final SecureStorage _storage;

  AuthService({required ApiClient api, required SecureStorage storage})
      : _api = api,
        _storage = storage;

  Future<AuthResult> register({
    required String email,
    required String password,
    required String username,
  }) async {
    try {
      final response = await _api.post(
        '/auth/register',
        data: {'email': email, 'password': password, 'username': username},
      );

      if (response.statusCode == 201) {
        final tokens = parseAuthTokens(response.data);
        await _storage.saveTokens(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        return const AuthResult.success();
      }
      return const AuthResult.failure('Registration failed');
    } on DioException catch (e) {
      return AuthResult.failure(_extractErrorMessage(e));
    } catch (e) {
      return const AuthResult.failure('An unexpected error occurred');
    }
  }

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _api.post(
        '/auth/login',
        data: {'email': email, 'password': password},
      );

      if (response.statusCode == 200) {
        final tokens = parseAuthTokens(response.data);
        await _storage.saveTokens(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        return const AuthResult.success();
      }
      return const AuthResult.failure('Login failed');
    } on DioException catch (e) {
      return AuthResult.failure(_extractErrorMessage(e));
    } catch (e) {
      return const AuthResult.failure('An unexpected error occurred');
    }
  }

  Future<void> logout() async {
    try {
      await _api.post('/auth/logout');
    } catch (_) {
      // Logout even if the API call fails
    } finally {
      await _storage.clearTokens();
    }
  }

  Future<bool> isAuthenticated() async {
    return _api.refreshSession();
  }

  String _extractErrorMessage(DioException e) {
    final responseMessage = _messageFromPayload(e.response?.data);
    if (responseMessage != null) return responseMessage;

    switch (e.response?.statusCode) {
      case 400:
        return 'Invalid request. Please check your input.';
      case 401:
        return 'Invalid email or password.';
      case 409:
        return 'An account with this email already exists.';
      case 422:
        return 'Please check your input and try again.';
      case 500:
        return 'Server error. Please try again later.';
      default:
        if (e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout) {
          return 'Connection timed out. Please check your internet.';
        }
        if (e.type == DioExceptionType.connectionError) {
          return 'Unable to connect to server.';
        }
        return 'An error occurred. Please try again.';
    }
  }

  String? _messageFromPayload(dynamic payload) {
    if (payload is! Map) return null;

    final message = payload['message'];
    if (message is String && message.isNotEmpty) return message;

    final error = payload['error'];
    if (error is String && error.isNotEmpty) return error;
    if (error is Map) {
      final nestedMessage = error['message'];
      if (nestedMessage is String && nestedMessage.isNotEmpty) {
        return nestedMessage;
      }
    }

    return null;
  }
}
