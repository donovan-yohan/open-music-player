import 'package:flutter/material.dart';

import '../dj_deck_copy.dart';
import '../models/dj_hot_cue.dart';

class DjHotCuePads extends StatelessWidget {
  const DjHotCuePads({
    super.key,
    required this.cues,
    required this.onTrigger,
    required this.onSet,
    this.enabled = true,
    this.disabledReason,
  });
  final Map<int, DjHotCue> cues;
  final ValueChanged<int> onTrigger;
  final ValueChanged<int> onSet;

  /// Whether this deck holds audio. Pads on an empty deck used to be fully
  /// coloured and fully armed, and setting a cue on a zero-duration deck is
  /// what produced the divide-by-zero in the overview strip (#414).
  final bool enabled;

  /// Reason shown on the gated pads; the lane's own reason where there is one,
  /// so the pads, the transport and the waveform lane cannot tell the user
  /// three different stories about one deck.
  final String? disabledReason;

  String get _reason => disabledReason ?? djDeckTransportDisabledReason;

  /// Mirrors `DjTransport._gated`. A pad carries its accessible name in its
  /// `Text` child and has no tooltip of its own, so this wrapper is the only
  /// place its reason can live — on screen for a long-press and in
  /// `SemanticsProperties.tooltip` for a screen reader. Gated pads used to
  /// explain nothing at all through either route (#414).
  Widget _gated(Widget child) =>
      enabled ? child : Tooltip(message: _reason, child: child);

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.35,
        children: [
          for (var slot = 1; slot <= 4; slot++)
            _gated(
              GestureDetector(
                onLongPress: enabled ? () => onSet(slot) : null,
                child: FilledButton(
                  key: ValueKey('dj_hot_cue_$slot'),
                  onPressed: enabled ? () => onTrigger(slot) : null,
                  child: Text(cues.containsKey(slot) ? 'C$slot' : '$slot'),
                ),
              ),
            ),
        ],
      );
}
