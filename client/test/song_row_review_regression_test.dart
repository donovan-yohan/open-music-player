import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:rxdart/rxdart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:provider/provider.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_models.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:open_music_player/shared/widgets/now_playing_row.dart';

import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

class _Playback extends FakePlayback {
  final added = <int>[];
  @override
  int? playbackQueueTailTrackId() => null;
  final _snapshots = BehaviorSubject<PlaybackSnapshot>();
  @override
  ValueStream<PlaybackSnapshot> get snapshotStream => _snapshots.stream;
  @override
  void set(PlaybackSnapshot next) {
    _snapshots.add(next);
    super.set(next);
  }

  @override
  void dispose() {
    _snapshots.close();
    super.dispose();
  }

  @override
  List<MediaItem> get queue => const [MediaItem(id: 'seed', title: 'Seed')];
  @override
  Future<void> enqueue(Map<String, dynamic> track) async {
    added.add(track['id'] as int);
  }
}

class _Home implements HomeService {
  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async => [
        for (final id in [1, 2])
          Track.fromJson({'id': id, 'title': 'Song $id', 'artist': 'Artist'})
      ];
  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async => [];
  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Dj implements DjSessionDataSource {
  @override
  Future<DjLineup> fetchLineup(DjLineupRequest request) async =>
      DjLineup.fromJson({
        'blocks': [
          {
            'id': 'on-repeat',
            'title': 'On Repeat',
            'reason': 'Test',
            'tracks': [
              for (final id in [1, 2])
                {
                  'id': id,
                  'title': 'Song $id',
                  'artist': 'Artist',
                  'durationMs': 180000
                }
            ]
          }
        ]
      });
  @override
  Future<DjPin> pinBlock(String blockId) async => DjPin.fromJson(const {});
  @override
  Future<void> unpinBlock() async {}
}

Future<void> _pump(
    WidgetTester tester, _Playback playback, Widget screen) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1100);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(playback.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<PlaybackState>.value(
    value: playback,
    child: MaterialApp(theme: AppTheme.darkTheme, home: screen),
  ));
  await tester.pumpAndSettle();
}

Finder _action(int id) => find.descendant(
      of: find.byKey(ValueKey('dj_track_$id')),
      matching: find.byType(IconButton),
    );

FocusNode _actionFocus(WidgetTester tester, int id) {
  final context = tester.element(find.descendant(
      of: _action(id), matching: find.byIcon(Icons.playlist_add)));
  return Focus.of(context);
}

TextStyle _renderedStyle(WidgetTester tester, String title) => tester
    .widget<RichText>(
        find.descendant(of: find.text(title), matching: find.byType(RichText)))
    .text
    .style!;

void main() {
  for (final id in [1, 2]) {
    testWidgets(
        'DJ action $id retains focus identity and keyboard activation across every row state',
        (tester) async {
      final playback = _Playback()..set(makeSnapshot(id: '1'));
      await _pump(tester, playback, DjSessionScreen(service: _Dj()));
      final node = _actionFocus(tester, id);
      final element = tester.element(_action(id));
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
      for (final next in [
        makeSnapshot(id: '2'),
        makeSnapshot(id: '2', playing: false),
        makeSnapshot(id: '2', state: ProcessingState.loading),
        makeSnapshot(id: null),
        makeSnapshot(id: '1'),
      ]) {
        playback.set(next);
        await tester.pump();
        expect(tester.element(_action(id)), same(element));
        expect(_actionFocus(tester, id), same(node));
        expect(node.hasFocus, isTrue);
        final before = playback.added.length;
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(playback.added.length, before + 1);
        expect(playback.added.last, id);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    testWidgets(
        'DJ action $id completes held pointer across snapshot switch and clear',
        (tester) async {
      final playback = _Playback()..set(makeSnapshot(id: '1'));
      await _pump(tester, playback, DjSessionScreen(service: _Dj()));
      for (final next in [makeSnapshot(id: '2'), makeSnapshot(id: null)]) {
        final before = playback.added.length;
        final gesture =
            await tester.startGesture(tester.getCenter(_action(id)));
        await tester.pump(const Duration(milliseconds: 100));
        playback.set(next);
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(playback.added.length, before + 1);
        expect(playback.added.last, id);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final home in [true, false]) {
    testWidgets(
        '${home ? 'Desktop Home' : 'DJ'} actual titles follow orange selection and restore typography',
        (tester) async {
      final playback = _Playback()..set(makeSnapshot(id: null));
      await _pump(
          tester,
          playback,
          home
              ? HomeScreen(homeService: _Home())
              : DjSessionScreen(service: _Dj()));
      if (home) expect(find.text('Your rotation'), findsOneWidget);
      final normal = {
        for (final id in [1, 2]) id: _renderedStyle(tester, 'Song $id')
      };
      final orange = AppTheme.darkTheme.colorScheme.primary;
      for (final selected in ['1', '2', null]) {
        playback.set(makeSnapshot(id: selected));
        await tester.pump();
        for (final id in [1, 2]) {
          final style = _renderedStyle(tester, 'Song $id');
          expect(style.color, selected == '$id' ? orange : normal[id]!.color);
          expect(style.fontWeight,
              selected == '$id' ? FontWeight.w700 : normal[id]!.fontWeight);
          expect(style.fontSize, normal[id]!.fontSize);
          expect(style.letterSpacing, normal[id]!.letterSpacing);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('inactive treatment preserves ambient text and ListTile styling',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: DefaultTextStyle(
      style: TextStyle(color: Colors.green, fontSize: 23),
      child: Column(children: [
        Text('plain'),
        SongRowTreatment(
            presentation: SongRowPresentation.none, child: Text('wrapped')),
        ListTile(title: Text('tile plain')),
        SongRowTreatment(
            presentation: SongRowPresentation.none,
            child: ListTile(title: Text('tile wrapped'))),
      ]),
    ))));
    expect(_renderedStyle(tester, 'wrapped'), _renderedStyle(tester, 'plain'));
    expect(_renderedStyle(tester, 'tile wrapped'),
        _renderedStyle(tester, 'tile plain'));
  });
}
