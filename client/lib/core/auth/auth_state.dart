import 'package:flutter/foundation.dart';
import 'auth_service.dart';

enum AuthStatus {
  initial,
  checking,
  authenticated,
  biometricLocked,
  unauthenticated,
}

class AuthState extends ChangeNotifier {
  final AuthService _authService;

  AuthStatus _status = AuthStatus.initial;
  String? _error;
  bool _isLoading = false;
  bool _biometricUnlockEnabled = false;
  bool _biometricUnlockAvailable = false;

  AuthState({required AuthService authService}) : _authService = authService;

  AuthStatus get status => _status;
  String? get error => _error;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  bool get isBiometricLocked => _status == AuthStatus.biometricLocked;
  bool get hasLocalSession => isAuthenticated || isBiometricLocked;
  bool get biometricUnlockEnabled => _biometricUnlockEnabled;
  bool get biometricUnlockAvailable => _biometricUnlockAvailable;

  Future<void> checkAuthStatus() async {
    _status = AuthStatus.checking;
    _error = null;
    notifyListeners();

    try {
      final isAuth = await _authService.isAuthenticated();
      if (isAuth) {
        await _refreshBiometricState();
        _status = _biometricUnlockEnabled
            ? AuthStatus.biometricLocked
            : AuthStatus.authenticated;
      } else {
        _status = AuthStatus.unauthenticated;
        _biometricUnlockEnabled = false;
      }
    } catch (_) {
      _status = AuthStatus.unauthenticated;
      _biometricUnlockEnabled = false;
    }
    notifyListeners();
  }

  Future<bool> login({required String email, required String password}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.login(email: email, password: password);

      if (result.success) {
        await _refreshBiometricState();
        _status = AuthStatus.authenticated;
        return true;
      } else {
        _error = result.error;
        return false;
      }
    } finally {
      _isLoading = false;
      notifyListeners();
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

    try {
      final result = await _authService.register(
        email: email,
        password: password,
        username: username,
      );

      if (result.success) {
        await _refreshBiometricState();
        _status = AuthStatus.authenticated;
        return true;
      } else {
        _error = result.error;
        return false;
      }
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _authService.logout();
      _status = AuthStatus.unauthenticated;
      _biometricUnlockEnabled = false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> setBiometricUnlockEnabled(bool enabled) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.setBiometricUnlockEnabled(enabled);
      if (result.success) {
        await _refreshBiometricState();
        _biometricUnlockEnabled = enabled;
        return true;
      }

      _error = result.error;
      await _refreshBiometricState();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> unlockWithBiometrics() async {
    if (!_biometricUnlockEnabled) {
      _status = AuthStatus.authenticated;
      notifyListeners();
      return true;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final unlocked = await _authService.unlockWithBiometrics();
      if (unlocked) {
        _status = AuthStatus.authenticated;
        return true;
      }

      _error = 'Unlock canceled. Sign in with your password to continue.';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> usePasswordLoginFallback() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _authService.clearLocalSession();
      _status = AuthStatus.unauthenticated;
      _biometricUnlockEnabled = false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void lockIfBiometricRequired() {
    if (_status == AuthStatus.authenticated && _biometricUnlockEnabled) {
      _status = AuthStatus.biometricLocked;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<void> _refreshBiometricState() async {
    final available = await _authService.isBiometricUnlockAvailable();
    final enabled = await _authService.isBiometricUnlockEnabled();
    _biometricUnlockAvailable = available;
    _biometricUnlockEnabled = enabled;
  }
}
