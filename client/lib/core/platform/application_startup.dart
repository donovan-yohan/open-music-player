import 'package:flutter/material.dart';

/// Do not silently skip a missing plugin and leave an apparently healthy app.
/// Keep the original exception in Flutter's error sink and in a selectable
/// startup diagnostic. No transport or alternate playback owner is created.
Future<void> runApplicationStartup(Future<void> Function() initialize) async {
  try {
    await initialize();
  } catch (error, stack) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'SoundQ startup',
      context: ErrorDescription('while initializing application services'),
    ));
    runApp(MaterialApp(
      title: 'SoundQ',
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('SoundQ could not start',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  const Text(
                      'A required application service failed. Restart the app after resolving this error.'),
                  const SizedBox(height: 16),
                  SelectableText(error.toString()),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }
}
