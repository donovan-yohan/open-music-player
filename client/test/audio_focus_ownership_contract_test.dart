import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AudioFocusCoordinator is the sole interruption owner', () {
    final voiceSource = File('lib/core/engine/voice.dart').readAsStringSync();
    final coordinatorSource =
        File('lib/core/audio/audio_focus_coordinator.dart').readAsStringSync();

    expect(
      voiceSource,
      contains(
        RegExp(
          r'AudioPlayer\(\s*handleInterruptions:\s*false,',
          multiLine: true,
        ),
      ),
      reason: 'JustAudioVoice must not handle interruptions independently.',
    );
    expect(
      coordinatorSource,
      isNot(contains(RegExp(r'''import\s+['"][^'"]*engine[^'"]*['"]'''))),
      reason: 'AudioFocusCoordinator must use the canonical playback facade.',
    );
  });
}
