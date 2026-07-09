import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/features/player/player_screen.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('progress slider previews scrub and commits once',
      (tester) async {
    final playback = _FakePlaybackState();
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart?.call(0.1);
    slider.onChanged?.call(0.4);
    slider.onChanged?.call(0.6);
    slider.onChangeEnd?.call(0.6);
    await tester.pump();

    expect(playback.seekCalls, 0);
    expect(playback.scrubEvents, [
      'begin',
      'update:24000',
      'update:36000',
      'end:36000',
    ]);
  });

  testWidgets('queue time mode displays context and scrubs global timeline',
      (tester) async {
    final playback = _FakePlaybackState(
      playbackContext: const PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'Road Mix',
      ),
      queue: const [
        _FakePlaybackState.testItem,
        MediaItem(id: '2', title: 'Next Track', duration: Duration(minutes: 2)),
      ],
      snapshot: const PlaybackSnapshot(
        sessionId: 'session_test',
        cues: [],
        currentCueId: 'cue_1',
        currentQueueIndex: 0,
        currentMediaItem: _FakePlaybackState.testItem,
        localPosition: Duration(seconds: 10),
        localDuration: Duration(minutes: 1),
        globalPosition: Duration(seconds: 30),
        globalDuration: Duration(minutes: 3),
        playing: false,
        processingState: ProcessingState.ready,
        activeVoiceCount: 1,
      ),
    );
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('Road Mix'), findsWidgets);
    expect(find.text('Playlist · 2 tracks'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart?.call(0.1);
    slider.onChanged?.call(0.5);
    slider.onChangeEnd?.call(0.5);
    await tester.pump();

    expect(playback.scrubEvents, [
      'timeline-begin',
      'timeline-update:90000',
      'timeline-end:90000',
    ]);
  });

  testWidgets('shows pitch lock fallback warning when snapshot reports it',
      (tester) async {
    final playback = _FakePlaybackState(
      snapshot: const PlaybackSnapshot(
        sessionId: 'session_test',
        cues: [],
        currentCueId: 'cue_1',
        currentQueueIndex: 0,
        currentMediaItem: _FakePlaybackState.testItem,
        localPosition: Duration(seconds: 10),
        localDuration: Duration(seconds: 60),
        globalPosition: Duration(seconds: 10),
        globalDuration: Duration(seconds: 60),
        playing: false,
        processingState: ProcessingState.ready,
        activeVoiceCount: 1,
        playbackSpeed: 1.25,
        pitchPreservationFallback: true,
      ),
    );
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    expect(
      find.text('Pitch lock unavailable. Tempo match may alter pitch.'),
      findsOneWidget,
    );
  });
}

class _FakePlaybackState extends Fake implements PlaybackState {
  _FakePlaybackState({
    PlaybackContext? playbackContext,
    List<MediaItem>? queue,
    PlaybackSnapshot? snapshot,
  })  : _playbackContext = playbackContext,
        _queue = queue ?? const [testItem],
        _snapshot = snapshot ??
            const PlaybackSnapshot(
              sessionId: 'session_test',
              cues: [],
              currentCueId: 'cue_1',
              currentQueueIndex: 0,
              currentMediaItem: testItem,
              localPosition: Duration(seconds: 10),
              localDuration: Duration(seconds: 60),
              globalPosition: Duration(seconds: 10),
              globalDuration: Duration(seconds: 60),
              playing: false,
              processingState: ProcessingState.ready,
              activeVoiceCount: 1,
            );

  static const testItem = MediaItem(
    id: '1',
    title: 'Test Track',
    artist: 'Test Artist',
    duration: Duration(seconds: 60),
  );

  final scrubEvents = <String>[];
  final PlaybackContext? _playbackContext;
  final List<MediaItem> _queue;
  final PlaybackSnapshot _snapshot;
  int seekCalls = 0;

  @override
  MediaItem? get currentItem => testItem;

  @override
  List<MediaItem> get queue => _queue;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Duration get position => const Duration(seconds: 10);

  @override
  Duration get duration => const Duration(seconds: 60);

  @override
  bool get isPlaying => false;

  @override
  bool get shuffleEnabled => false;

  @override
  LoopMode get loopMode => LoopMode.off;

  @override
  PlaybackContext? get playbackContext => _playbackContext;

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
  }

  @override
  void beginLocalScrub() => scrubEvents.add('begin');

  @override
  void updateLocalScrub(Duration position) {
    scrubEvents.add('update:${position.inMilliseconds}');
  }

  @override
  Future<void> endLocalScrub(Duration position) async {
    scrubEvents.add('end:${position.inMilliseconds}');
  }

  @override
  void beginTimelineScrub() => scrubEvents.add('timeline-begin');

  @override
  void updateTimelineScrub(int globalMs) {
    scrubEvents.add('timeline-update:$globalMs');
  }

  @override
  Future<void> endTimelineScrub(int globalMs) async {
    scrubEvents.add('timeline-end:$globalMs');
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> toggleShuffle() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> cycleLoopMode() async {}
}
