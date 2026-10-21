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

  int _sessionRevision = 0;

  /// Changes synchronously at account intent, before any storage/network await.
  int get sessionRevision => _sessionRevision;

  AuthStatus get status => _status;
  String? get error => _error;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  bool get isBiometricLocked => _status == AuthStatus.biometricLocked;
  bool get hasLocalSession => isAuthenticated || isBiometricLocked;
  bool get biometricUnlockEnabled => _biometricUnlockEnabled;
  bool get biometricUnlockAvailable => _biometricUnlockAvailable;

  Future<void> checkAuthStatus() async {
    final revision = ++_sessionRevision;
    _status = AuthStatus.checking;
    _error = null;
    notifyListeners();

    try {
      final isAuth = await _authService.isAuthenticated();
      if (revision != _sessionRevision) return;
      if (isAuth) {
        await _refreshBiometricState(revision);
        if (revision != _sessionRevision) return;
        _status = _biometricUnlockEnabled
            ? AuthStatus.biometricLocked
            : AuthStatus.authenticated;
      } else {
        _status = AuthStatus.unauthenticated;
        _biometricUnlockEnabled = false;
      }
    } catch (_) {
      if (revision != _sessionRevision) return;
      _status = AuthStatus.unauthenticated;
      _biometricUnlockEnabled = false;
    }
    notifyListeners();
  }

  Future<bool> login({required String email, required String password}) async {
    final revision = ++_sessionRevision;
    _authService.beginAuthIntent();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.login(email: email, password: password);
      if (revision != _sessionRevision) return false;

      if (result.success) {
        await _refreshBiometricState(revision);
        if (revision != _sessionRevision) return false;
        _status = AuthStatus.authenticated;
        return true;
      } else {
        _error = result.error;
        return false;
      }
    } finally {
      if (revision == _sessionRevision) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> register({
    required String email,
    required String password,
    required String username,
  }) async {
    final revision = ++_sessionRevision;
    _authService.beginAuthIntent();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.register(
        email: email,
        password: password,
        username: username,
      );
      if (revision != _sessionRevision) return false;

      if (result.success) {
        await _refreshBiometricState(revision);
        if (revision != _sessionRevision) return false;
        _status = AuthStatus.authenticated;
        return true;
      } else {
        _error = result.error;
        return false;
      }
    } finally {
      if (revision == _sessionRevision) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> logout() async {
    final revision = ++_sessionRevision;
    _authService.beginAuthIntent();
    _isLoading = true;
    notifyListeners();

    try {
      await _authService.logout();
      if (revision != _sessionRevision) return;
      _status = AuthStatus.unauthenticated;
      _biometricUnlockEnabled = false;
    } finally {
      if (revision == _sessionRevision) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> setBiometricUnlockEnabled(bool enabled) async {
    final revision = _sessionRevision;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await _authService.setBiometricUnlockEnabled(enabled);
      if (revision != _sessionRevision) return false;
      if (result.success) {
        await _refreshBiometricState(revision);
        _biometricUnlockEnabled = enabled;
        return true;
      }

      _error = result.error;
      await _refreshBiometricState(revision);
      return false;
    } finally {
      if (revision == _sessionRevision) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> unlockWithBiometrics() async {
    final revision = _sessionRevision;
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
      if (revision != _sessionRevision) return false;
      if (unlocked) {
        _status = AuthStatus.authenticated;
        return true;
      }

      _error = 'Unlock canceled. Sign in with your password to continue.';
      return false;
    } finally {
      if (revision == _sessionRevision) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> usePasswordLoginFallback() async {
    final revision = ++_sessionRevision;
    _authService.beginAuthIntent();
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _authService.clearLocalSession();
      if (revision != _sessionRevision) return;
      _status = AuthStatus.unauthenticated;
      _biometricUnlockEnabled = false;
    } finally {
      if (revision == _sessionRevision) {
        _isLoading = false;
        notifyListeners();
      }
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

  Future<void> _refreshBiometricState(int revision) async {
    final available = await _authService.isBiometricUnlockAvailable();
    final enabled = await _authService.isBiometricUnlockEnabled();
    if (revision != _sessionRevision) return;
    _biometricUnlockAvailable = available;
    _biometricUnlockEnabled = enabled;
  }
}
