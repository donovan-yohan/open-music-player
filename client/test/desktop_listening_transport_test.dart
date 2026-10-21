import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/commands/command_registry.dart';

void main() {
  for (final width in [390.0, 959.0]) {
    testWidgets('mobile fallback retains the listening mini-player at $width',
        (tester) async {
      await pumpListeningApp(tester, DesktopPlayback(),
          size: Size(width, 844), textScale: 2);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('spotify_like_mini_player')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('soundq_desktop_transport')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('seek has an accessible value and supports keyboard adjustment',
      (tester) async {
    final playback = DesktopPlayback();
    await pumpListeningApp(tester, playback);
    final semantics = tester.ensureSemantics();
    final seek = find.byKey(const ValueKey('soundq_desktop_seek'));
    expect(tester.widget<Slider>(seek).semanticFormatterCallback!(30000),
        '0:30 of 4:00');
    final element = tester.element(seek);
    final node = Focus.of(element);
    node.requestFocus();
    // The Slider owns a descendant focus node; Tab from the preceding play
    // control is also covered by the shell traversal fixture.
    final sliderFocus = find.descendant(
        of: seek, matching: find.byWidgetPredicate((w) => w is Focus));
    for (final match in sliderFocus.evaluate()) {
      final widget = match.widget as Focus;
      if (widget.focusNode?.canRequestFocus == true) {
        widget.focusNode!.requestFocus();
        break;
      }
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
        playback.calls.where((call) => call.startsWith('seek:')), hasLength(1));
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide desktop bounds the seek control instead of stretching it',
      (tester) async {
    await pumpListeningApp(tester, DesktopPlayback(),
        size: const Size(2560, 1440));
    expect(
        tester.getSize(find.byKey(const ValueKey('soundq_desktop_seek'))).width,
        lessThanOrEqualTo(720));
  });

  testWidgets('pending and ended states retain cancellation and replay',
      (tester) async {
    final playback = DesktopPlayback()..pending = true;
    await pumpListeningApp(tester, playback);
    expect(find.text('Starting playback…'), findsOneWidget);
    expect(find.text(playback.item.title), findsNothing);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('soundq_desktop_seek')))
            .onChanged,
        isNull);
    await tester.tap(find.byTooltip('Cancel playback'));
    await tester.pump();
    expect(playback.calls, ['pause']);
    playback.pending = false;
    playback.continuation = ContinuationDisposition.completed;
    playback.playing = false;
    playback.changed();
    await tester.pumpAndSettle();
    expect(find.text('Queue ended'), findsOneWidget);
    await tester.tap(find.byTooltip('Replay'));
    await tester.pump();
    expect(playback.calls.last, 'play');
  });

  testWidgets('a seek gesture never applies to a replacement occurrence',
      (tester) async {
    final playback = DesktopPlayback();
    await pumpListeningApp(tester, playback);
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('soundq_desktop_seek')));
    slider.onChangeStart!(slider.value);
    slider.onChanged!(90000);
    playback.cueId = 'cue-2';
    playback.changed();
    await tester.pump();
    slider.onChangeEnd!(90000);
    await tester.pump();
    expect(playback.calls, isEmpty);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('soundq_desktop_seek')))
            .value,
        30000);
  });

  for (final reduce in [false, true]) {
    testWidgets(
        'track and transport transitions respect reduced motion=$reduce',
        (tester) async {
      final playback = DesktopPlayback();
      await pumpListeningApp(tester, playback, reduceMotion: reduce);
      final trackSwitch =
          find.byKey(const ValueKey('soundq_desktop_track_switch'));
      final playSwitch =
          find.byKey(const ValueKey('soundq_desktop_play_switch'));
      expect(trackSwitch, findsOneWidget);
      expect(tester.widget<AnimatedSwitcher>(trackSwitch).duration,
          reduce ? Duration.zero : const Duration(milliseconds: 180));
      expect(tester.widget<AnimatedSwitcher>(playSwitch).duration,
          reduce ? Duration.zero : const Duration(milliseconds: 140));
      playback.playing = false;
      playback.changed();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Resume'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('seek previews locally then dispatches one canonical seek',
      (tester) async {
    final playback = DesktopPlayback();
    await pumpListeningApp(tester, playback);
    final slider = tester
        .widget<Slider>(find.byKey(const ValueKey('soundq_desktop_seek')));
    slider.onChangeStart?.call(slider.value);
    slider.onChanged!(60000);
    slider.onChanged!(90000);
    await tester.pump();
    expect(playback.calls, isEmpty);
    expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('soundq_desktop_seek')))
            .value,
        90000);
    tester
        .widget<Slider>(find.byKey(const ValueKey('soundq_desktop_seek')))
        .onChangeEnd!(90000);
    await tester.pump();
    expect(playback.calls, ['seek:90000']);
    expect(playback.cursor, const Duration(seconds: 30));
  });

  for (final size in [
    const Size(1024, 768),
    const Size(1440, 900),
    const Size(1920, 1080),
    const Size(2560, 1440),
    const Size(1024, 600)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('desktop listening layout $size at ${scale}x',
          (tester) async {
        await pumpListeningApp(tester, DesktopPlayback(),
            size: size, textScale: scale);
        final transport =
            find.byKey(const ValueKey('soundq_desktop_transport'));
        expect(tester.getSize(transport).width, size.width);
        expect(tester.getTopLeft(transport).dx, 0);
        expect(tester.getBottomRight(transport).dy, size.height);
        for (final label in ['Pause', 'Next', 'Previous', 'Open queue']) {
          expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
      '80 position ticks only rebuild progress, not chrome or lazy content',
      (tester) async {
    final playback = DesktopPlayback();
    var rowsBuilt = 0;
    await pumpListeningApp(tester, playback,
        content: ListView.builder(
          itemCount: 10000,
          itemBuilder: (_, index) {
            rowsBuilt++;
            return SizedBox(height: 64, child: Text('row_$index'));
          },
        ));
    final initialRows = rowsBuilt;
    expect(initialRows, lessThan(40));
    final rebuilt = <String, int>{};
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      final key = element.widget.key?.toString() ?? '';
      if (key.contains('soundq_desktop_')) {
        rebuilt.update(key, (n) => n + 1, ifAbsent: () => 1);
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var i = 0; i < 80; i++) {
      playback.tick();
      await tester.pump();
    }
    debugOnRebuildDirtyWidget = null;
    debugPrint(
        'desktop-rebuild-receipt ticks=80 totalRows=10000 initialRows=$initialRows finalRows=$rowsBuilt keyedRebuilds=$rebuilt');
    expect(rowsBuilt, initialRows);
    expect(rebuilt[const ValueKey('soundq_desktop_seek').toString()], 80);
    expect(
        rebuilt[const ValueKey('soundq_desktop_track_title').toString()] ?? 0,
        0);
    expect(rebuilt[const ValueKey('soundq_desktop_shell').toString()] ?? 0, 0);
    expect(
        rebuilt[const ValueKey('soundq_desktop_navigation_rail').toString()] ??
            0,
        0);
    expect(
        rebuilt[const ValueKey('soundq_desktop_transport').toString()] ?? 0, 0);
    expect(
        rebuilt[const ValueKey('soundq_desktop_track_switch').toString()] ?? 0,
        0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop uses canonical transport with real guarded commands',
      (tester) async {
    final playback = DesktopPlayback();
    final router = await pumpListeningApp(tester, playback);
    expect(
        find.byKey(const ValueKey('soundq_desktop_transport')), findsOneWidget);
    expect(find.text(playback.item.title), findsOneWidget);
    for (final (label, call) in [
      ('Pause', 'toggle'),
      ('Next', 'next'),
      ('Previous', 'previous')
    ]) {
      await tester.tap(find.byTooltip(label));
      await tester.pump();
      expect(playback.calls.last, call);
    }
    await tester.tap(find.byTooltip('Open queue'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/queue');
    playback.allowNext = false;
    playback.changed();
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == 'Next'))
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip('Toggle shuffle'));
    await tester.tap(find.byTooltip('Cycle repeat mode'));
    await tester.pump();
    expect(playback.calls, containsAll(['shuffle', 'repeat']));
    await tester.tap(find.byTooltip('Open now playing'));
    await tester.pumpAndSettle();
    expect(find.text('page_player'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<GoRouter> pumpListeningApp(
  WidgetTester tester,
  DesktopPlayback playback, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  bool reduceMotion = false,
  Widget? content,
  Widget Function(Widget child)? shellBuilder,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final registry = CommandRegistry(playbackState: playback);
  addTearDown(registry.dispose);
  addTearDown(playback.disposeFake);
  final router = GoRouter(initialLocation: '/home', routes: [
    ShellRoute(
        builder: (_, __, child) =>
            shellBuilder?.call(child) ?? ScaffoldWithNavBar(child: child),
        routes: [
          for (final path in ['home', 'queue'])
            GoRoute(
                path: '/$path',
                builder: (_, __) => content ?? Text('page_$path')),
        ]),
    GoRoute(path: '/player', builder: (_, __) => const Text('page_player')),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(MultiProvider(
      providers: [
        ListenableProvider<PlaybackState>.value(value: playback),
        Provider<CommandRegistry>.value(value: registry),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: reduceMotion,
            ),
            child: child!),
      )));
  await tester.pumpAndSettle();
  return router;
}

class DesktopPlayback extends Fake implements PlaybackState {
  final notifier = ChangeNotifier();
  final calls = <String>[];
  Duration cursor = const Duration(seconds: 30);
  bool playing = true;
  bool pending = false;
  bool allowNext = true;
  ContinuationDisposition continuation = ContinuationDisposition.none;
  String cueId = 'cue-1';
  final String title;
  final String artist;
  DesktopPlayback({
    this.title =
        'A very long desktop listening track title that should stay bounded',
    this.artist = 'The artist with an equally long name',
  });
  late final item = MediaItem(
      id: '39',
      title: title,
      artist: artist,
      duration: const Duration(minutes: 4));
  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot(
        sessionId: 'session',
        cues: [
          PlaybackCue(
              cueId: cueId,
              queueItemId: 'occurrence-1',
              queueIndex: 0,
              trackId: item.id,
              mediaItem: item,
              audioUri: Uri.parse('file:///fixture.wav'),
              sourceDuration: duration,
              sourceStart: Duration.zero,
              sourceEnd: duration,
              timelineStart: Duration.zero)
        ],
        currentCueId: cueId,
        currentQueueIndex: 0,
        currentMediaItem: item,
        localPosition: cursor,
        localDuration: duration,
        globalPosition: cursor,
        globalDuration: duration,
        playing: playing,
        processingState: ProcessingState.ready,
        activeVoiceCount: 1,
        continuationDisposition: continuation,
      );
  @override
  MediaItem get currentItem => item;
  @override
  bool get hasTrack => true;
  @override
  bool get isPlaying => playing;
  @override
  bool get isResolvingSignedUrl => pending;
  @override
  Duration get position => cursor;
  @override
  Duration get duration => const Duration(minutes: 4);
  @override
  List<MediaItem> get queue => [item, item];
  @override
  int get currentIndex => 0;
  @override
  bool get canSkipNext => allowNext;
  @override
  bool get hasPreviousInPlayOrder => true;
  @override
  bool get shuffleEnabled => false;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  PlaybackContext? get playbackContext => null;
  @override
  Future<void> togglePlayPause() async {
    calls.add('toggle');
  }

  @override
  Future<void> play() async {
    calls.add('play');
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> skipToNext() async {
    calls.add('next');
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
  }

  @override
  Future<void> seek(Duration target) async {
    calls.add('seek:${target.inMilliseconds}');
  }

  @override
  Future<void> toggleShuffle() async {
    calls.add('shuffle');
  }

  @override
  Future<void> cycleLoopMode() async {
    calls.add('repeat');
  }

  @override
  void addListener(VoidCallback listener) => notifier.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      notifier.removeListener(listener);
  void tick() {
    cursor += const Duration(milliseconds: 250);
    notifier.notifyListeners();
  }

  void changed() => notifier.notifyListeners();
  void disposeFake() => notifier.dispose();
}
