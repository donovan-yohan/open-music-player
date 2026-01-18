import 'package:flutter/foundation.dart';
import 'auth_service.dart';

enum AuthStatus {
  initial,
  checking,
  authenticated,
  unauthenticated,
}

class AuthState extends ChangeNotifier {
  final AuthService _authService;

  AuthStatus _status = AuthStatus.initial;
  String? _error;
  bool _isLoading = false;

  AuthState({required AuthService authService}) : _authService = authService;

  AuthStatus get status => _status;
  String? get error => _error;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  Future<void> checkAuthStatus() async {
    _status = AuthStatus.checking;
    notifyListeners();

    final isAuth = await _authService.isAuthenticated();
    _status = isAuth ? AuthStatus.authenticated : AuthStatus.unauthenticated;
    notifyListeners();
  }

  Future<bool> login({
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    final result = await _authService.login(
      email: email,
      password: password,
    );

    _isLoading = false;
    if (result.success) {
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } else {
      _error = result.error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register({
    required String email,
    required String password,
    required String username,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    final result = await _authService.register(
      email: email,
      password: password,
      username: username,
    );

    _isLoading = false;
    if (result.success) {
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    } else {
      _error = result.error;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    await _authService.logout();

    _isLoading = false;
    _status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
