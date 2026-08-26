import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../models/track.dart';
import '../../../models/timeline_viewport.dart';
import '../../../models/waveform.dart';
import '../../../widgets/timeline_waveform_painter.dart';
import '../models/dj_deck_state.dart';
import 'dj_deck_notice.dart';

class DjWaveformLane extends StatefulWidget {
  const DjWaveformLane({
    super.key,
    required this.deck,
    required this.track,
    required this.color,
  });
  final DjDeckState deck;
  final QueueTrack? track;
  final Color color;
  @override
  State<DjWaveformLane> createState() => _DjWaveformLaneState();
}

class _DjWaveformLaneState extends State<DjWaveformLane> {
  static const _pixelsPerSecond = 90.0;
  final _cache = TimelineWaveformPaintCache();
  _DjWaveformDataCache? _waveformCache;

  _DjWaveformDataCache _cachedWaveform({
    required QueueTrack? track,
    required int durationMs,
    required int sampleCount,
  }) {
    final cached = _waveformCache;
    if (cached != null &&
        cached.matches(
          track: track,
          durationMs: durationMs,
          sampleCount: sampleCount,
        )) {
      return cached;
    }
    final waveform = track == null
        ? TimelineWaveformData(
            durationMs: durationMs,
            frames: const [],
            analyzed: false,
          )
        : richWaveformForTrack(track, sampleCount: sampleCount);
    return _waveformCache = _DjWaveformDataCache(
      track: track,
      durationMs: durationMs,
      sampleCount: sampleCount,
      waveform: waveform,
    );
  }

  @override
  Widget build(BuildContext context) {
    // A refused deck explains itself where the waveform would be; the lane's
    // painter path below is untouched.
    if (widget.deck.loadFailure != null) return DjDeckNotice(deck: widget.deck);
    return RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = math.max(1.0, constraints.maxWidth);
            final track = widget.track;
            final durationMs = math.max(
              1,
              track?.durationMs ?? widget.deck.durationMs,
            );
            final viewport = TimelineViewport.clamped(
              durationMs: durationMs,
              widthPx: width,
              pixelsPerSecond: _pixelsPerSecond,
              offsetMs: widget.deck.positionMs,
            ).panToOffsetMs(
              widget.deck.positionMs -
                  ((width / _pixelsPerSecond) * 1000).round() ~/ 2,
            );
            final contentWidth = math.max(
              width,
              durationMs / 1000 * _pixelsPerSecond,
            );
            final cachedWaveform = _cachedWaveform(
              track: track,
              durationMs: durationMs,
              sampleCount: contentWidth.ceil().clamp(256, 4096),
            );
            final waveform = cachedWaveform.waveform;
            return Semantics(
              label: 'Deck ${widget.deck.deckId.name.toUpperCase()} waveform',
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: -(viewport.offsetMs / 1000) * _pixelsPerSecond,
                      width: contentWidth,
                      top: 0,
                      bottom: 0,
                      child: CustomPaint(
                        painter: TimelineWaveformPainter(
                          peaks: cachedWaveform.peaks,
                          waveform: waveform,
                          laneIdentity: widget.deck.queueItemId ??
                              'deck-${widget.deck.deckId.name}',
                          paintCache: _cache,
                          viewportPixelsPerMs: _pixelsPerSecond / 1000,
                          viewportOriginMs: 0,
                          color: widget.color,
                          dimColor:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          handleColor: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    ),
                    // The fixed centre playhead. It resolves from the
                    // waveformPlayhead design token in both themes, and D1's
                    // shared column grid puts this axis down the middle of the
                    // centre (mixer/crossfader) column rather than on a deck
                    // A/B boundary, so it cannot read as a divider (#415).
                    //
                    // The pixels the bar actually crosses are waveform peaks in
                    // the deck lane colour, not the surface: dark deck B is one
                    // hue step from the playhead token (1.1:1), so a bare 2dp
                    // bar vanishes into its own lane. A 1dp surface hairline on
                    // each side separates it from any lane colour (#415).
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: 4,
                        height: double.infinity,
                        child: ColoredBox(
                          key: ValueKey(
                            'dj_waveform_playhead_hairline_'
                            '${widget.deck.deckId.name}',
                          ),
                          color: Theme.of(context).colorScheme.surface,
                          child: Center(
                            child: SizedBox(
                              width: 2,
                              height: double.infinity,
                              child: ColoredBox(
                                key: ValueKey(
                                  'dj_waveform_playhead_'
                                  '${widget.deck.deckId.name}',
                                ),
                                color: SoundQPlayerTheme.of(context)
                                    .waveformPlayhead,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
    );
  }
}

/// Retains waveform object identity over 30Hz deck-position updates. Analysis
/// hydration replaces [QueueTrack.analysis], deliberately invalidating it.
class _DjWaveformDataCache {
  _DjWaveformDataCache({
    required this.track,
    required this.durationMs,
    required this.sampleCount,
    required this.waveform,
  }) : peaks = waveform.peaks;

  final QueueTrack? track;
  final int durationMs;
  final int sampleCount;
  final TimelineWaveformData waveform;
  final List<double> peaks;

  bool matches({
    required QueueTrack? track,
    required int durationMs,
    required int sampleCount,
  }) =>
      identical(this.track?.analysis, track?.analysis) &&
      this.track?.queueItemId == track?.queueItemId &&
      this.durationMs == durationMs &&
      this.sampleCount == sampleCount;
}
