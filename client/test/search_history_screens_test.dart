import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/network/connectivity_service.dart';
import 'package:open_music_player/core/storage/offline_database.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const accountId = 'screen-history-user';
  final token = _jwt(accountId);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'access_token': token});
  });

  testWidgets(
      'SearchScreen submits history, shows chips, promotes, clears, and remounts',
      (tester) async {
    final adapter = await _pumpSearch(tester);
    final field = find.byType(TextField);
    final prefs = await SharedPreferences.getInstance();

    await tester.tap(field);
    await tester.enterText(field, 'draft');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(adapter.queries, ['draft']);
    expect(prefs.getStringList('search_history.discover.$accountId'), isNull);
    await tester.enterText(field, 'ambient set');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ambient set'), findsOneWidget);
    expect(find.text('Recent searches'), findsOneWidget);

    await tester.enterText(field, 'second search');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.widgetWithText(ActionChip, 'ambient set'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<TextField>(field).controller!.text, 'ambient set');
    expect(adapter.queries,
        ['draft', 'ambient set', 'second search', 'ambient set']);
    expect(prefs.getStringList('search_history.discover.$accountId'),
        ['ambient set', 'second search']);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpSearch(tester);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ambient set'), findsOneWidget);
    expect(find.text('second search'), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Clear history'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(prefs.getStringList('search_history.discover.$accountId'), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpSearch(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('ambient set'), findsNothing);
  });

  testWidgets('horizontal recent-chip drag keeps SearchScreen focused',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'search_history.discover.$accountId',
      List<String>.generate(8, (index) => 'discover query $index'),
    );
    await _pumpSearch(tester);

    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 100));
    final recent = find.byKey(const ValueKey('recent_searches_discover'));
    expect(recent, findsOneWidget);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: recent, matching: find.byType(Scrollable)),
    );
    final before = scrollable.position.pixels;

    await tester.drag(recent, const Offset(-240, 0));
    await tester.pump();

    expect(scrollable.position.pixels, greaterThan(before));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(find.text('Recent searches'), findsOneWidget);
    expect(find.text('discover query 0'), findsOneWidget);
  });

  testWidgets('LibraryScreen uses its scoped history on the real screen',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs
        .setStringList('search_history.library.$accountId', ['library q']);
    await prefs
        .setStringList('search_history.discover.$accountId', ['discover q']);
    await _pumpLibrary(tester);

    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('library q'), findsOneWidget);
    expect(find.text('Recent searches'), findsOneWidget);
    expect(find.text('discover q'), findsNothing);

    await tester.enterText(field, 'draft');
    await tester.pump(const Duration(milliseconds: 400));
    expect(prefs.getStringList('search_history.library.$accountId'),
        ['library q']);
    expect(find.byTooltip('Clear search'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.byTooltip('Clear search'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'library q'), findsOneWidget);
    expect(prefs.getStringList('search_history.library.$accountId'),
        ['library q']);
    await tester.enterText(field, 'submitted q');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 50));
    expect(prefs.getStringList('search_history.library.$accountId'),
        ['submitted q', 'library q']);
    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.widgetWithText(ActionChip, 'library q'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<TextField>(field).controller!.text, 'library q');
    expect(prefs.getStringList('search_history.library.$accountId'),
        ['library q', 'submitted q']);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpLibrary(tester);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('library q'), findsOneWidget);

    await tester.enterText(field, '');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Clear history'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(prefs.getStringList('search_history.library.$accountId'), isNull);
    expect(prefs.getStringList('search_history.discover.$accountId'),
        ['discover q']);
  });
}

Future<_SearchAdapter> _pumpSearch(WidgetTester tester) async {
  final adapter = _SearchAdapter();
  final api = ApiClient(
      storage: SecureStorage(), dio: Dio()..httpClientAdapter = adapter);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider(create: (_) => QueueProvider(api)),
      ],
      child: const MaterialApp(home: SearchScreen()),
    ),
  );
  await tester.pump();
  return adapter;
}

Future<void> _pumpLibrary(WidgetTester tester) async {
  final api = ApiClient(storage: SecureStorage());
  final db =
      OfflineDatabase(databaseProvider: () async => throw StateError('no db'));
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<ConnectivityService>.value(
          value: _OfflineConnectivity(),
        ),
        Provider<OfflineDatabase>.value(value: db),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pump();
}

class _OfflineConnectivity extends ConnectivityService {
  @override
  bool get isOnline => false;
}

String _jwt(String accountId) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.${part({'user_id': accountId})}.signature';
}

class _SearchAdapter implements HttpClientAdapter {
  final queries = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final isSearch = options.path == '/discovery/search';
    if (isSearch) queries.add(options.queryParameters['q'] as String);
    return ResponseBody.fromString(
        jsonEncode(isSearch
            ? {
                'query': options.queryParameters['q'],
                'results': [],
                'providers': []
              }
            : {'items': [], 'currentPosition': 0}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}
