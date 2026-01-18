import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/auth/auth_service.dart';
import 'core/auth/auth_state.dart';
import 'core/storage/secure_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final storage = SecureStorage();
  final apiClient = ApiClient(storage: storage);
  final authService = AuthService(api: apiClient, storage: storage);
  final authState = AuthState(authService: authService);

  runApp(OpenMusicPlayerApp(authState: authState));
}
