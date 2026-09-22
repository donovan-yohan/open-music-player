import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/storage/search_history.dart';
import 'package:open_music_player/shared/widgets/recent_searches.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(TextEditingController, FocusNode)> pumpHistory(
    WidgetTester tester,
    SearchHistoryStore store, {
    double width = 360,
    double scale = 1,
    ValueChanged<String>? onSelected,
    AuthState? auth,
  }) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    final app = MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  TextField(controller: controller, focusNode: focus),
                  RecentSearches(
                    controller: controller,
                    focusNode: focus,
                    store: store,
                    onSelected: onSelected ?? (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(auth == null
        ? app
        : ChangeNotifierProvider<AuthState>.value(value: auth, child: app));
    return (controller, focus);
  }

  SearchHistoryStore history() => SearchHistoryStore(
        kind: SearchHistoryKind.discover,
        accountId: () async => 'test',
      );

  testWidgets('only focused empty fields show history; tap and clear work',
      (tester) async {
    final store = history();
    await store.add('Radiohead');
    String? selected;
    final (controller, focus) = await pumpHistory(tester, store,
        onSelected: (query) => selected = query);
    expect(find.text('Recent searches'), findsNothing);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('Radiohead'), findsOneWidget);
    controller.text = 'draft';
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsNothing);
    controller.clear();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Radiohead'));
    expect(selected, 'Radiohead');
    await tester.tap(find.byTooltip('Clear history'));
    await tester.pumpAndSettle();
    expect(await store.load(), isEmpty);
    expect(find.text('Recent searches'), findsNothing);
    expect(tester.getSize(find.byType(RecentSearches)).height, 0);
  });

  testWidgets('account intent hides old history before auth storage changes',
      (tester) async {
    final auth = _TestAuthState();
    addTearDown(auth.dispose);
    var account = 'test';
    final store = SearchHistoryStore(
      kind: SearchHistoryKind.discover,
      accountId: () async => account,
    );
    await store.add('Private query');
    final (_, focus) = await pumpHistory(tester, store, auth: auth);
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(find.text('Private query'), findsOneWidget);
    auth.changeSession(loading: true);
    await tester.pump();
    expect(find.text('Private query'), findsNothing);
    account = 'other';
    auth.changeSession(loading: false);
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsNothing);
  });

  for (final width in [320.0, 360.0, 480.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('clipped next chip and swipe at width $width scale $scale',
          (tester) async {
        final store = history();
        for (var i = 0; i < 12; i++) {
          await store.add('Long music search number $i');
        }
        final (_, focus) =
            await pumpHistory(tester, store, width: width, scale: scale);
        focus.requestFocus();
        await tester.pumpAndSettle();
        final viewport = find.byKey(const ValueKey('recent_searches_discover'));
        final bounds = tester.getRect(viewport);
        final chips = find.byType(ActionChip);
        final rects = [
          for (final element in chips.evaluate())
            tester.getRect(find.byWidget(element.widget))
        ];
        expect(
            rects.any((rect) =>
                rect.left < bounds.right && rect.right > bounds.right),
            isTrue,
            reason: 'A partial next chip must reveal horizontal overflow.');
        final start = tester.getTopLeft(chips.first).dx;
        await tester.drag(viewport, const Offset(-240, 0));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(chips.first).dx, lessThan(start));
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a late load cannot restore history after focus leaves',
      (tester) async {
    final barrier = Completer<SharedPreferences>();
    final requested = Completer<void>();
    final store = SearchHistoryStore(
      kind: SearchHistoryKind.discover,
      accountId: () async => 'test',
      prefs: () {
        requested.complete();
        return barrier.future;
      },
    );
    final (_, focus) = await pumpHistory(tester, store);
    focus.requestFocus();
    await tester.pump();
    await requested.future;
    focus.unfocus();
    await tester.pump();
    barrier.complete(await SharedPreferences.getInstance());
    await tester.pumpAndSettle();
    expect(find.text('Recent searches'), findsNothing);
  });
}

class _TestAuthState extends AuthState {
  _TestAuthState()
      : super(
            authService:
                AuthService(api: ApiClient(), storage: SecureStorage()));

  int _revision = 0;
  bool _loading = false;

  @override
  int get sessionRevision => _revision;
  @override
  bool get isAuthenticated => true;
  @override
  bool get isLoading => _loading;

  void changeSession({required bool loading}) {
    _revision++;
    _loading = loading;
    notifyListeners();
  }
}
