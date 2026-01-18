import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_provider.dart';

/// User model for authenticated user
class User {
  final String id;
  final String email;

  const User({required this.id, required this.email});
}

/// Authentication state
class AuthState {
  final User? user;
  final bool isLoading;

  const AuthState({this.user, this.isLoading = false});

  bool get isAuthenticated => user != null;

  AuthState copyWith({User? user, bool? isLoading, bool clearUser = false}) {
    return AuthState(
      user: clearUser ? null : (user ?? this.user),
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// Auth notifier for managing authentication state
class AuthNotifier extends StateNotifier<AuthState> {
  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;

  static const _tokenKey = 'auth_token';
  static const _userEmailKey = 'user_email';
  static const _userIdKey = 'user_id';

  AuthNotifier(this._prefs, this._secureStorage) : super(const AuthState()) {
    _loadUser();
  }

  Future<void> _loadUser() async {
    state = state.copyWith(isLoading: true);

    final token = await _secureStorage.read(key: _tokenKey);
    if (token != null) {
      final email = _prefs.getString(_userEmailKey);
      final userId = _prefs.getString(_userIdKey);
      if (email != null && userId != null) {
        state = AuthState(user: User(id: userId, email: email));
      } else {
        state = const AuthState();
      }
    } else {
      state = const AuthState();
    }
  }

  Future<void> logout({bool clearCache = false}) async {
    state = state.copyWith(isLoading: true);

    // Clear tokens
    await _secureStorage.delete(key: _tokenKey);

    // Clear user info
    await _prefs.remove(_userEmailKey);
    await _prefs.remove(_userIdKey);

    if (clearCache) {
      // Clear all cached data
      final keys = _prefs.getKeys();
      for (final key in keys) {
        if (key != 'app_settings') {
          await _prefs.remove(key);
        }
      }
    }

    state = const AuthState(user: null);
  }

  // Mock method for demo - in real app this would verify with backend
  Future<void> setMockUser(String email) async {
    await _secureStorage.write(key: _tokenKey, value: 'mock_token');
    await _prefs.setString(_userEmailKey, email);
    await _prefs.setString(_userIdKey, 'mock_user_id');
    state = AuthState(user: User(id: 'mock_user_id', email: email));
  }
}

/// Secure storage provider
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
});

/// Provider for authentication state
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final secureStorage = ref.watch(secureStorageProvider);
  return AuthNotifier(prefs, secureStorage);
});
