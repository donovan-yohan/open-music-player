import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../dj_deck_copy.dart';
import '../models/dj_camelot.dart';
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
  _DjHeaderMetric(
    this.text,
    this.dropRank, {
    this.minWidth = 0,
    this.tappable = false,
  });

  final String text;
  final int? dropRank;
  final double minWidth;

  /// True for the BPM segment, which doubles as the tempo sheet's tap target
  /// (#413). Nothing else in the run is interactive.
  final bool tappable;
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
  const DjDeckHeader({super.key, required this.deck, this.onTapBpm});

  final DjDeckState deck;

  /// Opens the deck's tempo and key sheet (#413). Null leaves the run inert,
  /// which is what a header built outside the deck layout gets.
  ///
  /// The trigger is the BPM segment because BPM is the one metric the give
  /// order never drops (`dropRank: null`), so the control can never disappear
  /// with the run. Its target is the header band's own height — measured at
  /// **36dp** at the three serviceable fixtures (the 44dp band less the 8dp
  /// overview strip) and 42dp where the strip is dropped — i.e. below the 48dp
  /// minimum by construction. That is the same deliberate ladder
  /// `DjPitchFader.nudgeExtentFor` and `DjDeckNotice`'s 24dp action already sit
  /// on (docs/dj-deck-spec.md, "Geometry budget"), and it is documented there
  /// rather than silently accepted: the header band is pinned by the row budget
  /// and a taller tap target would have to come out of the waveform stack.
  final VoidCallback? onTapBpm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final headerKey = ValueKey('dj_deck_header_${deck.deckId.name}');
    // A deck with no audio has no metrics, and says so. It used to render the
    // whole placeholder run — `-- BPM`, `+0.0%`, `0:00/-0:00` — at full
    // emphasis beside a lane saying the track is not on this device, which is
    // the header advertising a track it does not have (#414).
    if (!deck.isLoaded) {
      final muted = theme.colorScheme.onSurfaceVariant;
      return Row(
        key: headerKey,
        children: [
          Expanded(
            child: Text(
              deck.title ?? 'Deck ${deck.deckId.name.toUpperCase()}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(color: muted),
            ),
          ),
          const SizedBox(width: AppTheme.space2),
          Flexible(
            child: Text(
              djDeckHeaderNotLoaded,
              key: ValueKey('dj_deck_header_status_${deck.deckId.name}'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
          ),
        ],
      );
    }
    final remaining =
        (deck.durationMs - deck.positionMs).clamp(0, deck.durationMs);
    final bpm = deck.bpm;
    // `A minor 8A -> 3A` while the deck is shifted; the plain pair at zero.
    // One parser, in dj_camelot.dart, and the header never re-derives the wheel
    // arithmetic itself.
    final key = djDeckKeySegment(
      musicalKey: deck.musicalKey,
      camelot: deck.camelot,
      semitones: deck.keySemitones,
    );
    final reliableBeatPhase =
        deck.beatPhase == null ? '' : '${deck.beatPhase}/4';
    return LayoutBuilder(
      key: headerKey,
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Display order; `dropRank` is the give-order, which is deliberately
        // not the same sequence.
        final metrics = <_DjHeaderMetric>[
          _DjHeaderMetric(
            '${bpm == null ? '--' : (bpm * deck.rate).toStringAsFixed(1)} BPM',
            null,
            tappable: true,
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
              _segment(metric, scale, metricStyle, constraints.maxHeight),
            ],
          ],
        );
      },
    );
  }

  /// One metric, and — for BPM — the tempo sheet's tap target around it.
  ///
  /// The target is grown to the band height rather than to the text's own
  /// height, so the whole header band under the number is tappable instead of
  /// a ~16dp text box. `HitTestBehavior.opaque` because the box is otherwise
  /// transparent above the `Text`. Layout is unchanged: the `SizedBox` takes a
  /// height the `Row` already offered and the `ConstrainedBox` inside it is the
  /// same one that was there before.
  Widget _segment(
    _DjHeaderMetric metric,
    double scale,
    TextStyle style,
    double bandHeight,
  ) {
    final box = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: metric.intrinsicWidth * scale),
      child: Text(
        metric.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
    if (!metric.tappable || onTapBpm == null) return box;
    return KeyedSubtree(
      key: ValueKey('dj_tempo_key_${deck.deckId.name}'),
      child: GestureDetector(
        key: ValueKey('dj_bpm_${deck.deckId.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTapBpm,
        child: SizedBox(
          // Unbounded only when the header is laid out outside the deck's row
          // budget; there the segment simply keeps its intrinsic height.
          height: bandHeight.isFinite ? bandHeight : null,
          child: Center(child: box),
        ),
      ),
    );
  }

  String _clock(int ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
