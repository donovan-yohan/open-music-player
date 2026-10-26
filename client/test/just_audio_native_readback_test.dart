import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default-off readback never activates a native platform', () async {
    final calls = <MethodCall>[];
    const session = MethodChannel('com.ryanheise.audio_session');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(session, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (call) async {
        calls.add(call);
        return <String, Object?>{};
      },
    );
    final player = AudioPlayer(
      handleAudioSessionActivation: false,
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
    );
    // Construction can ask the plugin to retire hot-restart players. The
    // diagnostic must not cause a native init, load or method dispatch.
    await Future<void>.delayed(Duration.zero);
    calls.clear();
    await expectLater(
      player.soundqNativeReadback(capability: 'a' * 64),
      throwsStateError,
    );
    expect(calls, isEmpty);
    await expectLater(
      player.soundqNativeReadback(capability: 'invalid'),
      throwsStateError,
    );
    expect(calls, isEmpty);
    await player.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(session, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      null,
    );
  });
}
