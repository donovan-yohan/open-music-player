import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
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
}

class _FakePlaybackState extends Fake implements PlaybackState {
  final scrubEvents = <String>[];
  int seekCalls = 0;

  @override
  MediaItem? get currentItem => const MediaItem(
        id: '1',
        title: 'Test Track',
        artist: 'Test Artist',
        duration: Duration(seconds: 60),
      );

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
  PlaybackContext? get playbackContext => null;

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
