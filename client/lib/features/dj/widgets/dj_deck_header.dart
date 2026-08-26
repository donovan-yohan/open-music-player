import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../models/dj_deck_state.dart';

/// Header width below which the beat-phase counter is dropped.
const double kDjHeaderBeatPhaseMinWidth = 320;

/// Header width below which key + camelot is dropped.
const double kDjHeaderKeyMinWidth = 260;

/// Header width below which the pitch percentage is dropped.
const double kDjHeaderPitchMinWidth = 200;

/// Header width below which the elapsed/remaining clock is dropped.
const double kDjHeaderClockMinWidth = 150;

/// Width the title keeps no matter how wide the metric run wants to be.
const double kDjHeaderTitleMinWidth = 48;

/// One deck's title + live metric run.
///
/// The band height belongs to `DjLayout`'s row budget, not to this widget, so
/// there is no `SizedBox(height:)` here any more. As width falls the metric run
/// drops segments in this order — beat phase, key + camelot, pitch %, clock —
/// and BPM is never dropped. Every remaining metric is width-capped and
/// ellipsised, so no font, locale or textScaler can overflow the row.
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final metrics = <String>[
          '${bpm == null ? '--' : (bpm * deck.rate).toStringAsFixed(1)} BPM',
          if (width >= kDjHeaderPitchMinWidth)
            '${deck.ratePercent >= 0 ? '+' : ''}'
                '${deck.ratePercent.toStringAsFixed(1)}%',
          if (key.isNotEmpty && width >= kDjHeaderKeyMinWidth) key,
          if (reliableBeatPhase.isNotEmpty &&
              width >= kDjHeaderBeatPhaseMinWidth)
            reliableBeatPhase,
          if (width >= kDjHeaderClockMinWidth)
            '${_clock(deck.positionMs)}/-${_clock(remaining)}',
        ];
        // The metrics are non-flex, so the Expanded title alone cannot stop
        // them overflowing the row: they are capped instead. Splitting the
        // budget evenly would ellipsise a long metric while a short one kept
        // slack, so the caps are proportional to what each string actually
        // needs, and no cap binds at all while everything fits.
        final metricStyle = DefaultTextStyle.of(context).style;
        final textScaler = MediaQuery.textScalerOf(context);
        final intrinsic = [
          for (final metric in metrics)
            _measure(metric, metricStyle, textScaler),
        ];
        final needed = intrinsic.fold<double>(0, (sum, w) => sum + w);
        final gaps = metrics.length * AppTheme.space2;
        final metricBudget =
            math.max(0.0, width - gaps - kDjHeaderTitleMinWidth);
        final scale = needed <= metricBudget || needed == 0
            ? 1.0
            : metricBudget / needed;
        return Row(
          children: [
            Expanded(
              child: Text(
                deck.title ?? 'Deck ${deck.deckId.name.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            for (var i = 0; i < metrics.length; i++) ...[
              const SizedBox(width: AppTheme.space2),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: intrinsic[i] * scale),
                child: Text(
                  metrics[i],
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: metricStyle,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static double _measure(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  String _clock(int ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
