import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:audio_service/audio_service.dart' as audio;
import 'package:rxdart/rxdart.dart';
import 'package:open_music_player/core/audio/mix_audio_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/player_presentation.dart';
import 'package:open_music_player/features/player/player_screen.dart';
import 'package:open_music_player/features/player/widgets/mini_player.dart';

const item = MediaItem(
    id: 'local', title: 'Previous track', duration: Duration(seconds: 60));
PlaybackSnapshot snap(ContinuationDisposition disposition,
        {bool playing = false,
        int position = 60,
        ProcessingState state = ProcessingState.ready}) =>
    PlaybackSnapshot(
        sessionId: 'test',
        cues: [
          PlaybackCue(
              cueId: 'c',
              queueItemId: 'q',
              queueIndex: 0,
              trackId: item.id,
              mediaItem: item,
              audioUri: Uri.parse('file:///a.wav'),
              sourceDuration: item.duration!,
              sourceStart: Duration.zero,
              sourceEnd: item.duration!,
              timelineStart: Duration.zero)
        ],
        currentCueId: 'c',
        currentQueueIndex: 0,
        currentMediaItem: item,
        localPosition: Duration(seconds: position),
        localDuration: item.duration!,
        globalPosition: Duration(seconds: position),
        globalDuration: item.duration!,
        playing: playing,
        processingState: state,
        activeVoiceCount: playing ? 1 : 0,
        continuationDisposition: disposition);

void main() {
  test('handler exports completed only for canonical ended', () async {
    final playback = TerminalPlayback();
    final handler = MixAudioHandler(playbackState: playback);
    addTearDown(() async {
      await handler.dispose();
      playback.dispose();
    });
    for (final disposition in ContinuationDisposition.values) {
      for (final playing in [false, true]) {
        playback.set(snap(disposition,
            playing: playing, state: ProcessingState.completed));
        await pumpEventQueue();
        expect(
            handler.playbackState.value.processingState,
            switch (disposition) {
              ContinuationDisposition.waiting =>
                audio.AudioProcessingState.loading,
              ContinuationDisposition.completed =>
                audio.AudioProcessingState.completed,
              ContinuationDisposition.none => audio.AudioProcessingState.ready,
            });
        expect(handler.playbackState.value.playing, playing);
      }
    }
  });
  test('canonical end, not clip processing or paused end cursor', () {
    expect(PlayerPresentation.fromSnapshot(PlaybackSnapshot.empty()),
        PlayerPresentation.empty);
    expect(
        PlayerPresentation.fromSnapshot(
            snap(ContinuationDisposition.none, state: ProcessingState.idle)),
        PlayerPresentation.idle);
    expect(
        PlayerPresentation.fromSnapshot(snap(ContinuationDisposition.none,
            state: ProcessingState.completed)),
        PlayerPresentation.paused);
    expect(
        PlayerPresentation.fromSnapshot(
            snap(ContinuationDisposition.completed)),
        PlayerPresentation.ended);
  });
  for (final full in [false, true]) {
    for (final width in [390.0, 1200.0]) {
      testWidgets('terminal surfaces full=$full width=$width at 3x',
          (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final playback = TerminalPlayback();
        addTearDown(playback.dispose);
        await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
            value: playback,
            child: MaterialApp(
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: const TextScaler.linear(3)),
                    child: child!),
                home: full
                    ? const PlayerScreen()
                    : const Scaffold(body: MiniPlayer()))));
        void expectAttribution() {
          expect(find.text(full ? 'FROM' : 'From Discovery'), findsOneWidget);
          if (full) expect(find.text('Discovery'), findsOneWidget);
          expect(find.textContaining('Playing from'), findsNothing);
          expect(find.text('PLAYING FROM'), findsNothing);
        }

        final semantics = tester.ensureSemantics();
        expectAttribution();
        expect(find.text('Finding more music…'), findsWidgets);
        expect(find.text('Previous track'), findsNothing);
        final liveStatus = find.byWidgetPredicate((widget) =>
            widget is Semantics && widget.properties.liveRegion == true);
        expect(liveStatus, findsWidgets);
        final cancel = full
            ? find.widgetWithText(TextButton, 'Cancel')
            : find.byTooltip('Cancel');
        expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
        await tester.tap(cancel);
        await tester.pump();
        expect(playback.pauses, 1);
        expectAttribution();
        expect(find.byTooltip('Resume'), findsOneWidget);
        expect(tester.takeException(), isNull);
        playback.set(snap(ContinuationDisposition.completed));
        await tester.pump();
        expect(find.text('Queue ended'), findsOneWidget);
        expectAttribution();
        expect(find.text('PLAYING FROM'), findsNothing);
        expect(find.byTooltip('Replay'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Replay'));
        await tester.tap(find.byTooltip('Replay'));
        await tester.pump();
        expect(playback.plays, 1);
        playback.set(snap(ContinuationDisposition.none));
        await tester.pump();
        expect(find.byTooltip('Resume'), findsOneWidget);
        expectAttribution();
        playback.set(snap(ContinuationDisposition.waiting));
        playback.failPause = true;
        await tester.pump();
        await tester.tap(cancel);
        await tester.pump();
        expect(find.text('Could not pause playback. Please try again.'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }
  }
  testWidgets('mini chrome ignores position-only snapshots', (tester) async {
    final playback = TerminalPlayback()
      ..set(snap(ContinuationDisposition.none, playing: true, position: 1));
    addTearDown(playback.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: Scaffold(body: MiniPlayer()))));
    final before = tester.widget(find.text('Previous track'));
    playback
        .set(snap(ContinuationDisposition.none, playing: true, position: 2));
    await tester.pump();
    expect(
        identical(before, tester.widget(find.text('Previous track'))), isTrue);
  });
}

class TerminalPlayback extends ChangeNotifier implements PlaybackState {
  PlaybackSnapshot value = snap(ContinuationDisposition.waiting);
  int pauses = 0, plays = 0;
  bool failPause = false;
  final changes = BehaviorSubject<PlaybackSnapshot>();
  @override
  ValueStream<PlaybackSnapshot> get snapshotStream => changes.stream;
  @override
  Stream<bool> get shuffleEnabledStream => const Stream.empty();
  @override
  Stream<LoopMode> get loopModeStream => const Stream.empty();
  @override
  bool get canSkipPrevious => false;
  @override
  bool get canSkipNext => false;
  @override
  void dispose() {
    changes.close();
    super.dispose();
  }

  void set(PlaybackSnapshot next) {
    value = next;
    changes.add(next);
    notifyListeners();
  }

  @override
  PlaybackSnapshot get snapshot => value;
  @override
  MediaItem? get currentItem => value.currentMediaItem;
  @override
  bool get hasTrack => true;
  @override
  bool get isPlaying => value.playing;
  @override
  bool get isResolvingSignedUrl => false;
  @override
  PlaybackContext? get playbackContext => const PlaybackContext(
      kind: PlaybackContextKind.playlist, label: 'Discovery');
  @override
  Duration get position => value.localPosition;
  @override
  Duration get duration => value.localDuration;
  @override
  List<MediaItem> get queue => [item];
  @override
  bool get shuffleEnabled => false;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
    if (failPause) throw StateError('pause failed');
    set(snap(ContinuationDisposition.none, state: ProcessingState.completed));
  }

  @override
  Future<void> togglePlayPause() => isPlaying ? pause() : play();
  @override
  Future<void> toggleShuffle() async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> skipToNext() async {}
  @override
  Future<void> cycleLoopMode() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
