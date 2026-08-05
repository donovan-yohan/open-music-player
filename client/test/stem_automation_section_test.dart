import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/stem_channel_source.dart';
import 'package:open_music_player/features/stems/track_stem_channel_source.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:open_music_player/widgets/stem_automation_section.dart';

MixPlanClip _clip() => MixPlanClip(
      clipId: 'clip-a',
      queueItemId: 'queue-a',
      trackId: '42',
      sourceStartMs: 0,
      sourceEndMs: 60000,
      timelineStartMs: 12000,
    );

StemEdits _edits({List<StemGainEvent> events = const <StemGainEvent>[]}) =>
    StemEdits(
      channelSet: StemChannelSet.stems5Hybrid,
      sourceFileHash: 'sha256:deadbeef',
      events: events,
    );

/// Pumps the section and keeps the latest document the section handed back.
Future<StemEdits Function()> _pump(
  WidgetTester tester, {
  required StemEdits edits,
  int? playheadSourceMs,
  List<int> beatGridMs = const <int>[],
  StemChannelSource? stemSource,
}) async {
  var current = edits;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => SingleChildScrollView(
            child: StemAutomationSection(
              clip: _clip(),
              edits: current,
              playheadSourceMs: playheadSourceMs,
              beatGridMs: beatGridMs,
              stemSource: stemSource,
              onEditsChanged: (next) => setState(() => current = next),
            ),
          ),
        ),
      ),
    ),
  );
  return () => current;
}

/// Minimal [StemsService] returning one canned row, so the section can be
/// driven by the same live source the DJ deck uses.
class _FakeStemsService implements StemsService {
  _FakeStemsService(this.response);

  final TrackStems response;

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
  }) async =>
      throw UnimplementedError();
}

Future<TrackStemChannelSource> _boundSource(TrackStems response) async {
  final source = TrackStemChannelSource(service: _FakeStemsService(response));
  await source.bindTrack(42);
  return source;
}

void main() {
  testWidgets('section lists one row per channel of the active set', (
    tester,
  ) async {
    await _pump(tester, edits: _edits());

    for (final id in ['vocals', 'melody', 'bass', 'kick', 'perc']) {
      expect(find.byKey(ValueKey('stem_channel_row_$id')), findsOneWidget);
    }
    expect(find.text('No change points'), findsNWidgets(5));
  });

  testWidgets('honesty copy is present for cuts and for lossy channels', (
    tester,
  ) async {
    await _pump(tester, edits: _edits());

    expect(find.text('Kick (low drums)'), findsOneWidget);
    expect(find.text('Hats & Percussion'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stem_automation_honesty_copy')),
      findsOneWidget,
    );
    expect(find.textContaining('mostly removed'), findsOneWidget);
    expect(find.textContaining('isolated'), findsOneWidget,
        reason: 'the only "isolated" copy is the "not isolated" disclaimer');
    expect(find.textContaining('Hats'), findsOneWidget);
  });

  testWidgets('existing change points render as chips per channel', (
    tester,
  ) async {
    await _pump(
      tester,
      edits: _edits(
        events: [
          StemGainEvent(channel: 'vocals', atMs: 12000, gain: 0),
          StemGainEvent(channel: 'vocals', atMs: 20000, gain: 1),
          StemGainEvent(channel: 'kick', atMs: 4500, gain: 0.5),
        ],
      ),
    );

    expect(find.text('12.0s -> 0%'), findsOneWidget);
    expect(find.text('20.0s -> 100%'), findsOneWidget);
    expect(find.text('4.5s -> 50%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stem_change_point_vocals_12000')),
      findsOneWidget,
    );
    expect(find.text('No change points'), findsNWidgets(3),
        reason: 'melody, bass and perc still have none');
  });

  testWidgets('the add dialog writes a well-formed change point', (
    tester,
  ) async {
    final read = await _pump(tester, edits: _edits(), playheadSourceMs: 12000);

    await tester.tap(
      find.byKey(const ValueKey('stem_add_change_point_vocals')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stem_change_point_dialog')),
        findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('stem_change_point_time_field')),
          )
          .controller!
          .text,
      '12000',
      reason: 'the time field prefills from the playhead',
    );

    await tester.tap(find.byKey(const ValueKey('stem_change_point_cut')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stem_change_point_save')));
    await tester.pumpAndSettle();

    final written = read().events.single;
    expect(written.channel, 'vocals');
    expect(written.atMs, 12000);
    expect(written.gain, 0.0);
    expect(written.rampMs, stemRampDefaultMs);
    expect(written.beatIndex, isNull);
    expect(find.text('12.0s -> 0%'), findsOneWidget);
  });

  testWidgets('the cut and full buttons drive the gain control', (
    tester,
  ) async {
    final read = await _pump(tester, edits: _edits(), playheadSourceMs: 8000);

    await tester.tap(find.byKey(const ValueKey('stem_add_change_point_bass')));
    await tester.pumpAndSettle();

    expect(find.text(stemCutActionLabel), findsOneWidget);
    expect(find.text(stemFullActionLabel), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stem_change_point_full')));
    await tester.pumpAndSettle();
    expect(find.text('Gain 100%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stem_change_point_cut')));
    await tester.pumpAndSettle();
    expect(find.text('Gain 0%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stem_change_point_save')));
    await tester.pumpAndSettle();

    expect(read().gainAt('bass', 8000), 0.0);
  });

  testWidgets('editing a chip retimes exactly that change point', (
    tester,
  ) async {
    final read = await _pump(
      tester,
      edits: _edits(
        events: [
          StemGainEvent(channel: 'vocals', atMs: 12000, gain: 0),
          StemGainEvent(channel: 'vocals', atMs: 20000, gain: 1),
        ],
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('stem_change_point_vocals_12000')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('stem_change_point_time_field')),
      '15000',
    );
    await tester.tap(find.byKey(const ValueKey('stem_change_point_save')));
    await tester.pumpAndSettle();

    final events = read().eventsFor('vocals');
    expect(events, hasLength(2));
    expect(events.map((e) => e.atMs).toList(), [15000, 20000]);
    expect(events.first.gain, 0.0, reason: 'the edited gain is preserved');
  });

  testWidgets('removing a chip deletes exactly one change point', (
    tester,
  ) async {
    final read = await _pump(
      tester,
      edits: _edits(
        events: [
          StemGainEvent(channel: 'vocals', atMs: 12000, gain: 0),
          StemGainEvent(channel: 'vocals', atMs: 20000, gain: 1),
          StemGainEvent(channel: 'kick', atMs: 4500, gain: 0),
        ],
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('stem_remove_change_point_vocals_12000')),
    );
    await tester.pumpAndSettle();

    expect(read().events, hasLength(2));
    expect(read().eventsFor('vocals').single.atMs, 20000);
    expect(read().eventsFor('kick').single.atMs, 4500);
    expect(find.text('12.0s -> 0%'), findsNothing);
    expect(find.text('20.0s -> 100%'), findsOneWidget);
  });

  testWidgets('the snap toggle only appears when a beat grid is supplied', (
    tester,
  ) async {
    await _pump(tester, edits: _edits(), playheadSourceMs: 1100);
    await tester.tap(
      find.byKey(const ValueKey('stem_add_change_point_vocals')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stem_change_point_snap')), findsNothing);
  });

  testWidgets('snapping to a beat stores the snapped millisecond', (
    tester,
  ) async {
    final read = await _pump(
      tester,
      edits: _edits(),
      playheadSourceMs: 1100,
      beatGridMs: const [0, 500, 1000, 1500, 2000],
    );

    await tester.tap(
      find.byKey(const ValueKey('stem_add_change_point_vocals')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('stem_change_point_snap')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('stem_change_point_snap')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('stem_change_point_save')));
    await tester.pumpAndSettle();

    final written = read().events.single;
    expect(written.atMs, 1000, reason: 'the snapped ms is what is stored');
    expect(written.beatIndex, 2, reason: 'beat index is advisory provenance');
  });

  group('wired to the live stem source', () {
    testWidgets('no source leaves the registry-driven rows untouched', (
      tester,
    ) async {
      await _pump(tester, edits: _edits());

      expect(
        find.byKey(const ValueKey('stem_automation_source_status')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('stem_channel_row_perc')),
          findsOneWidget);
    });

    testWidgets('a ready source names the real separated channels', (
      tester,
    ) async {
      final source = await _boundSource(
        const TrackStems(
          trackId: 42,
          channelSet: defaultStemChannelSet,
          status: StemsStatus.ready,
          channels: ['vocals', 'melody', 'bass', 'kick', 'perc'],
        ),
      );

      await _pump(tester, edits: _edits(), stemSource: source);

      expect(
        find.text('Stems ready: Vocals, Melody, Bass, Kick (low drums), '
            'Hats & Percussion'),
        findsOneWidget,
      );
      for (final id in ['vocals', 'melody', 'bass', 'kick', 'perc']) {
        expect(find.byKey(ValueKey('stem_channel_row_$id')), findsOneWidget);
      }
    });

    testWidgets('a partial manifest only lists the stems that exist', (
      tester,
    ) async {
      final source = await _boundSource(
        const TrackStems(
          trackId: 42,
          channelSet: defaultStemChannelSet,
          status: StemsStatus.ready,
          channels: ['vocals', 'bass'],
        ),
      );

      await _pump(tester, edits: _edits(), stemSource: source);

      expect(find.byKey(const ValueKey('stem_channel_row_vocals')),
          findsOneWidget);
      expect(
          find.byKey(const ValueKey('stem_channel_row_bass')), findsOneWidget);
      expect(find.byKey(const ValueKey('stem_channel_row_perc')), findsNothing);
    });

    testWidgets('authoring is never gated on separation', (tester) async {
      final source = await _boundSource(TrackStems.unavailable(42));

      final read = await _pump(
        tester,
        edits: _edits(),
        playheadSourceMs: 12000,
        stemSource: source,
      );

      expect(
        find.text('Stems not separated. Change points still save.'),
        findsOneWidget,
      );
      // All five registry rows stay authorable: atMs is anchored to the source
      // file, so an edit written now survives a later separation.
      expect(find.byKey(const ValueKey('stem_channel_row_perc')),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('stem_add_change_point_perc')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('stem_change_point_save')));
      await tester.pumpAndSettle();

      expect(read().eventsFor('perc'), hasLength(1));
    });

    testWidgets('a pending source says separation is in flight', (
      tester,
    ) async {
      final source = await _boundSource(
        const TrackStems(
          trackId: 42,
          channelSet: defaultStemChannelSet,
          status: StemsStatus.pending,
        ),
      );

      await _pump(tester, edits: _edits(), stemSource: source);

      expect(
        find.text('Separating stems — change points still save.'),
        findsOneWidget,
      );
    });

    testWidgets('the section repaints when the shared source changes', (
      tester,
    ) async {
      final source = await _boundSource(
        const TrackStems(
          trackId: 42,
          channelSet: defaultStemChannelSet,
          status: StemsStatus.ready,
          channels: ['vocals', 'melody', 'bass', 'kick', 'perc'],
        ),
      );
      await _pump(tester, edits: _edits(), stemSource: source);

      // The DJ deck panel mutes a stem on the same object the timeline holds.
      await source.setMute('kick', true);
      await tester.pump();

      expect(find.byKey(const ValueKey('stem_channel_row_kick')),
          findsOneWidget);
    });
  });
}
