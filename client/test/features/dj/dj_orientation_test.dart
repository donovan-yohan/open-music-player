import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411 defers `DjScreen.dispose` restoring `DeviceOrientation.values`
/// wholesale rather than the caller's prior preference. This test pins the
/// behaviour that exists so the deferral stays deliberate: the rotate prompt of
/// D3 is a fallback for frames the request cannot cover, not a replacement for
/// the request itself.
void main() {
  final deck = useEmptyDjSession();
  final orientationCalls = <List<String>>[];

  setUp(() {
    orientationCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientationCalls.add(
          (call.arguments as List).map((e) => e.toString()).toList(),
        );
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('the deck requests landscape on enter and restores on exit',
      (tester) async {
    await pumpDjScreen(
      tester,
      session: deck.session,
      viewport: landscapeReference,
    );

    expect(orientationCalls, hasLength(1));
    expect(orientationCalls.single, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));

    expect(orientationCalls, hasLength(2));
    expect(
      orientationCalls.last,
      DeviceOrientation.values.map((e) => e.toString()).toList(),
    );
  });
}
