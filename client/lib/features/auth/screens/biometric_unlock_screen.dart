import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_state.dart';

class BiometricUnlockScreen extends StatefulWidget {
  const BiometricUnlockScreen({super.key});

  @override
  State<BiometricUnlockScreen> createState() => _BiometricUnlockScreenState();
}

class _BiometricUnlockScreenState extends State<BiometricUnlockScreen> {
  bool _autoPrompted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_autoPrompted) return;
    _autoPrompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _unlock();
    });
  }

  Future<void> _unlock() async {
    final authState = context.read<AuthState>();
    final next = _safeNext;
    final unlocked = await authState.unlockWithBiometrics();
    if (!mounted) return;

    if (unlocked) {
      context.go(next);
    } else if (authState.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authState.error!),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _usePasswordInstead() async {
    await context.read<AuthState>().usePasswordLoginFallback();
    if (!mounted) return;
    context.go('/login');
  }

  String get _safeNext {
    final next = GoRouterState.of(context).uri.queryParameters['next'];
    return _safeUnlockRedirectNext(next) ?? '/home';
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<AuthState>();
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.fingerprint,
                    size: 88,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Unlock Open Music Player',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Biometric/PIN unlock protects the session stored on this installed app only. It does not survive reinstall or app data removal.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: authState.isLoading ? null : _unlock,
                    icon: authState.isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_open_outlined),
                    label: const Text('Unlock with device credential'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: authState.isLoading ? null : _usePasswordInstead,
                    child: const Text('Use email and password instead'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _safeUnlockRedirectNext(String? next) {
  if (next == null || next.isEmpty) return null;
  if (!next.startsWith('/') || next.startsWith('//')) return null;
  final uri = Uri.tryParse(next);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  if (uri.path == '/unlock' ||
      uri.path == '/login' ||
      uri.path == '/register') {
    return null;
  }
  return next;
}
