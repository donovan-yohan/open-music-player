import 'package:flutter/material.dart';
import '../../../core/audio/playback_state.dart';

/// Uses the existing pause intent fence, including its synchronous cancellation.
Future<void> cancelRadio(BuildContext context, PlaybackState playback) async {
  try {
    await playback.pause();
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Could not pause playback. Please try again.'),
    ));
  }
}

class RadioWaiting extends StatelessWidget {
  const RadioWaiting({super.key, required this.playback});
  final PlaybackState playback;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ExcludeSemantics(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Semantics(liveRegion: true, child: const Text('Finding more music…')),
          const SizedBox(height: 16),
          TextButton(
              onPressed: () => cancelRadio(context, playback),
              child: const Text('Cancel')),
        ]),
      );
}
