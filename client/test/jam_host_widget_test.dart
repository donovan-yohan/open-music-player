import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:open_music_player/features/jam/jam_host_screen.dart';
import 'jam_host_controller_test.dart' show Harness;
import 'device_presence_service_test.dart' show flush;

void main() {
  testWidgets(
      'selects owned library explicitly, local QR and pending approval actions',
      (tester) async {
    final h = Harness();
    h.presence.attach(h.source, h.api.captureAuthSession());
    await flush(tester);
    h.controller.setGuestOrigin('https://guests.example');
    await tester
        .pumpWidget(MaterialApp(home: JamHostScreen(controller: h.controller)));
    await flush(tester);
    expect(find.text('Choose tracks'), findsOneWidget);
    await tester.tap(find.text('Choose tracks'));
    await flush(tester, const Duration(milliseconds: 300));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    expect(find.text('Song'), findsOneWidget,
        reason:
            '${h.methods} ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Use 1 track'));
    await flush(tester);
    await tester.tap(find.text('Start Jam'));
    await flush(tester);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(find.text('Local song'), findsOneWidget);
    await tester.tap(find.text('Create invitation'));
    await flush(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is QrPainter),
        findsOneWidget);
    expect(find.bySemanticsLabel('Jam invitation QR code'), findsOneWidget);
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('jam-invitation-qr')));
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final dir = Directory.systemTemp.path;
      await File('$dir/soundq-jam-host-qr.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      await File('$dir/soundq-jam-host-qr-expected.txt')
          .writeAsString(h.controller.invitationLink.toString());
      image.dispose();
    });
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await flush(tester, const Duration(seconds: 5));
    expect(h.controller.isHosting, isTrue);
    expect(h.hostBeats, greaterThan(1));
    await h.dispose(tester);
  });
  testWidgets('library picker enforces explicit twenty-track ceiling',
      (tester) async {
    final h = Harness()..libraryCount = 21;
    h.presence.attach(h.source, h.api.captureAuthSession());
    await flush(tester);
    await tester
        .pumpWidget(MaterialApp(home: JamHostScreen(controller: h.controller)));
    await tester.tap(find.text('Choose tracks'));
    await flush(tester, const Duration(milliseconds: 300));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    final list = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(ListView));
    for (var i = 0; i < 20; i++) {
      final title = i == 0 ? 'Song' : 'Song $i';
      await tester.scrollUntilVisible(find.text(title), 90,
          scrollable:
              find.descendant(of: list, matching: find.byType(Scrollable)));
      await tester.tap(find.text(title));
      await tester.pump();
    }
    await tester.scrollUntilVisible(find.text('Song 20'), 90,
        scrollable:
            find.descendant(of: list, matching: find.byType(Scrollable)));
    final row = tester.widget<CheckboxListTile>(find.ancestor(
        of: find.text('Song 20'), matching: find.byType(CheckboxListTile)));
    expect(row.onChanged, isNull);
    expect(find.text('Use 20 tracks'), findsOneWidget);
    await tester.tap(find.text('Use 20 tracks'));
    await flush(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await h.dispose(tester);
  });
  testWidgets('auth change clears old selection', (tester) async {
    final h = Harness();
    h.presence.attach(h.source, h.api.captureAuthSession());
    await flush(tester);
    await tester
        .pumpWidget(MaterialApp(home: JamHostScreen(controller: h.controller)));
    await flush(tester);
    await tester.tap(find.text('Choose tracks'));
    await flush(tester, const Duration(milliseconds: 300));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await flush(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Use 1 track'));
    await flush(tester);
    h.storage.beginAuthIntent();
    await tester.pump();
    expect(find.text('1 track selected'), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await h.dispose(tester);
  });
}
