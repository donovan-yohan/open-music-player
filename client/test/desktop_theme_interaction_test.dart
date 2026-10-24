import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/auth/auth_frame.dart';
import 'package:open_music_player/features/auth/screens/login_screen.dart';
import 'auth_desktop_presentation_test.dart' show pumpAuth;
import 'desktop_listening_transport_test.dart'
    show pumpListeningApp, DesktopPlayback;
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/core/commands/command_widgets.dart';
import 'package:open_music_player/shared/widgets/app_snack_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'connect_app_composition_test.dart' show ConnectPlayback, NoSharedIntent;

import 'desktop_listening_shell_test.dart' show shellRouter;

void main() {
  testWidgets('production login keeps square desktop controls reachable at 2x',
      (tester) async {
    await pumpAuth(tester, const SoundQDesktopTheme(child: LoginScreen()),
        size: const Size(960, 600), scale: 2);
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton).hitTestable(), findsOneWidget);
    for (final material in tester.widgetList<Material>(find.descendant(
        of: find.byType(FilledButton), matching: find.byType(Material)))) {
      expect((material.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.zero);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'disabled primary transport does not retain actionable orange fill',
      (tester) async {
    await pumpListeningApp(tester, _UnavailablePlayback());
    final play =
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Pause');
    expect(tester.widget<IconButton>(play).onPressed, isNull);
    final material = tester.widget<Material>(
        find.descendant(of: play, matching: find.byType(Material)).first);
    expect(material.color, isNot(AppTheme.orange));
  });
  testWidgets(
      'real selected chip shows cyan hover without losing orange selection',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = true;
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: SoundQDesktopTheme(
            child: Scaffold(
                body: StatefulBuilder(
                    builder: (context, setState) => Center(
                        child: FilterChip(
                            selected: selected,
                            label: const Text('Selected filter'),
                            onSelected: (value) =>
                                setState(() => selected = value))))))));
    await tester.pumpAndSettle();
    Material material() => tester.widget<Material>(find
        .descendant(
            of: find.byType(FilterChip), matching: find.byType(Material))
        .first);
    expect((material().shape! as OutlinedBorder).side.color, AppTheme.orange);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(FilterChip)));
    await tester.pumpAndSettle();
    expect((material().shape! as OutlinedBorder).side.color, AppTheme.accent);
    expect(tester.widget<FilterChip>(find.byType(FilterChip)).selected, isTrue);
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(selected, isFalse);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  for (final width in [960.0, 1440.0, 2560.0]) {
    testWidgets('native desktop menu stays reachable at 2x text on $width',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var invoked = false;
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: SoundQDesktopTheme(child: child!)),
          home: Scaffold(
              body: Center(
                  child: MenuAnchor(
                      menuChildren: [
                MenuItemButton(
                    onPressed: () => invoked = true,
                    child: const Text('Add to playlist')),
                const MenuItemButton(child: Text('Unavailable')),
              ],
                      builder: (context, controller, child) => OutlinedButton(
                          onPressed: controller.open,
                          child: const Text('Open menu')))))));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Add to playlist').hitTestable(), findsOneWidget);
      expect(tester.getRect(find.text('Add to playlist')).right,
          lessThanOrEqualTo(width));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(invoked, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('disabled chip label stays muted during real pointer hover',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: const SoundQDesktopTheme(
            child: Scaffold(
                body: Center(
                    child: FilterChip(
                        label: Text('Unavailable'), onSelected: null))))));
    await tester.pumpAndSettle();
    Color? labelColor() =>
        DefaultTextStyle.of(tester.element(find.text('Unavailable')))
            .style
            .color;
    final theme = Theme.of(tester.element(find.byType(FilterChip)));
    expect(labelColor(), theme.disabledColor);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(FilterChip)));
    await tester.pumpAndSettle();
    expect(labelColor(), theme.disabledColor);
    await mouse.removePointer();
  });

  test('theme adaptation preserves custom menu constraints and typography', () {
    final base = AppTheme.darkTheme.copyWith(
        menuTheme: const MenuThemeData(
            style: MenuStyle(
                minimumSize: WidgetStatePropertyAll(Size(220, 56)),
                maximumSize: WidgetStatePropertyAll(Size(500, 600)))),
        menuButtonTheme: const MenuButtonThemeData(
            style: ButtonStyle(
                shape: WidgetStatePropertyAll(StadiumBorder()),
                minimumSize: WidgetStatePropertyAll(Size(180, 52)),
                padding: WidgetStatePropertyAll(EdgeInsets.all(16)))));
    final adapted = SoundQDesktopTheme.apply(base);
    expect(adapted.colorScheme, base.colorScheme);
    expect(adapted.textTheme.bodyMedium?.fontFamily, 'Space Grotesk');
    expect(adapted.textTheme.bodyMedium?.fontSize,
        base.textTheme.bodyMedium?.fontSize);
    expect(adapted.extensions, base.extensions);
    expect(adapted.menuTheme.style?.minimumSize,
        base.menuTheme.style?.minimumSize);
    expect(adapted.menuTheme.style?.maximumSize,
        base.menuTheme.style?.maximumSize);
    expect(adapted.menuButtonTheme.style?.minimumSize,
        base.menuButtonTheme.style?.minimumSize);
    expect(adapted.menuButtonTheme.style?.padding,
        base.menuButtonTheme.style?.padding);
    expect(adapted.menuButtonTheme.style?.shape?.resolve({}),
        const RoundedRectangleBorder());
    final native = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    expect(native.menuButtonTheme.style?.minimumSize, isNull);
    expect(native.menuButtonTheme.style?.padding, isNull);
  });

  testWidgets('desktop button presentation is immediate for reduced motion',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: SoundQDesktopTheme(child: child!)),
        home: Scaffold(
            body: OutlinedButton(
                onPressed: () {}, child: const Text('Action')))));
    await tester.pumpAndSettle();
    final style = Theme.of(tester.element(find.byType(OutlinedButton)))
        .outlinedButtonTheme
        .style;
    expect(style?.animationDuration, Duration.zero);
  });
  testWidgets(
      'desktop transport keeps geometry but removes identity and play rounding',
      (tester) async {
    await pumpListeningApp(tester, DesktopPlayback(),
        size: const Size(960, 600));
    final identity = find.byTooltip('Open now playing');
    for (final clip in tester.widgetList<ClipRRect>(
        find.descendant(of: identity, matching: find.byType(ClipRRect)))) {
      expect(clip.borderRadius, BorderRadius.zero);
    }
    final ink = tester.widget<InkWell>(
        find.descendant(of: identity, matching: find.byType(InkWell)));
    expect(ink.borderRadius, BorderRadius.zero);
    final play =
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Pause');
    final material = tester.widget<Material>(
        find.descendant(of: play, matching: find.byType(Material)).first);
    final shape = material.shape! as OutlinedBorder;
    final path = shape.getOuterPath(const Rect.fromLTWH(0, 0, 48, 48));
    expect(path.getBounds(), const Rect.fromLTWH(0, 0, 48, 48));
    for (final corner in [
      const Offset(.01, .01),
      const Offset(47.99, .01),
      const Offset(.01, 47.99),
      const Offset(47.99, 47.99),
    ]) {
      expect(path.contains(corner), isTrue);
    }
    expect(shape.side.width, 1);
    expect(tester.getSize(play), const Size(48, 48));
    expect(
        tester
            .getSize(find.byKey(const ValueKey('soundq_desktop_transport')))
            .height,
        inInclusiveRange(88, 100));
    expect(tester.getCenter(play).dx, 480);
  });

  testWidgets('auth frame is angular only at desktop window boundary',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [959.0, 960.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          home:
              const AuthFrame(title: 'Sign in', child: Text('Auth content'))));
      await tester.pumpAndSettle();
      final panel = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .singleWhere((d) => d.border != null);
      expect(panel.boxShadow, width < 960 ? isNotEmpty : isNull);
      expect(panel.borderRadius,
          width < 960 ? BorderRadius.circular(16) : BorderRadius.zero);
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(clip.borderRadius,
          width < 960 ? BorderRadius.circular(10) : BorderRadius.zero);
    }
  });

  testWidgets(
      'desktop feedback has square thin outline without replacing native controller',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [959.0, 960.0]) {
      tester.view.physicalSize = Size(width, 800);
      final messenger = GlobalKey<ScaffoldMessengerState>();
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          scaffoldMessengerKey: messenger,
          home: const AppFeedbackTheme(child: Scaffold(body: Text('Body')))));
      await tester.pumpAndSettle();
      final controller = messenger.currentState!
          .showSnackBar(const AppSnackBar(content: Text('Feedback')));
      await tester.pumpAndSettle();
      final snack = find.byType(SnackBar).last;
      final theme = Theme.of(tester.element(snack));
      if (width >= 960) {
        final shape = theme.snackBarTheme.shape;
        expect(shape, isA<RoundedRectangleBorder>());
        expect(
            (shape! as RoundedRectangleBorder).borderRadius, BorderRadius.zero);
        expect((shape as RoundedRectangleBorder).side.width, 1);
      } else {
        expect(
            theme.snackBarTheme.shape, AppTheme.darkTheme.snackBarTheme.shape);
      }
      messenger.currentState!.hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(await controller.closed, SnackBarClosedReason.hide);
    }
  });
  testWidgets(
      'desktop shell joins panel edges with full-width native navigation cells',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = shellRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('soundq_desktop_content_panel'));
    final box = tester.widget<DecoratedBox>(panel).decoration as BoxDecoration;
    expect(box.borderRadius ?? BorderRadius.zero, BorderRadius.zero);
    expect(box.border?.top.width, 1);
    expect(tester.getRect(panel).top, 0);
    expect(tester.getRect(panel).right, 1440);
    final first = find.byKey(const ValueKey('soundq_desktop_nav_focus_0'));
    final second = find.byKey(const ValueKey('soundq_desktop_nav_focus_1'));
    expect(tester.getCenter(second).dy - tester.getCenter(first).dy, 48);
    final rail = find.byKey(const ValueKey('soundq_desktop_rail_container'));
    expect(tester.getSize(rail).width, greaterThanOrEqualTo(224));
    expect(tester.getRect(panel).left, tester.getRect(rail).right);
    expect(tester.getRect(first).left, tester.getRect(rail).left);
    expect(tester.getRect(first).right, tester.getRect(rail).right);
    expect(
        tester.widget<SingleChildScrollView>(
            find.byKey(const ValueKey('soundq_desktop_navigation_rail'))),
        isA<SingleChildScrollView>());

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(first));
    await tester.pumpAndSettle();
    BoxDecoration decoration() =>
        tester.widget<AnimatedContainer>(first).decoration! as BoxDecoration;
    expect(decoration().color, AppTheme.accent,
        reason: 'Hover must remain visible on the orange selected destination');
    expect(decoration().borderRadius ?? BorderRadius.zero, BorderRadius.zero);
    await mouse.moveTo(const Offset(1430, 890));
    final strategy = tester.binding.focusManager.highlightStrategy;
    addTearDown(() => tester.binding.focusManager.highlightStrategy = strategy);
    tester.binding.focusManager.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focused = tester
        .widget<AnimatedContainer>(first)
        .foregroundDecoration! as BoxDecoration;
    expect(focused.border?.top.color,
        Theme.of(tester.element(first)).colorScheme.onSecondary,
        reason: 'focused=${FocusManager.instance.primaryFocus?.debugLabel}');
    expect(focused.border?.top.width, 1);
    expect(decoration().color, isNot(AppTheme.orange));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'desktop Material controls share angular outlined interaction states',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final buttonStates = WidgetStatesController();
    addTearDown(buttonStates.dispose);
    final router = shellRouter(
        content: Wrap(spacing: 8, children: [
      FilledButton(onPressed: () {}, child: const Text('Primary')),
      ElevatedButton(onPressed: () {}, child: const Text('Elevated')),
      OutlinedButton(
          statesController: buttonStates,
          onPressed: () {},
          child: const Text('Outline')),
      TextButton(onPressed: () {}, child: const Text('Text')),
      IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
      FilterChip(label: const Text('Filter'), onSelected: (_) {}),
      const Card(child: Text('Card')),
      const SizedBox(width: 180, child: TextField()),
    ]));
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.byType(FilterChip)));
    final colors = theme.colorScheme;
    for (final style in [
      theme.filledButtonTheme.style,
      theme.elevatedButtonTheme.style,
      theme.textButtonTheme.style,
      theme.iconButtonTheme.style,
      theme.outlinedButtonTheme.style
    ]) {
      expect(style?.shape?.resolve({}), const RoundedRectangleBorder());
      expect(style?.side?.resolve({})?.width, 1);
      expect(
          style?.overlayColor
              ?.resolve({WidgetState.disabled, WidgetState.hovered}),
          Colors.transparent);
      expect(style?.overlayColor?.resolve({WidgetState.hovered}),
          Colors.transparent);
      expect(style?.backgroundColor?.resolve({WidgetState.hovered}),
          colors.secondary);
      expect(
          style?.side?.resolve({WidgetState.focused})?.color, colors.secondary);
    }
    final chip = theme.chipTheme;
    expect(chip.shape, const RoundedRectangleBorder());
    expect(chip.side, isA<WidgetStateBorderSide>());
    final side = chip.side! as WidgetStateBorderSide;
    expect(side.resolve({})?.color, colors.secondary);
    expect(side.resolve({WidgetState.selected})?.color, colors.primary);
    expect(side.resolve({WidgetState.selected, WidgetState.hovered})?.color,
        colors.secondary);
    expect(side.resolve({WidgetState.disabled, WidgetState.hovered})?.color,
        isNot(colors.secondary));
    expect(chip.color?.resolve({WidgetState.selected, WidgetState.hovered}),
        isNot(chip.color?.resolve({WidgetState.selected})));
    expect((theme.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.zero);
    for (final border in [
      theme.inputDecorationTheme.enabledBorder,
      theme.inputDecorationTheme.focusedBorder,
      theme.inputDecorationTheme.disabledBorder,
      theme.inputDecorationTheme.errorBorder
    ]) {
      expect((border! as OutlineInputBorder).borderRadius, BorderRadius.zero);
      expect(border.borderSide.width, 1);
    }
    expect(theme.inputDecorationTheme.focusedBorder?.borderSide.color,
        colors.secondary);
    expect(
        theme.inputDecorationTheme.errorBorder?.borderSide.color, colors.error);
    expect(theme.navigationRailTheme.indicatorShape,
        isA<RoundedRectangleBorder>());
    expect(theme.popupMenuTheme.shape, isA<RoundedRectangleBorder>());
    expect(theme.menuTheme.style?.shape?.resolve({}),
        isA<RoundedRectangleBorder>());
    expect(theme.menuButtonTheme.style?.shape?.resolve({}),
        const RoundedRectangleBorder());
    expect(theme.tooltipTheme.decoration, isA<BoxDecoration>());
    expect((theme.tooltipTheme.decoration! as BoxDecoration).borderRadius,
        BorderRadius.zero);
    expect(theme.sliderTheme.secondaryActiveTrackColor, colors.secondary);
    expect(theme.textSelectionTheme.cursorColor, colors.secondary);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Outline')));
    await tester.pumpAndSettle();
    expect(buttonStates.value, contains(WidgetState.hovered));
    final material = tester.widget<Material>(find
        .descendant(
            of: find.byType(OutlinedButton), matching: find.byType(Material))
        .first);
    expect((material.shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.zero);
    expect((material.shape! as RoundedRectangleBorder).side.color,
        colors.secondary);
    expect(tester.getSize(find.byType(OutlinedButton)).height,
        greaterThanOrEqualTo(40));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'production root themes commands and feedback at desktop boundary',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final api = ApiClient();
    final auth =
        AuthState(authService: AuthService(api: api, storage: SecureStorage()));
    final playback = ConnectPlayback();
    final app = OpenMusicPlayerApp(
        apiClient: api,
        authState: auth,
        playbackState: playback,
        sharedIntentReceiver: NoSharedIntent());
    app.router.go('/login');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(959, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: app));
    await tester.pumpAndSettle();
    expect(
        Theme.of(tester.element(find.byType(CommandHost)))
            .outlinedButtonTheme
            .style,
        isNull);
    tester.view.physicalSize = const Size(960, 800);
    await tester.pumpAndSettle();
    for (final finder in [
      find.byType(CommandHost),
      find.byType(AppFeedbackTheme),
      find.byType(FilledButton)
    ]) {
      expect(
          Theme.of(tester.element(finder)).outlinedButtonTheme.style, isNotNull,
          reason: 'Desktop adapter must precede commands and feedback');
    }
    await tester.pumpWidget(const SizedBox());
    app.router.dispose();
    auth.dispose();
    await playback.source.close();
  });
  testWidgets(
      'routed desktop overrides dark theme with square cyan controls at 960',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(959, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = shellRouter(
        content: OutlinedButton(
            onPressed: () {}, child: const Text('Secondary action')));
    addTearDown(router.dispose);
    await tester.pumpWidget(
        MaterialApp.router(theme: AppTheme.lightTheme, routerConfig: router));
    await tester.pumpAndSettle();
    final mobile = Theme.of(tester.element(find.byType(OutlinedButton)));
    expect(mobile.brightness, Brightness.light);
    expect(mobile.outlinedButtonTheme.style?.shape, isNull);

    tester.view.physicalSize = const Size(960, 800);
    await tester.pumpAndSettle();
    final desktop = Theme.of(tester.element(find.byType(OutlinedButton)));
    expect(desktop.brightness, Brightness.dark);
    expect(desktop.colorScheme, AppTheme.darkTheme.colorScheme);
    expect(desktop.textTheme.bodyLarge?.fontSize,
        AppTheme.darkTheme.textTheme.bodyLarge?.fontSize);
    expect(desktop.extension<SoundQPlayerTheme>(), SoundQPlayerTheme.dark);
    expect(desktop.outlinedButtonTheme.style, isNotNull,
        reason: 'Desktop must supply square outlined cyan controls');
    final style = desktop.outlinedButtonTheme.style!;
    expect(style.shape?.resolve({}), const RoundedRectangleBorder());
    expect(style.side?.resolve({}), const BorderSide(color: AppTheme.accent));
    expect(style.foregroundColor?.resolve({}), AppTheme.accent);
    expect(style.minimumSize?.resolve({}), const Size(40, 40));
    expect(style.side?.resolve({WidgetState.focused})?.color, AppTheme.accent);
    expect(
        style.side?.resolve({WidgetState.disabled, WidgetState.hovered})?.color,
        isNot(AppTheme.accent));
    expect(
        style.overlayColor
            ?.resolve({WidgetState.disabled, WidgetState.hovered}),
        Colors.transparent);
    expect(
        style.overlayColor?.resolve({WidgetState.hovered}), Colors.transparent);
    expect(
        style.backgroundColor?.resolve({WidgetState.hovered}), AppTheme.accent);
  });
}

class _UnavailablePlayback extends DesktopPlayback {
  @override
  bool get hasTrack => false;
}
