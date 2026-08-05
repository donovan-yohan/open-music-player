import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/stem_channel_source.dart';
import 'package:open_music_player/features/dj/widgets/dj_stem_panel.dart';
import 'package:open_music_player/features/stems/track_stem_channel_source.dart';

class _FakeStemsService implements StemsService {
  _FakeStemsService(this.response);

  TrackStems response;
  int requestCalls = 0;

  @override
  Future<TrackStems> getTrackStems(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) async =>
      response;

  @override
  Future<StemsRequestResult> requestSeparation(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) async {
    requestCalls++;
    response = TrackStems(
      trackId: trackId,
      channelSet: channelSet,
      status: StemsStatus.pending,
      queuePosition: 1,
    );
    return StemsRequestResult(
      trackId: trackId,
      channelSet: channelSet,
      status: StemsStatus.pending,
      queued: true,
      queuePosition: 1,
    );
  }
}

TrackStems _ready(int trackId) => TrackStems(
      trackId: trackId,
      channelSet: defaultStemChannelSet,
      status: StemsStatus.ready,
      channels: const ['vocals', 'melody', 'bass', 'kick', 'perc'],
    );

Future<void> _pumpPanel(WidgetTester tester, StemChannelSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 220,
          width: 400,
          child: DjStemPanel(source: source),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an unseparated track offers the opt-in instead of hiding',
      (tester) async {
    final source = TrackStemChannelSource(
      service: _FakeStemsService(TrackStems.unavailable(42)),
    );
    await source.bindTrack(42);

    await _pumpPanel(tester, source);

    expect(find.byKey(const ValueKey('dj_stem_unavailable')), findsOneWidget);
    expect(find.text('Separate stems'), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_stem_mixer')), findsNothing);
  });

  testWidgets('tapping Separate stems triggers the opt-in and shows progress',
      (tester) async {
    final service = _FakeStemsService(TrackStems.unavailable(42));
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);
    await _pumpPanel(tester, source);

    await tester.tap(find.byKey(const ValueKey('dj_stem_separate')));
    // Not pumpAndSettle: the in-flight state runs a CircularProgressIndicator,
    // which never settles.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(service.requestCalls, 1);
    expect(find.byKey(const ValueKey('dj_stem_separating')), findsOneWidget);
    expect(find.text('Separating… #1 in queue'), findsOneWidget);
  });

  testWidgets('a pending track can be re-checked without re-queueing',
      (tester) async {
    final service = _FakeStemsService(
      const TrackStems(
        trackId: 42,
        channelSet: defaultStemChannelSet,
        status: StemsStatus.pending,
      ),
    );
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);
    await _pumpPanel(tester, source);

    expect(find.text('Separating…'), findsOneWidget);
    service.response = _ready(42);

    await tester.tap(find.byKey(const ValueKey('dj_stem_refresh')));
    await tester.pumpAndSettle();

    expect(service.requestCalls, 0);
    expect(find.byKey(const ValueKey('dj_stem_mixer')), findsOneWidget);
  });

  testWidgets('a ready track renders one strip per manifest channel',
      (tester) async {
    final source =
        TrackStemChannelSource(service: _FakeStemsService(_ready(42)));
    await source.bindTrack(42);

    await _pumpPanel(tester, source);

    for (final id in ['vocals', 'melody', 'bass', 'kick', 'perc']) {
      expect(find.byKey(ValueKey('dj_stem_strip_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('dj_stem_gain_$id')), findsOneWidget);
      expect(find.byKey(ValueKey('dj_stem_mute_$id')), findsOneWidget);
    }
    expect(find.text('Kick (low drums)'), findsOneWidget);
  });

  testWidgets('the live mixer always states the Rung B audibility gap',
      (tester) async {
    final source =
        TrackStemChannelSource(service: _FakeStemsService(_ready(42)));
    await source.bindTrack(42);

    await _pumpPanel(tester, source);

    expect(
      find.byKey(const ValueKey('dj_stem_not_audible_hint')),
      findsOneWidget,
    );
    expect(find.text(stemPreviewNotAudibleCopy), findsOneWidget);
  });

  testWidgets('muting a stem updates the shared source state', (tester) async {
    final source =
        TrackStemChannelSource(service: _FakeStemsService(_ready(42)));
    await source.bindTrack(42);
    await _pumpPanel(tester, source);

    await tester.tap(find.byKey(const ValueKey('dj_stem_mute_kick')));
    await tester.pump();

    expect(source.channels.firstWhere((c) => c.id == 'kick').muted, isTrue);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('dj_stem_gain_kick')),
    );
    expect(slider.onChanged, isNull, reason: 'a muted stem has no live fader');
  });

  testWidgets('a failed separation offers a retry with the backend reason',
      (tester) async {
    final source = TrackStemChannelSource(
      service: _FakeStemsService(
        const TrackStems(
          trackId: 42,
          channelSet: defaultStemChannelSet,
          status: StemsStatus.failed,
          error: 'separator exited 1',
        ),
      ),
    );
    await source.bindTrack(42);

    await _pumpPanel(tester, source);

    expect(find.text('Separation failed'), findsOneWidget);
    expect(find.text('separator exited 1'), findsOneWidget);
    expect(find.text('Retry separation'), findsOneWidget);
  });

  testWidgets('a deck with no library track says so instead of offering a POST',
      (tester) async {
    final source =
        TrackStemChannelSource(service: _FakeStemsService(_ready(42)));

    await _pumpPanel(tester, source);

    expect(find.byKey(const ValueKey('dj_stem_no_track')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_stem_separate')), findsNothing);
  });

  testWidgets('a non-backend source degrades without a separation action',
      (tester) async {
    await _pumpPanel(tester, const UnavailableStemChannelSource());

    expect(find.byKey(const ValueKey('dj_stem_unsupported')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_stem_separate')), findsNothing);
  });
}
