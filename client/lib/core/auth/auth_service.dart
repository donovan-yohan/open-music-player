import 'package:dio/dio.dart';
import '../api/api_client.dart';
import '../storage/secure_storage.dart';

class AuthResult {
  final bool success;
  final String? error;

  const AuthResult.success() : success = true, error = null;
  const AuthResult.failure(this.error) : success = false;
}

class AuthService {
  final ApiClient _api;
  final SecureStorage _storage;

  AuthService({
    required ApiClient api,
    required SecureStorage storage,
  })  : _api = api,
        _storage = storage;

  Future<AuthResult> register({
    required String email,
    required String password,
    required String username,
  }) async {
    try {
      final response = await _api.post(
        '/auth/register',
        data: {
          'email': email,
          'password': password,
          'username': username,
        },
      );

      if (response.statusCode == 201) {
        final data = response.data;
        await _storage.saveTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
        );
        return const AuthResult.success();
      }
      return const AuthResult.failure('Registration failed');
    } on DioException catch (e) {
      return AuthResult.failure(_extractErrorMessage(e));
    } catch (e) {
      return AuthResult.failure('An unexpected error occurred');
    }
  }

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _api.post(
        '/auth/login',
        data: {
          'email': email,
          'password': password,
        },
      );

      if (response.statusCode == 200) {
        final data = response.data;
        await _storage.saveTokens(
          accessToken: data['access_token'],
          refreshToken: data['refresh_token'],
        );
        return const AuthResult.success();
      }
      return const AuthResult.failure('Login failed');
    } on DioException catch (e) {
      return AuthResult.failure(_extractErrorMessage(e));
    } catch (e) {
      return AuthResult.failure('An unexpected error occurred');
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
    return _storage.hasTokens();
  }

  String _extractErrorMessage(DioException e) {
    if (e.response?.data is Map) {
      final data = e.response!.data as Map;
      if (data.containsKey('message')) {
        return data['message'] as String;
      }
      if (data.containsKey('error')) {
        return data['error'] as String;
      }
    }

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
}
