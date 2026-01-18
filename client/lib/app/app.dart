import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/auth/auth_state.dart';
import 'router.dart';

class OpenMusicPlayerApp extends StatelessWidget {
  final AuthState authState;

  const OpenMusicPlayerApp({
    super.key,
    required this.authState,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: authState,
      child: MaterialApp.router(
        title: 'Open Music Player',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        routerConfig: appRouter,
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _handleLogout(BuildContext context) async {
    final authState = context.read<AuthState>();
    await authState.logout();
    if (context.mounted) {
      context.go('/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Open Music Player'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => _handleLogout(context),
          ),
        ],
      ),
      body: const Center(
        child: Text('Welcome to Open Music Player'),
      ),
    );
  }
}
