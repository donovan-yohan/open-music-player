import 'package:flutter/material.dart';

import '../../../models/mix_plan.dart';

/// The transition preset ladder, limited to what the playback engine can
/// actually render today.
///
/// The engine renders volume envelopes and clip placement — nothing else.
/// Fade and Cut are fully expressible in those terms, so they ship. Rise, Dip,
/// Wave, Melt and Slam need real filter/EQ automation, so they are absent
/// rather than mocked: a chip that promises a filter sweep the engine cannot
/// render would be a lie the user can hear.
enum MixPresetId { fade, cut }

@immutable
class MixPreset {
  const MixPreset._({
    required this.id,
    required this.label,
    required this.blurb,
    required this.gainDb,
  });

  final MixPresetId id;
  final String label;

  /// One-line description shown under the chips, sentence case.
  final String blurb;

  /// Clip gain, in dB, this preset imposes on both clips of the seam.
  ///
  /// No shipped preset attenuates, so both are unity and — because applying
  /// a preset must not clobber an authored per-clip gain — unity presets
  /// leave existing gain values untouched on write.
  final double gainDb;

  /// A preset the ladder does not ship, for tests only.
  ///
  /// [applyTo]'s attenuating arm has no shipped caller — every shipped preset
  /// is unity — so without this seam the branch that decides whether a preset
  /// may overwrite an authored clip gain (review finding F-5) cannot be
  /// exercised at all.
  @visibleForTesting
  const MixPreset.forTest({
    required MixPresetId id,
    required String label,
    required String blurb,
    required double gainDb,
  }) : this._(id: id, label: label, blurb: blurb, gainDb: gainDb);

  static const fade = MixPreset._(
    id: MixPresetId.fade,
    label: 'Fade',
    blurb: 'Volume crossfade across the overlap.',
    gainDb: 0,
  );

  static const cut = MixPreset._(
    id: MixPresetId.cut,
    label: 'Cut',
    blurb: 'No overlap — the next track starts where this one ends.',
    gainDb: 0,
  );

  /// Every preset the engine can render, smoothest first.
  static const List<MixPreset> shipped = [fade, cut];

  /// Cut butt-joins the two clips: no overlap, so no envelope either.
  bool get isCut => id == MixPresetId.cut;

  /// The overlap this preset actually uses for a requested length.
  int overlapFor(int requestedMs) => isCut ? 0 : requestedMs;

  /// Writes this preset's concrete envelope onto the two clips of a seam.
  ///
  /// Both fades equal the placement overlap, matching the generator invariant
  /// `fadeOut(i) == fadeIn(i+1) == placement overlap`; callers move
  /// `timelineStartMs` to match.
  ({MixPlanClip outgoing, MixPlanClip incoming}) applyTo({
    required MixPlanClip outgoing,
    required MixPlanClip incoming,
    required int overlapMs,
  }) {
    final overlap = overlapFor(overlapMs);
    // Preserve any authored clip gain: shipped presets are unity, so writing
    // gainDb unconditionally would silently zero a per-clip gain the user
    // (or a future preset) had set. Only override when this preset actually
    // attenuates (review finding F-5).
    final appliesGain = gainDb != 0;
    return (
      outgoing: outgoing.copyWith(
          fadeOutMs: overlap, gainDb: appliesGain ? gainDb : null),
      incoming: incoming.copyWith(
          fadeInMs: overlap, gainDb: appliesGain ? gainDb : null),
    );
  }

  /// The preset a persisted seam represents. A seam with no overlap is a cut;
  /// anything else is rendered as a volume crossfade.
  static MixPreset forOverlapMs(int overlapMs) =>
      overlapMs <= 0 ? MixPreset.cut : MixPreset.fade;

  static MixPreset byId(MixPresetId id) =>
      id == MixPresetId.cut ? MixPreset.cut : MixPreset.fade;
}

/// The preset's curve, drawn as the shape the engine will actually apply:
/// two gain lanes over the seam window.
class MixPresetGlyph extends StatelessWidget {
  const MixPresetGlyph({
    super.key,
    required this.preset,
    required this.color,
    this.size = const Size(26, 14),
  });

  final MixPreset preset;
  final Color color;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: size,
      painter: _MixPresetGlyphPainter(preset: preset, color: color),
    );
  }
}

class _MixPresetGlyphPainter extends CustomPainter {
  const _MixPresetGlyphPainter({required this.preset, required this.color});

  final MixPreset preset;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const top = 1.5;
    final bottom = size.height - 1.5;

    if (preset.isCut) {
      // Outgoing holds full gain to the seam, then stops dead; the incoming
      // track starts at full gain from the same instant.
      final seamX = size.width / 2;
      canvas.drawLine(const Offset(0, top), Offset(seamX, top), stroke);
      canvas.drawLine(Offset(seamX, top), Offset(seamX, bottom), stroke);
      canvas.drawLine(Offset(seamX, top), Offset(size.width, top), stroke);
      return;
    }

    // Straight-line crossfade: outgoing falls, incoming rises, both linear
    // across the whole overlap.
    canvas.drawLine(const Offset(0, top), Offset(size.width, bottom), stroke);
    canvas.drawLine(Offset(0, bottom), Offset(size.width, top), stroke);
  }

  @override
  bool shouldRepaint(_MixPresetGlyphPainter old) =>
      old.preset != preset || old.color != color;
}
