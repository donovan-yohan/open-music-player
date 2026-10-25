import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/features/playlists/mix/mix_exchange_actions.dart';
import 'package:open_music_player/core/services/mix_exchange_service.dart';

import 'mix_exchange_service_test.dart' show portableMix;
import 'desktop_mix_editor_draft_test.dart' show planJson;
import 'support/mock_dio_client.dart';

void main() {
  testWidgets('export copies saved portable metadata, not a listening URL',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final api = mockQueueApiClient((request) async {
      expect(request.url.path, '/api/v1/mix-plans/plan-1/export');
      return http.Response(jsonEncode(portableMix()), 200);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MixExchangeMenu(
                service: MixExchangeService(api),
                planId: 'plan-1',
                onImported: (_) {}))));
    await tester.tap(find.byTooltip('Mix import and export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export mix'));
    await tester.pumpAndSettle();
    expect(find.text('Export mix'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(jsonDecode(copied!), portableMix());
  });

  testWidgets('import dialog sends metadata and opens only verified readback',
      (tester) async {
    String? imported;
    final api = mockQueueApiClient((request) async => http.Response(
        jsonEncode(planJson()), request.method == 'POST' ? 201 : 200));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MixExchangeMenu(
                service: MixExchangeService(api),
                onImported: (plan) => imported = plan.id))));
    await tester.tap(find.byTooltip('Mix import and export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import mix'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('mix-import-json')),
        jsonEncode(portableMix()));
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(imported, 'plan-1');
    expect(find.byKey(const ValueKey('mix-import-json')), findsNothing);
  });

  testWidgets('missing audio keeps the import text and never opens a mix',
      (tester) async {
    var imported = false;
    var requests = 0;
    final api = mockQueueApiClient((_) async {
      requests++;
      return http.Response(
          '{"code":"MISSING_SOURCES","message":"Missing source."}', 422);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MixExchangeMenu(
                service: MixExchangeService(api),
                onImported: (_) => imported = true))));
    await tester.tap(find.byTooltip('Mix import and export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import mix'));
    await tester.pumpAndSettle();
    final text = jsonEncode(portableMix());
    await tester.enterText(find.byKey(const ValueKey('mix-import-json')), text);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(imported, isFalse);
    expect(
        find.text('Add the matching audio to your library before importing.'),
        findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mix-import-json')))
            .controller!
            .text,
        text);
  });
}
