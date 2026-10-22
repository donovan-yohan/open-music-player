import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:open_music_player/features/player/widgets/radio_waiting.dart';
import 'package:open_music_player/core/errors/app_error.dart';
import 'package:open_music_player/core/errors/error_handler.dart';
import 'package:open_music_player/shared/widgets/app_snack_bar.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:provider/provider.dart';
import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;

void main() {
  testWidgets(
      'real desktop transport remains bounded and operable during feedback',
      (tester) async {
    final playback = DesktopPlayback();
    await pumpListeningApp(tester, playback, size: const Size(960, 640));
    final messenger = ScaffoldMessenger.of(
        tester.element(find.byKey(const ValueKey('soundq_desktop_shell'))));
    messenger.showSnackBar(
        const AppSnackBar(content: Text('Could not load this track')));
    await tester.pumpAndSettle();
    final transport =
        tester.getRect(find.byKey(const ValueKey('soundq_desktop_transport')));
    expect(transport.height, lessThan(200));
    expect(tester.getRect(_notificationMaterial()).bottom,
        lessThan(transport.top));
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(playback.calls, contains('toggle'));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player failure is compact, dismissible, above desktop transport',
      (tester) async {
    tester.view
      ..physicalSize = const Size(960, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final playback = _FailingPlayback();
    var transportTaps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: DesktopListeningShell(
        compact: true,
        selectedIndex: 0,
        onDestinationSelected: (_) {},
        miniPlayer: SizedBox(
          height: 160,
          child: Center(
              child: TextButton(
            onPressed: () => transportTaps++,
            child: const Text('Transport'),
          )),
        ),
        child: Scaffold(
            body: Builder(
                builder: (context) => Center(
                      child: TextButton(
                          onPressed: () => cancelRadio(context, playback),
                          child: const Text('Cancel playback')),
                    ))),
      ),
    ));
    await tester.tap(find.text('Cancel playback'));
    await tester.pumpAndSettle();
    expect(playback.pauseCalls, 1);
    final material = find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
        .first;
    final rect = tester.getRect(material);
    expect(rect.width, lessThanOrEqualTo(420));
    expect(rect.right, closeTo(944, 1));
    expect(rect.bottom, lessThanOrEqualTo(480));
    expect(find.byTooltip('Close'), findsOneWidget);
    await tester.tap(find.text('Transport'));
    expect(transportTaps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    // Traverse normally rather than requesting a private close-button focus.
    for (var i = 0; i < 60; i++) {
      final closeFocused = find
          .descendant(
            of: find.byTooltip('Close'),
            matching: find.byWidgetPredicate((w) => w is Focus),
          )
          .evaluate()
          .any((element) =>
              identical(element, FocusManager.instance.primaryFocus?.context));
      if (closeFocused) break;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final size in [
    const Size(960, 640),
    const Size(1440, 900),
    const Size(960, 360)
  ]) {
    testWidgets('long error at 2x stays scrollable and closable at $size',
        (tester) async {
      _viewport(tester, size);
      late BuildContext feedbackContext;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: AppFeedbackTheme(child: child!),
        ),
        home: DesktopListeningShell(
          compact: size.width < 1200,
          selectedIndex: 2,
          onDestinationSelected: (_) {},
          miniPlayer: const SizedBox(height: 140),
          child: Scaffold(body: Builder(builder: (context) {
            feedbackContext = context;
            return const Center(child: Text('Library'));
          })),
        ),
      ));
      ErrorHandler().handle(
          AppError(
              code: 'LONG',
              category: ErrorCategory.network,
              message:
                  '${List.filled(60, 'Could not load this track.').join(' ')} END'),
          context: feedbackContext,
          onRetry: () {});
      await tester.pumpAndSettle();
      final rect = tester.getRect(_notificationMaterial());
      expect(rect.width, 400);
      expect(rect.right, size.width - 16);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(tester.getRect(find.byTooltip('Close')).bottom,
          lessThan(size.height));
      final scrollable = find
          .descendant(
              of: find.byType(SnackBar), matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('scrollwrapped feedback message remains in a native live region',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final semantics = tester.ensureSemantics();
    try {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      const message = 'Could not update the playlist. Please try again.';
      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: messenger,
        theme: AppTheme.darkTheme,
        builder: (_, child) => AppFeedbackTheme(child: child!),
        home: const Scaffold(body: Text('Library')),
      ));
      messenger.currentState!.showSnackBar(const AppSnackBar(
        content: Text(message),
        persist: true,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      final messageNode = tester.getSemantics(find.text(message));
      expect(messageNode.label, contains(message));
      var node = messageNode;
      while (!node.flagsCollection.isLiveRegion && node.parent != null) {
        node = node.parent!;
      }
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(
          tester
              .getSemantics(find.byTooltip('Close'))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'native controller, queue, Undo, timeout, hide, remove and clear survive',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final messenger = GlobalKey<ScaffoldMessengerState>();
    var undo = 0;
    var visible = 0;
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messenger,
      theme: AppTheme.darkTheme,
      builder: (_, child) => AppFeedbackTheme(child: child!),
      home: const Scaffold(body: Text('Library')),
    ));
    final first = messenger.currentState!.showSnackBar(AppSnackBar(
      key: GlobalKey(),
      content: const Text('Removed track'),
      onVisible: () => visible++,
      duration: const Duration(seconds: 20),
      action: SnackBarAction(label: 'Undo', onPressed: () => undo++),
    ));
    final second = messenger.currentState!.showSnackBar(const AppSnackBar(
      content: Text('Next notification'),
      duration: Duration(milliseconds: 100),
    ));
    await tester.pumpAndSettle();
    expect(visible, 1);
    expect(find.text('Next notification'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undo, 1);
    expect(await first.closed, SnackBarClosedReason.action);
    expect(find.text('Next notification'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await second.closed, SnackBarClosedReason.timeout);
    final closed = messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Close me')));
    await tester.pumpAndSettle();
    closed.close();
    await tester.pumpAndSettle();
    expect(await closed.closed, SnackBarClosedReason.hide);
    final removed = messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Remove me')));
    await tester.pumpAndSettle();
    messenger.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(await removed.closed, SnackBarClosedReason.remove);
    final cleared = messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Clear me')));
    messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Never shown')));
    await tester.pumpAndSettle();
    messenger.currentState!.clearSnackBars();
    await tester.pumpAndSettle();
    expect(await cleared.closed, SnackBarClosedReason.hide);
    expect(find.text('Never shown'), findsNothing);
  });

  testWidgets('unmigrated auth SnackBars inherit compact desktop defaults',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messenger,
      builder: (_, child) => AppFeedbackTheme(child: child!),
      home: const Scaffold(body: Text('Sign in')),
    ));
    messenger.currentState!.showSnackBar(
        const SnackBar(content: Text('Unable to connect to server')));
    await tester.pumpAndSettle();
    expect(tester.getRect(_notificationMaterial()).width, 400);
    expect(tester.getRect(_notificationMaterial()).right, 1424);
    expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('mobile retains original fixed and explicit floating behavior',
      (tester) async {
    _viewport(tester, const Size(390, 844));
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messenger,
      builder: (_, child) => AppFeedbackTheme(child: child!),
      home: const Scaffold(body: Text('Library')),
    ));
    messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Mobile')));
    await tester.pumpAndSettle();
    expect(tester.getSize(_notificationMaterial()).width, 390);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    messenger.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    messenger.currentState!.showSnackBar(const AppSnackBar(
        content: Text('Mobile floating'), behavior: SnackBarBehavior.floating));
    await tester.pumpAndSettle();
    expect(tester.getSize(_notificationMaterial()).width, 360);
    expect(find.byTooltip('Close'), findsNothing);
    messenger.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    messenger.currentState!.showSnackBar(const AppSnackBar(
      content: Text('Mobile explicit width'),
      behavior: SnackBarBehavior.floating,
      width: 300,
      backgroundColor: Colors.red,
      persist: true,
    ));
    await tester.pumpAndSettle();
    final surface = tester.getRect(_notificationMaterial());
    expect(surface.width, 300);
    expect(surface.center.dx, 195);
    expect(tester.widget<Material>(_notificationMaterial()).color, Colors.red);
    expect(find.byTooltip('Close'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    messenger.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'route changes retain the native notification queue and dialog feedback',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final navigator = GlobalKey<NavigatorState>();
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      scaffoldMessengerKey: messenger,
      theme: AppTheme.darkTheme,
      builder: (_, child) => AppFeedbackTheme(child: child!),
      home: const Scaffold(body: Text('Library')),
    ));
    final active = messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Still here')));
    await tester.pumpAndSettle();
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Player'))));
    await tester.pumpAndSettle();
    expect(find.text('Still here'), findsOneWidget);
    expect(tester.getRect(_notificationMaterial()).right, 1424);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(await active.closed, SnackBarClosedReason.dismiss);
    final context = tester.element(find.text('Player'));
    var retryCalls = 0;
    showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              content: const Text('Playlist operation'),
              actions: [
                TextButton(
                    onPressed: () {
                      Navigator.of(dialogContext).pop();
                      context.showError(AppError.network(),
                          onRetry: () => retryCalls++);
                    },
                    child: const Text('Show failure'))
              ],
            ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show failure'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
    expect(retryCalls, 0);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retryCalls, 1);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'distinct root and nested feedback retain native Hero identity on push',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final navigator = GlobalKey<NavigatorState>();
    final root = GlobalKey<ScaffoldMessengerState>();
    final nested = GlobalKey<ScaffoldMessengerState>();
    var rootVisible = 0;
    var nestedVisible = 0;
    const rootKey = ValueKey('root_feedback');
    const nestedKey = ValueKey('nested_feedback');
    const rootContent = Text('Root failure');
    const nestedContent = Text('Nested failure');
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      scaffoldMessengerKey: root,
      theme: AppTheme.darkTheme,
      builder: (_, child) => AppFeedbackTheme(child: child!),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: 600,
            height: 500,
            child: ScaffoldMessenger(
              key: nested,
              child: const Scaffold(body: Text('Nested panel')),
            ),
          ),
        ),
      ),
    ));
    final rootController = root.currentState!.showSnackBar(AppSnackBar(
      key: rootKey,
      content: rootContent,
      persist: true,
      onVisible: () => rootVisible++,
    ));
    final nestedController = nested.currentState!.showSnackBar(AppSnackBar(
      key: nestedKey,
      content: nestedContent,
      persist: true,
      onVisible: () => nestedVisible++,
    ));
    await tester.pumpAndSettle();
    expect(find.text('Root failure'), findsOneWidget);
    expect(find.text('Nested failure'), findsOneWidget);
    var rootClosed = false;
    var nestedClosed = false;
    rootController.closed.then((_) => rootClosed = true);
    nestedController.closed.then((_) => nestedClosed = true);
    await tester.pump(const Duration(seconds: 5));
    expect(rootClosed, isFalse);
    expect(nestedClosed, isFalse);
    expect(rootVisible, 1);
    expect(nestedVisible, 1);
    final heroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
    final tags = heroes.map((hero) => hero.tag).toList();

    // The real route transition must collect both Heroes, not just build them.
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Player'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        tags,
        unorderedEquals([
          '<SnackBar Hero tag - $rootContent>',
          '<SnackBar Hero tag - $nestedContent>',
        ]));
    expect(find.byKey(rootKey), findsOneWidget);
    expect(find.text('Root failure'), findsOneWidget);
    expect(tester.getRect(_notificationMaterial()).right, 1424);
    rootController.close();
    await tester.pumpAndSettle();
    expect(await rootController.closed, SnackBarClosedReason.hide);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byKey(nestedKey), findsOneWidget);
    expect(find.text('Nested failure'), findsOneWidget);
    expect(rootVisible, 1);
    expect(nestedVisible, 1);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(await nestedController.closed, SnackBarClosedReason.dismiss);
    expect(tester.takeException(), isNull);
  });

  for (final panelWidth in [1440.0, 600.0, 360.0]) {
    for (final width in [300.0, 520.0]) {
      testWidgets(
          'explicit feedback width $width stays native and reachable in $panelWidth slot',
          (tester) async {
        _viewport(tester, const Size(1440, 900));
        final messenger = GlobalKey<ScaffoldMessengerState>();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (_, child) => AppFeedbackTheme(child: child!),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: panelWidth,
                height: panelWidth == 1440 ? 900 : 500,
                child: ScaffoldMessenger(
                  key: messenger,
                  child: const Scaffold(body: Text('Panel')),
                ),
              ),
            ),
          ),
        ));
        final controller = messenger.currentState!.showSnackBar(AppSnackBar(
          content: const Text('Explicit width'),
          behavior: SnackBarBehavior.floating,
          width: width,
          persist: true,
        ));
        await tester.pumpAndSettle();
        final surface = tester.getRect(_notificationMaterial());
        final expectedWidth = width < panelWidth ? width : panelWidth;
        expect(surface.right, lessThanOrEqualTo(1440),
            reason: 'Surface must stay in the viewport: $surface');
        expect(surface.width, expectedWidth);
        expect(surface.center.dx, 1440 - panelWidth / 2);
        expect(surface.left, greaterThanOrEqualTo(1440 - panelWidth));
        expect(surface.top, greaterThanOrEqualTo(0));
        expect(
            surface.bottom, lessThanOrEqualTo(panelWidth == 1440 ? 900 : 500));
        expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(await controller.closed, SnackBarClosedReason.dismiss);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('a smaller nested messenger uses local width, not root margins',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      builder: (_, child) => AppFeedbackTheme(child: child!),
      home: Scaffold(
          body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: 600,
                height: 500,
                child: ScaffoldMessenger(
                    key: messenger,
                    child: const Scaffold(body: Text('Nested panel'))),
              ))),
    ));
    messenger.currentState!
        .showSnackBar(const AppSnackBar(content: Text('Nested failure')));
    await tester.pumpAndSettle();
    expect(tester.getRect(_notificationMaterial()).width, 400);
    expect(tester.getRect(_notificationMaterial()).right, 1424);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'real local library heart failure keeps state and corner feedback',
      (tester) async {
    _viewport(tester, const Size(1440, 900));
    final service = _FailingLibrary();
    final liked = LikedTracksState(service);
    addTearDown(liked.dispose);
    await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: liked),
          ListenableProvider<PlaybackState>.value(value: _FailingPlayback()),
        ],
        child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: DesktopListeningShell(
              compact: false,
              selectedIndex: 2,
              onDestinationSelected: (_) {},
              miniPlayer: const SizedBox(height: 140),
              child:
                  LocalArtistScreen(artist: 'Artist', libraryService: service),
            ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('local_browse_like_1')));
    await tester.pumpAndSettle();
    expect(service.calls, 1);
    expect(liked.isLiked(1), isFalse);
    expect(find.text('Could not update liked status'), findsOneWidget);
    expect(tester.getRect(_notificationMaterial()).right, 1424);
    expect(
        tester.getRect(_notificationMaterial()).bottom, lessThanOrEqualTo(760));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(service.calls, 1);
  });
}

void _viewport(WidgetTester tester, Size size) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _notificationMaterial() => find
    .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
    .first;

class _FailingLibrary extends LibraryService {
  _FailingLibrary() : super(ApiClient());
  int calls = 0;
  @override
  Future<void> like(int trackId) async {
    calls++;
    throw StateError('injected library failure');
  }

  @override
  Future<List<Track>> getLibraryByArtist(String artist,
          {int limit = 500}) async =>
      [
        Track.fromJson({
          'id': 1,
          'title': 'Track',
          'artist': 'Artist',
          'is_liked': false,
        })
      ];
}

class _FailingPlayback extends Fake implements PlaybackState {
  int pauseCalls = 0;
  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot.empty();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  Future<void> pause() async {
    pauseCalls++;
    throw StateError('injected pause failure');
  }
}
