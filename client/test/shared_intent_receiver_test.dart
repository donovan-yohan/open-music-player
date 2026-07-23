import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/share/shared_intent_receiver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('open_music_player/share_intents');
  const eventControlChannel = MethodChannel(
    'open_music_player/share_intents/events',
  );

  test(
    'initial shared text no-ops on an unsupported platform',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      var invocationCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        invocationCount++;
        return 'unexpected';
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, null),
      );
      final receiver = SharedIntentReceiver();

      await expectLater(receiver.initialSharedText(), completion(isNull));
      expect(invocationCount, isZero);
    },
  );

  test(
    'shared text stream closes cleanly on an unsupported platform',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      var invocationCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(eventControlChannel, (call) async {
        invocationCount++;
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(eventControlChannel, null),
      );
      final receiver = SharedIntentReceiver();

      await expectLater(receiver.sharedTextStream(), emitsDone);
      expect(invocationCount, isZero);
    },
  );

  test(
    'initial shared text uses the method channel on Android',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      var invocationCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        invocationCount++;
        expect(call.method, 'getInitialSharedText');
        return 'https://example.com/shared-track';
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, null),
      );
      final receiver = SharedIntentReceiver();

      await expectLater(
        receiver.initialSharedText(),
        completion('https://example.com/shared-track'),
      );
      expect(invocationCount, 1);
    },
  );
}
