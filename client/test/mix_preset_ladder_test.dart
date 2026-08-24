import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/playlists/mix/mix_models.dart';
import 'package:open_music_player/features/playlists/mix/mix_presets.dart';
import 'package:open_music_player/models/mix_plan.dart';

MixPlanClip _clip(
  String id, {
  required int timelineStartMs,
  int? fadeInMs,
  int? fadeOutMs,
  double gainDb = 0,
}) =>
    MixPlanClip(
      clipId: id,
      queueItemId: 'queue-$id',
      trackId: id.replaceAll(RegExp(r'[^0-9]'), ''),
      sourceStartMs: 0,
      sourceEndMs: 200000,
      timelineStartMs: timelineStartMs,
      gainDb: gainDb,
      fadeInMs: fadeInMs,
      fadeOutMs: fadeOutMs,
    );

void main() {
  test('only presets the engine can render are shipped', () {
    expect(
      MixPreset.shipped.map((preset) => preset.label),
      ['Fade', 'Cut'],
    );
    // Rise/Dip/Wave/Melt/Slam need filter or EQ automation the engine does not
    // have; they must not appear until it does.
    expect(MixPresetId.values, [MixPresetId.fade, MixPresetId.cut]);
  });

  test('Fade writes the requested overlap into both fades and unity gain', () {
    final applied = MixPreset.fade.applyTo(
      outgoing: _clip('clip-1', timelineStartMs: 0, gainDb: -1.5),
      incoming: _clip('clip-2', timelineStartMs: 190000, gainDb: -1.5),
      overlapMs: 8000,
    );

    expect(applied.outgoing.fadeOutMs, 8000);
    expect(applied.incoming.fadeInMs, 8000);
    // The preset is a complete statement of the seam envelope, so it writes
    // its own gain rather than inheriting whatever the clip carried.
    expect(applied.outgoing.gainDb, 0);
    expect(applied.incoming.gainDb, 0);
  });

  test('Cut writes zero fades regardless of the requested overlap', () {
    final applied = MixPreset.cut.applyTo(
      outgoing: _clip('clip-1', timelineStartMs: 0),
      incoming: _clip('clip-2', timelineStartMs: 190000),
      overlapMs: 8000,
    );

    expect(MixPreset.cut.overlapFor(8000), 0);
    expect(applied.outgoing.fadeOutMs, 0);
    expect(applied.incoming.fadeInMs, 0);
    expect(applied.outgoing.gainDb, 0);
    expect(applied.incoming.gainDb, 0);
  });

  test('a persisted seam maps back to the preset that produced it', () {
    expect(MixPreset.forOverlapMs(0), MixPreset.cut);
    expect(MixPreset.forOverlapMs(-1), MixPreset.cut);
    expect(MixPreset.forOverlapMs(1), MixPreset.fade);
    expect(MixPreset.forOverlapMs(8000), MixPreset.fade);
    expect(MixPreset.byId(MixPresetId.cut), MixPreset.cut);
    expect(MixPreset.byId(MixPresetId.fade), MixPreset.fade);
  });

  test('a cut seam reads as "No overlap" rather than "0s"', () {
    const cut = MixTransition(
      index: 0,
      outgoingTrackId: 1,
      incomingTrackId: 2,
      preset: 'Cut',
      overlapMs: 0,
    );
    expect(cut.overlapLabel(), 'No overlap');

    const fade = MixTransition(
      index: 0,
      outgoingTrackId: 1,
      incomingTrackId: 2,
      preset: 'Fade',
      overlapMs: 8000,
      bars: 8,
    );
    expect(fade.overlapLabel(), '8s · 8 bars');
  });
}
