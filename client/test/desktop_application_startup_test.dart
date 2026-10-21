import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/platform/application_startup.dart';

void main() {
  testWidgets(
      'startup plugin failure is reported and visible instead of a blank window',
      (tester) async {
    final reported = <FlutterErrorDetails>[];
    final oldHandler = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = oldHandler);
    await runApplicationStartup(() async {
      throw MissingPluginException('sqflite macOS registration missing');
    });
    await tester.pumpAndSettle();
    expect(find.text('SoundQ could not start'), findsOneWidget);
    expect(find.textContaining('sqflite macOS registration missing'),
        findsOneWidget);
    expect(reported.single.exception, isA<MissingPluginException>());
  });
}
