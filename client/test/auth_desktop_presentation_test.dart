import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/auth/screens/login_screen.dart';
import 'package:open_music_player/features/auth/screens/register_screen.dart';
import 'package:provider/provider.dart';

Future<void> pumpAuth(WidgetTester tester, Widget screen,
    {Size size = const Size(1440, 900),
    double scale = 1,
    bool light = false,
    bool reduced = false,
    bool accessible = false,
    bool ticker = true,
    bool settle = true,
    AuthState? auth}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = auth ??
      AuthState(
          authService: AuthService(api: ApiClient(), storage: SecureStorage()));
  if (auth == null) addTearDown(state.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
    value: state,
    child: MaterialApp(
      theme: light ? AppTheme.lightTheme : AppTheme.darkTheme,
      home: MediaQuery(
        data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
            accessibleNavigation: accessible),
        child: TickerMode(enabled: ticker, child: screen),
      ),
    ),
  ));
  if (settle) await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'login retains autofill, next focus, keyboard submission and loading',
      (tester) async {
    final auth = _SubmissionAuth();
    addTearDown(auth.dispose);
    await pumpAuth(tester, const LoginScreen(), auth: auth);
    final fields = find.byType(TextFormField);
    final email = tester.widget<TextField>(find.byType(TextField).first);
    expect(email.autofillHints, contains(AutofillHints.email));
    expect(tester.widget<TextField>(find.byType(TextField).last).autofillHints,
        contains(AutofillHints.password));
    await tester.enterText(fields.first, 'listener@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText).last)
            .focusNode
            .hasFocus,
        isTrue);
    await tester.enterText(fields.last, 'fixture-password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(auth.calls, 1);
    expect(auth.email, 'listener@example.com');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(tester.widget<TextField>(find.byType(TextField).first).enabled,
        isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    auth.finish(false);
    await tester.pumpAndSettle();
    expect(find.text('Fixture sign-in failure'), findsOneWidget);
  });

  for (final next in [
    '/queue/imports',
    '//untrusted.example',
    'https://untrusted.example'
  ]) {
    testWidgets('login preserves safe next redirect $next', (tester) async {
      final auth = _SubmissionAuth();
      addTearDown(auth.dispose);
      final router = GoRouter(
          initialLocation: '/login?next=${Uri.encodeComponent(next)}',
          routes: [
            GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
            GoRoute(
                path: '/home',
                builder: (_, __) => const Scaffold(body: Text('home landing'))),
            GoRoute(
                path: '/queue/imports',
                builder: (_, __) =>
                    const Scaffold(body: Text('imports landing'))),
          ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(ChangeNotifierProvider<AuthState>.value(
          value: auth,
          child: MaterialApp.router(
              theme: AppTheme.darkTheme, routerConfig: router)));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextFormField).first, 'listener@example.com');
      await tester.enterText(
          find.byType(TextFormField).last, 'fixture-password');
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      auth.finish(true);
      await tester.pumpAndSettle();
      expect(
          find.text(
              next == '/queue/imports' ? 'imports landing' : 'home landing'),
          findsOneWidget);
    });
  }

  testWidgets(
      'registration retains mismatch validation and keyboard submission',
      (tester) async {
    final auth = _SubmissionAuth();
    addTearDown(auth.dispose);
    await pumpAuth(tester, const RegisterScreen(), auth: auth);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'listener');
    await tester.enterText(fields.at(1), 'listener@example.com');
    await tester.enterText(fields.at(2), 'fixture-password');
    await tester.enterText(fields.at(3), 'mismatch');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(auth.calls, 0);
    await tester.enterText(fields.at(3), 'fixture-password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(auth.calls, 1);
    expect(auth.username, 'listener');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    auth.finish(false);
    await tester.pumpAndSettle();
    expect(find.text('Fixture sign-in failure'), findsOneWidget);
  });

  testWidgets(
      'large-text registration labels remain complete rather than ellipsized',
      (tester) async {
    await pumpAuth(tester, const RegisterScreen(),
        size: const Size(360, 800), scale: 2);
    final paragraphs =
        tester.renderObjectList<RenderParagraph>(find.byType(RichText));
    expect(
        paragraphs.where((p) =>
            p.text.toPlainText() == 'Confirm Password' && p.didExceedMaxLines),
        isEmpty);
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(
        field.decoration?.floatingLabelBehavior, FloatingLabelBehavior.always);
  });

  testWidgets('hiding an active auth entrance retires its ticker',
      (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    await pumpAuth(
        tester,
        ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
            child: const LoginScreen()),
        settle: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    visible.value = false;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    visible.value = true;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('opening only repaints atmosphere, never rebuilds form fields',
      (tester) async {
    await pumpAuth(tester, const LoginScreen(), settle: false);
    var fieldRebuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is TextFormField) fieldRebuilds++;
    };
    try {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(fieldRebuilds, 0);
      expect(tester.binding.transientCallbackCount, 0);
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
  });

  testWidgets('registration visibility controls have accessible action names',
      (tester) async {
    await pumpAuth(tester, const RegisterScreen());
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byTooltip('Show confirmed password'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide password'), findsOneWidget);
  });

  for (final config in [
    (true, false, true),
    (false, true, true),
    (false, false, false)
  ]) {
    testWidgets('motion disabled for reduce/accessibility/ticker $config',
        (tester) async {
      await pumpAuth(tester, const LoginScreen(),
          reduced: config.$1,
          accessible: config.$2,
          ticker: config.$3,
          settle: false);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('inactivation retires an opening ticker without resuming it',
      (tester) async {
    await pumpAuth(tester, const LoginScreen(), settle: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final screen in [const LoginScreen(), const RegisterScreen()]) {
    for (final size in [
      const Size(360, 800),
      const Size(390, 844),
      const Size(1024, 320),
      const Size(1440, 900),
      const Size(2560, 1440)
    ]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
            '${screen.runtimeType} ${size.width}x${size.height} at $scale text',
            (tester) async {
          await pumpAuth(tester, screen, size: size, scale: scale);
          expect(tester.takeException(), isNull);
          final field = tester.getRect(find.byType(TextFormField).first);
          expect(field.width, lessThanOrEqualTo(400));
          expect(field.left, greaterThanOrEqualTo(16));
          final submit = find.byType(FilledButton);
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(find.text('Please enter your email'), findsOneWidget);
          for (final editable
              in find.byType(TextFormField).evaluate().toList()) {
            final target = find.byWidget(editable.widget);
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            expect(tester.getRect(target).overlaps(Offset.zero & size), isTrue);
            expect(tester.takeException(), isNull);
          }
          await tester.ensureVisible(submit);
          await tester.pumpAndSettle();
          expect(submit.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final screen in [const LoginScreen(), const RegisterScreen()]) {
    testWidgets(
        '${screen.runtimeType} light theme preserves compact control geometry',
        (tester) async {
      await pumpAuth(tester, screen, light: true);
      final fields = find.byType(TextFormField);
      final editable = tester.getSize(find.byType(TextField).first);
      expect(editable.height, inInclusiveRange(48, 56));
      expect(tester.getSize(fields.first).width, inInclusiveRange(360, 400));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('auth atmosphere opens once then stops scheduling frames',
      (tester) async {
    await pumpAuth(tester, const LoginScreen(), settle: false);
    expect(find.byKey(const ValueKey('auth-atmosphere')), findsOneWidget);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
  testWidgets('desktop registration shares the bounded credential column',
      (tester) async {
    await pumpAuth(tester, const RegisterScreen());
    for (final field in find.byType(TextFormField).evaluate()) {
      expect(tester.getSize(find.byWidget(field.widget)).width,
          inInclusiveRange(360, 400));
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop login credentials stay in a human-sized column',
      (tester) async {
    await pumpAuth(tester, const LoginScreen());
    final field = tester.getRect(find.byType(TextFormField).first);
    expect(field.width, inInclusiveRange(360, 400));
    expect(field.center.dx, 720);
    expect(tester.takeException(), isNull);
  });
}

// Screen contract fake: no HTTP, token writes or real account credentials.
class _SubmissionAuth extends AuthState {
  _SubmissionAuth()
      : super(
            authService:
                AuthService(api: ApiClient(), storage: SecureStorage()));
  final _result = Completer<bool>();
  bool _loading = false;
  String? _message;
  int calls = 0;
  String? email;
  String? username;
  @override
  bool get isLoading => _loading;
  @override
  String? get error => _message;
  @override
  void clearError() {}
  Future<bool> _submit() async {
    calls++;
    _loading = true;
    notifyListeners();
    final result = await _result.future;
    _loading = false;
    _message = result ? null : 'Fixture sign-in failure';
    notifyListeners();
    return result;
  }

  void finish(bool success) => _result.complete(success);
  @override
  Future<bool> login({required String email, required String password}) {
    this.email = email;
    return _submit();
  }

  @override
  Future<bool> register(
      {required String username,
      required String email,
      required String password}) {
    this.email = email;
    this.username = username;
    return _submit();
  }
}
