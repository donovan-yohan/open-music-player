import 'dart:async';

import 'package:rxdart/rxdart.dart';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/core/audio/mix_audio_handler.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart' as app;

void main() {
  test('handler preserves source artwork and clears it on replacement',
      () async {
    final source = _SnapshotSource();
    final first = audio.MediaItem(
      id: 'a',
      title: 'A',
      artUri: Uri.parse('https://covers.example/a.png'),
      artHeaders: const {'X-Art-Variant': 'large'},
    );
    source.replace(first);
    final handler = MixAudioHandler(playbackState: source);
    addTearDown(() async {
      await handler.dispose();
      await source.changes.close();
    });
    expect(handler.mediaItem.value?.artUri, first.artUri);
    expect(handler.mediaItem.value?.artHeaders, first.artHeaders);

    // No headers migrate from A to an unrelated external artwork host.
    final second = audio.MediaItem(
      id: 'b',
      title: 'B',
      artUri: Uri.parse('https://external.example/b.png'),
    );
    source.replace(second);
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.id, 'b');
    expect(handler.mediaItem.value?.artUri, second.artUri);
    expect(handler.mediaItem.value?.artHeaders, isNull);

    // Same identity with authoritative missing art must clear, not merge.
    source.replace(const audio.MediaItem(id: 'b', title: 'B without art'));
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.artUri, isNull);
    expect(handler.mediaItem.value?.artHeaders, isNull);

    source.replace(first);
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.artUri, first.artUri);
    source.replace(null);
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.artUri, isNull);
    expect(handler.mediaItem.value?.artHeaders, isNull);
  });

  test('standard transport drawable names remain plugin defaults', () async {
    final source = _SnapshotSource();
    final handler = MixAudioHandler(playbackState: source);
    addTearDown(() async {
      await handler.dispose();
      await source.changes.close();
    });
    expect(handler.playbackState.value.controls.map((c) => c.androidIcon), [
      'drawable/audio_service_skip_previous',
      'drawable/audio_service_play_arrow',
      'drawable/audio_service_skip_next',
      'drawable/audio_service_stop',
    ]);
    expect(
        audio.MediaControl.pause.androidIcon, 'drawable/audio_service_pause');
  });
}

// Only the canonical snapshot/mode inputs consumed by the handler are faked.
class _SnapshotSource implements app.PlaybackState {
  final changes = BehaviorSubject<PlaybackSnapshot>();
  @override
  PlaybackSnapshot snapshot = PlaybackSnapshot.empty();
  @override
  ValueStream<PlaybackSnapshot> get snapshotStream => changes.stream;
  @override
  bool get shuffleEnabled => false;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  Stream<bool> get shuffleEnabledStream => const Stream.empty();
  @override
  Stream<LoopMode> get loopModeStream => const Stream.empty();

  void replace(audio.MediaItem? item) {
    snapshot = PlaybackSnapshot(
      sessionId: 'test',
      cues: const [],
      currentCueId: null,
      currentQueueIndex: null,
      currentMediaItem: item,
      localPosition: Duration.zero,
      localDuration: Duration.zero,
      globalPosition: Duration.zero,
      globalDuration: Duration.zero,
      playing: false,
      processingState: ProcessingState.ready,
      activeVoiceCount: item == null ? 0 : 1,
    );
    changes.add(snapshot);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
