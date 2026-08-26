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

/// One metric segment of the header run.
///
/// [dropRank] orders the give-up sequence — lowest rank is surrendered first.
/// A null rank is never dropped, which is BPM and only BPM.
class _DjHeaderMetric {
  _DjHeaderMetric(this.text, this.dropRank, {this.minWidth = 0});

  final String text;
  final int? dropRank;
  final double minWidth;
  double intrinsicWidth = 0;

  bool get droppable => dropRank != null;
}

/// One deck's title + live metric run.
///
/// The band height belongs to `DjLayout`'s row budget, not to this widget, so
/// there is no `SizedBox(height:)` here any more. As the run stops fitting it
/// drops segments in this order — beat phase, key + camelot, pitch %, clock —
/// and BPM is never dropped.
///
/// The decision is *cumulative and measured*, not a set of independent width
/// thresholds: the raw-width constants above are only an outer gate, and text
/// scaling, a long key or a clock past ten minutes never move them. Without the
/// measured pass the proportional cap below became the only mechanism and
/// ellipsised every segment together, so the user was shown `142.1 B…` next to
/// an intact `1/4` — the exact inversion of the documented order (#411). The
/// cap now only ever binds once BPM is the sole survivor, so it cannot overflow
/// the row and cannot truncate the deck's primary metric ahead of a lower
/// priority one.
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
        // Display order; `dropRank` is the give-order, which is deliberately
        // not the same sequence.
        final metrics = <_DjHeaderMetric>[
          _DjHeaderMetric(
            '${bpm == null ? '--' : (bpm * deck.rate).toStringAsFixed(1)} BPM',
            null,
          ),
          _DjHeaderMetric(
            '${deck.ratePercent >= 0 ? '+' : ''}'
                '${deck.ratePercent.toStringAsFixed(1)}%',
            2,
            minWidth: kDjHeaderPitchMinWidth,
          ),
          if (key.isNotEmpty)
            _DjHeaderMetric(key, 1, minWidth: kDjHeaderKeyMinWidth),
          if (reliableBeatPhase.isNotEmpty)
            _DjHeaderMetric(
              reliableBeatPhase,
              0,
              minWidth: kDjHeaderBeatPhaseMinWidth,
            ),
          _DjHeaderMetric(
            '${_clock(deck.positionMs)}/-${_clock(remaining)}',
            3,
            minWidth: kDjHeaderClockMinWidth,
          ),
        ]..retainWhere((metric) => width >= metric.minWidth);

        final metricStyle = DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        );
        for (final metric in metrics) {
          painter.text = TextSpan(text: metric.text, style: metricStyle);
          painter.layout();
          metric.intrinsicWidth = painter.width;
        }
        painter.dispose();

        double budgetFor(int count) => math.max(
              0.0,
              width - count * AppTheme.space2 - kDjHeaderTitleMinWidth,
            );
        double neededBy(List<_DjHeaderMetric> run) =>
            run.fold<double>(0, (sum, metric) => sum + metric.intrinsicWidth);

        // Give up whole segments, cheapest first, until the run fits.
        final giveOrder = metrics.where((metric) => metric.droppable).toList()
          ..sort((a, b) => a.dropRank!.compareTo(b.dropRank!));
        for (final victim in giveOrder) {
          if (neededBy(metrics) <= budgetFor(metrics.length)) break;
          metrics.remove(victim);
        }

        // Last resort, reached only when BPM alone still does not fit: cap
        // proportionally so the row ellipsises instead of overflowing.
        final needed = neededBy(metrics);
        final metricBudget = budgetFor(metrics.length);
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
            for (final metric in metrics) ...[
              const SizedBox(width: AppTheme.space2),
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: metric.intrinsicWidth * scale),
                child: Text(
                  metric.text,
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

  String _clock(int ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
