import 'package:flutter/material.dart';

import '../models/dj_deck_state.dart';

class DjDeckHeader extends StatelessWidget {
  const DjDeckHeader({super.key, required this.deck});

  final DjDeckState deck;

  @override
  Widget build(BuildContext context) {
    final remaining =
        (deck.durationMs - deck.positionMs).clamp(0, deck.durationMs);
    final bpm = deck.bpm;
    final key = [deck.musicalKey, deck.camelot].whereType<String>().join(' ');
    final reliableBeatPhase =
        deck.beatPhase == null ? '' : '${deck.beatPhase}/4';
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: Text(
              deck.title ?? 'Deck ${deck.deckId.name.toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Text(
            '${bpm == null ? '--' : (bpm * deck.rate).toStringAsFixed(1)} BPM',
          ),
          const SizedBox(width: 8),
          Text(
              '${deck.ratePercent >= 0 ? '+' : ''}${deck.ratePercent.toStringAsFixed(1)}%'),
          if (key.isNotEmpty) ...[const SizedBox(width: 8), Text(key)],
          if (reliableBeatPhase.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(reliableBeatPhase),
          ],
          const SizedBox(width: 8),
          Text('${_clock(deck.positionMs)}/-${_clock(remaining)}'),
        ],
      ),
    );
  }

  String _clock(int ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
