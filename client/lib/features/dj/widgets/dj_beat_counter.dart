import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../models/dj_beat_grid.dart';
import '../models/dj_deck_state.dart';

/// Per-deck position inside the phrase, next to the transport controls (#416).
///
/// Three display tiers, taken from docs/dj-deck-spec.md:82-83:
///
/// * **numbered** (manual or legacy downbeat authority): `bar.beat · phrase N`.
/// * **unnumbered** (a beat grid whose downbeats are generated — the common
///   case on real analysis today): a beat pulse with no bar numbers, because
///   generated meter and phase are compatibility data, not structure.
/// * **none** (no effective beat grid): nothing at all, no placeholder.
///
/// Returns a [Flexible] so a narrow transport slot shrinks the label instead of
/// pushing CUE off the row.
class DjBeatCounter extends StatefulWidget {
  const DjBeatCounter({super.key, required this.deck});

  final DjDeckState deck;

  @override
  State<DjBeatCounter> createState() => _DjBeatCounterState();
}

class _DjBeatCounterState extends State<DjBeatCounter> {
  DjBeatRuler? _ruler;

  @override
  void initState() {
    super.initState();
    _ruler = DjBeatRuler.forAnalysis(widget.deck.queueTrack?.analysis);
  }

  @override
  void didUpdateWidget(covariant DjBeatCounter oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same discipline as the lane's waveform cache: the 30 Hz snapshot replaces
    // the deck state object every tick but leaves the analysis identity alone.
    final analysis = widget.deck.queueTrack?.analysis;
    if (identical(oldWidget.deck.queueTrack?.analysis, analysis)) return;
    _ruler = DjBeatRuler.forAnalysis(analysis);
  }

  @override
  Widget build(BuildContext context) {
    final ruler = _ruler;
    if (ruler == null) return const SizedBox.shrink();
    final accent = SoundQPlayerTheme.of(context).waveformBeat;
    final deckName = widget.deck.deckId.name;
    final position =
        ruler.numbered ? ruler.positionAt(widget.deck.positionMs) : null;
    if (position != null) {
      return Flexible(
        fit: FlexFit.loose,
        child: Text(
          position.label,
          key: ValueKey('dj_beat_counter_$deckName'),
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: accent),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
        ),
      );
    }
    final fraction = ruler.beatFractionAt(widget.deck.positionMs);
    final onBeat = fraction != null && fraction < 0.5;
    return SizedBox(
      width: 6,
      height: 6,
      child: DecoratedBox(
        key: ValueKey('dj_beat_pulse_$deckName'),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent.withValues(alpha: onBeat ? 0.9 : 0.35),
        ),
      ),
    );
  }
}
