import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/database/database_helper.dart';
import 'core/services/connectivity_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize database
  await DatabaseHelper.database;

  // Initialize connectivity service
  final connectivityService = ConnectivityService();
  await connectivityService.initialize();

  runApp(
    ProviderScope(
      overrides: [
        // Pre-initialize connectivity service
      ],
      child: const OpenMusicPlayerApp(),
    ),
  );
}
