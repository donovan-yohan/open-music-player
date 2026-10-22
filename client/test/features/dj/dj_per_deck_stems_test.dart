import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/stem_channel_source.dart';
import 'package:open_music_player/features/stems/track_stem_channel_source.dart';

import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_stem_panel.dart';

import '../../support/dj_viewport_fixtures.dart';
import '../../support/fake_voice.dart';
import '../../support/gated_stems_service.dart';

void main() {
  test('both decks bind independent manifests without blocking voice loading',
      () async {
    final service = GatedStemsService();
    final a = TrackStemChannelSource(service: service);
    final b = TrackStemChannelSource(service: service);
    final session = DjSessionProvider.prototype(
      voiceFactory: () => FakeVoice('independent-stems'),
      deckStems: {DjDeckId.a: a, DjDeckId.b: b},
    );
    for (final deck in [DjDeckId.a, DjDeckId.b]) {
      await session
          .load(deck, DjDeckLoad(trackRef: '42', localUri: Uri.file('/42.wav')))
          .timeout(const Duration(milliseconds: 100));
    }
    expect(service.gets.map((r) => r.$1), [42, 42]);
    for (final request in service.gets) {
      request.$2.complete(const TrackStems(
          trackId: 42,
          channelSet: defaultStemChannelSet,
          status: StemsStatus.ready,
          channels: ['vocals']));
    }
    await Future<void>.delayed(Duration.zero);
    await a.setGain('vocals', .2);
    await a.setMute('vocals', true);
    expect(b.channels.single.gain, 1);
    expect(b.channels.single.muted, isFalse);
    await session.load(DjDeckId.a,
        DjDeckLoad(trackRef: 'local:file', localUri: Uri.file('/local.wav')));
    expect(a.trackId, isNull);
    expect(b.trackId, 42);
    session.dispose();
    a.dispose();
    b.dispose();
  });

  testWidgets('deck B never renders deck A stem source', (tester) async {
    final a = TrackStemChannelSource(service: GatedStemsService());
    final session = DjSessionProvider.prototype(
      voiceFactory: () => FakeVoice('stem-deck'),
      resolver: const DirectEngineAudioSourceResolver(),
      stems: a,
    );
    await pumpDjScreen(tester, session: session, viewport: landscapeReference);
    await tester.tap(find.text('STEMS').first);
    await tester.pump();
    await tester.tap(find.text('STEMS').last);
    await tester.pump();
    final panels =
        tester.widgetList<DjStemPanel>(find.byType(DjStemPanel)).toList();
    expect(panels, hasLength(2));
    expect(identical(panels[0].source, panels[1].source), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
    a.dispose();
  });
}
