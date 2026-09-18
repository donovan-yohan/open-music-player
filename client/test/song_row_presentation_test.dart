import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:provider/provider.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/shared/widgets/now_playing_row.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

PlaybackSnapshot makeSnapshot(
    {String? id = 'A',
    int index = 0,
    bool playing = true,
    ProcessingState state = ProcessingState.ready,
    bool stale = false,
    int position = 0,
    int? activeVoices,
    bool reversedCues = false}) {
  final item = MediaItem(id: id ?? 'A', title: 'Same title');
  final cues = List.generate(
      2,
      (i) => PlaybackCue(
            cueId: 'cue_$i',
            queueItemId: 'occurrence_$i',
            queueIndex: i,
            trackId: item.id,
            mediaItem: item,
            audioUri: Uri.parse('file:///track.wav'),
            sourceDuration: const Duration(seconds: 90),
            sourceStart: Duration.zero,
            sourceEnd: const Duration(seconds: 90),
            timelineStart: Duration.zero,
          ));
  return PlaybackSnapshot(
    sessionId: 'test',
    cues: reversedCues ? cues.reversed.toList() : cues,
    currentCueId: stale ? 'stale' : 'cue_$index',
    currentQueueIndex: index,
    currentMediaItem: id == null ? null : item,
    localPosition: Duration(seconds: position),
    localDuration: Duration.zero,
    globalPosition: Duration.zero,
    globalDuration: Duration.zero,
    playing: playing,
    processingState: state,
    activeVoiceCount: activeVoices ?? (playing ? 1 : 0),
  );
}

class FakePlayback extends ChangeNotifier implements PlaybackState {
  PlaybackSnapshot value = makeSnapshot();
  @override
  PlaybackSnapshot get snapshot => value;
  void set(PlaybackSnapshot next) {
    value = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('canonical IDs, never title equality; A to B and no current item', () {
    expect(songRowPresentationFor(makeSnapshot(), trackId: 'A'),
        SongRowPresentation.playing);
    expect(songRowPresentationFor(makeSnapshot(), trackId: 'B'),
        SongRowPresentation.none);
    expect(songRowPresentationFor(makeSnapshot(id: 'B'), trackId: 'A'),
        SongRowPresentation.none);
    expect(songRowPresentationFor(makeSnapshot(id: 'B'), trackId: 'B'),
        SongRowPresentation.playing);
    expect(songRowPresentationFor(makeSnapshot(id: null), trackId: 'A'),
        SongRowPresentation.none);
    expect(songRowPresentationFor(makeSnapshot(), trackId: null),
        SongRowPresentation.none);
    expect(
        songRowPresentationFor(makeSnapshot(id: 'local:/music/a'),
            trackId: 'local:/music/a'),
        SongRowPresentation.playing);
  });
  test('pause/resume and loading/stopped/stale cannot claim playing', () {
    expect(songRowPresentationFor(makeSnapshot(playing: false), trackId: 'A'),
        SongRowPresentation.paused);
    for (final state in [
      ProcessingState.idle,
      ProcessingState.loading,
      ProcessingState.buffering,
      ProcessingState.completed
    ]) {
      expect(songRowPresentationFor(makeSnapshot(state: state), trackId: 'A'),
          SongRowPresentation.selected);
    }
    expect(songRowPresentationFor(makeSnapshot(stale: true), trackId: 'A'),
        SongRowPresentation.selected);
    expect(
        songRowPresentationFor(makeSnapshot(state: ProcessingState.loading),
            trackId: 'B'),
        SongRowPresentation.none);
  });
  test('unavailable voices and shuffled cues do not invent playback', () {
    expect(songRowPresentationFor(makeSnapshot(activeVoices: 0), trackId: 'A'),
        SongRowPresentation.selected);
    expect(
        songRowPresentationFor(makeSnapshot(index: 1, reversedCues: true),
            trackId: 'A', queueItemId: 'occurrence_1'),
        SongRowPresentation.playing);
  });
  test('duplicate queue occurrences only select the coherent active cue', () {
    for (var index = 0; index < 2; index++) {
      for (var row = 0; row < 2; row++) {
        expect(
            songRowPresentationFor(makeSnapshot(index: index),
                trackId: 'A', queueItemId: 'occurrence_$row'),
            index == row
                ? SongRowPresentation.playing
                : SongRowPresentation.none);
      }
    }
    expect(
        songRowPresentationFor(makeSnapshot(stale: true),
            trackId: 'A', queueItemId: 'occurrence_0'),
        SongRowPresentation.none);
  });
  testWidgets(
      'shared custom/TrackTile rows transition together without tick rebuilds',
      (tester) async {
    final playback = FakePlayback();
    addTearDown(playback.dispose);
    await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(
            home: Scaffold(
                body: Column(children: [
          NowPlayingRow(trackId: 'A', child: ListTile(title: Text('Home A'))),
          TrackTile(trackId: 'A', title: 'Playlist A', duration: '1:30'),
          TrackTile(trackId: 'B', title: 'Same title', duration: '1:30'),
        ])))));
    expect(find.byKey(const ValueKey('song_row_current')), findsNWidgets(2));
    final before = tester
        .widgetList<SongRowTreatment>(find.byType(SongRowTreatment))
        .toList();
    playback.set(makeSnapshot(position: 12));
    await tester.pump();
    final after = tester
        .widgetList<SongRowTreatment>(find.byType(SongRowTreatment))
        .toList();
    for (var i = 0; i < before.length; i++) {
      expect(identical(before[i], after[i]), isTrue);
    }
    playback.set(makeSnapshot(playing: false));
    await tester.pump();
    expect(
        tester
            .widgetList<SongRowTreatment>(find.byType(SongRowTreatment))
            .where((w) => w.presentation == SongRowPresentation.paused)
            .length,
        2);
    playback.set(makeSnapshot());
    await tester.pump();
    playback.set(makeSnapshot(id: 'B'));
    await tester.pump();
    expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
    final decoration = tester
        .widget<Ink>(find.byKey(const ValueKey('song_row_current')))
        .decoration as BoxDecoration;
    final theme = Theme.of(tester.element(find.text('Same title')));
    expect(decoration.color,
        theme.colorScheme.primaryContainer.withValues(alpha: 0.28));
    playback.set(makeSnapshot(id: null));
    await tester.pump();
    expect(find.byKey(const ValueKey('song_row_current')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('queue occurrences keep gestures and only one selected row',
      (tester) async {
    final playback = FakePlayback();
    addTearDown(playback.dispose);
    var taps = 0;
    await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
      value: playback,
      child: MaterialApp(
          home: Scaffold(
              body: Column(children: [
        for (var i = 0; i < 2; i++)
          TrackTile(
              key: ValueKey('occurrence_$i'),
              trackId: 'A',
              queueItemId: 'occurrence_$i',
              title: 'Same title',
              duration: '1:30',
              onTap: () => taps++),
      ]))),
    ));
    for (var i = 0; i < 2; i++) {
      playback.set(makeSnapshot(index: i, playing: false));
      await tester.pump();
      expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(ValueKey('occurrence_$i')),
              matching: find.byKey(const ValueKey('song_row_current'))),
          findsOneWidget);
      expect(
          find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label == 'Paused here'),
          findsOneWidget);
      expect(find.byIcon(Icons.equalizer), findsNothing);
    }
    await tester.tap(find.text('Same title').first);
    expect(taps, 1);
    playback.set(makeSnapshot(id: null));
    await tester.pump();
    expect(find.byKey(const ValueKey('song_row_current')), findsNothing);
  });
}
