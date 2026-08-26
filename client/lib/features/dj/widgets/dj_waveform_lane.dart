import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../models/track.dart';
import '../../../models/track_analysis.dart';
import '../../../models/timeline_viewport.dart';
import '../../../models/waveform.dart';
import '../../../widgets/timeline_waveform_painter.dart';
import '../models/dj_beat_grid.dart';
import '../models/dj_deck_state.dart';
import 'dj_beat_ruler_painter.dart';
import 'dj_deck_notice.dart';

class DjWaveformLane extends StatefulWidget {
  const DjWaveformLane({
    super.key,
    required this.deck,
    required this.track,
    required this.color,
    this.pixelsPerSecond = kDjLaneDetailPixelsPerSecond,
  });
  final DjDeckState deck;
  final QueueTrack? track;
  final Color color;

  /// Lane zoom. The deck has no zoom control yet, so production is always the
  /// detail default; the parameter exists so the ruler's density rule is
  /// directly pumpable at [kDjLaneOverviewPixelsPerSecond] (#416).
  final double pixelsPerSecond;
  @override
  State<DjWaveformLane> createState() => _DjWaveformLaneState();
}

class _DjWaveformLaneState extends State<DjWaveformLane> {
  final _cache = TimelineWaveformPaintCache();
  _DjWaveformDataCache? _waveformCache;
  _DjRulerTickCache? _rulerCache;

  /// Ruler geometry is rebuilt only when the analysis, the content width or the
  /// zoom changes — never on a position tick (#416, ~508 beats per deck).
  List<DjBeatTick> _cachedTicks({
    required QueueTrack? track,
    required int durationMs,
    required double contentWidth,
  }) {
    final analysis = track?.analysis;
    final cached = _rulerCache;
    if (cached != null &&
        cached.matches(
          analysis: analysis,
          durationMs: durationMs,
          contentWidth: contentWidth,
          pixelsPerSecond: widget.pixelsPerSecond,
        )) {
      return cached.ticks;
    }
    final ruler = DjBeatRuler.forAnalysis(analysis);
    final ticks = ruler == null
        ? const <DjBeatTick>[]
        : djBeatRulerTicks(
            ruler: ruler,
            durationMs: durationMs,
            contentWidth: contentWidth,
            pixelsPerSecond: widget.pixelsPerSecond,
          );
    _rulerCache = _DjRulerTickCache(
      analysis: analysis,
      durationMs: durationMs,
      contentWidth: contentWidth,
      pixelsPerSecond: widget.pixelsPerSecond,
      ticks: ticks,
    );
    return ticks;
  }

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

  /// The lane's explicit unanalyzed state, or null once frames exist.
  ///
  /// The flat-baseline branch in TimelineWaveformPainter still paints
  /// underneath: this is the affordance, not a replacement lane. A refused deck
  /// never reaches here — DjDeckNotice wins in [build].
  Widget? _analysisNotice(
    BuildContext context,
    TimelineWaveformData waveform,
    QueueTrack? track,
  ) {
    if (waveform.frames.isNotEmpty) return null;
    // A deck holding no track has nothing in flight: no analysis was ever
    // requested and none ever will be, so claiming one is in progress would be
    // a false status (deck B's steady state on a single-item queue). The empty
    // deck says what it is in its own header and in DjDeckNotice, which is lane
    // D's copy; the lane keeps its bare baseline.
    if (track == null) return null;
    final status = track.analysis?.status;
    // Everything else — no analysis object at all, pending/analyzing/stale/
    // unknown, and analyzed-but-not-yet-hydrated — is still on its way.
    final missing = status == TrackAnalysisStatus.failed ||
        status == TrackAnalysisStatus.unsupported;
    final theme = Theme.of(context);
    final deckName = widget.deck.deckId.name;
    return Align(
      // Off the centre playhead axis; a vertical offset would not help, the
      // hairline is full height.
      alignment: const Alignment(-0.45, 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          missing ? 'No analysis' : 'Analyzing…',
          key: ValueKey(
            'dj_lane_analysis_${missing ? 'missing' : 'pending'}_$deckName',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A deck with no audio explains itself where the waveform would be —
    // refused *and* never seeded, because both used to paint an empty lane
    // beside an armed transport (#414). The painter path below is untouched.
    if (widget.deck.loadFailure != null || !widget.deck.isLoaded) {
      return DjDeckNotice(deck: widget.deck);
    }
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
              pixelsPerSecond: widget.pixelsPerSecond,
              offsetMs: widget.deck.positionMs,
            ).panToOffsetMs(
              widget.deck.positionMs -
                  ((width / widget.pixelsPerSecond) * 1000).round() ~/ 2,
            );
            final contentWidth = math.max(
              width,
              durationMs / 1000 * widget.pixelsPerSecond,
            );
            final cachedWaveform = _cachedWaveform(
              track: track,
              durationMs: durationMs,
              sampleCount: contentWidth.ceil().clamp(256, 4096),
            );
            final waveform = cachedWaveform.waveform;
            final analysisNotice = _analysisNotice(context, waveform, track);
            final ticks = _cachedTicks(
              track: track,
              durationMs: durationMs,
              contentWidth: contentWidth,
            );
            final theme = Theme.of(context);
            final beatToken = SoundQPlayerTheme.of(context).waveformBeat;
            // The waveform and the ruler share one content box, so the ruler
            // cannot drift off the peaks it annotates.
            final contentLeft =
                -(viewport.offsetMs / 1000) * widget.pixelsPerSecond;
            return Semantics(
              // The lane's own node, kept addressable by label. The analysis
              // notice below carries a label of its own, and without an
              // explicit child node it is merged into this one and the lane
              // identity stops resolving (the same reason DjDeckNotice does
              // this).
              container: true,
              explicitChildNodes: true,
              label: 'Deck ${widget.deck.deckId.name.toUpperCase()} waveform',
              child: ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: contentLeft,
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
                          viewportPixelsPerMs: widget.pixelsPerSecond / 1000,
                          viewportOriginMs: 0,
                          color: widget.color,
                          dimColor: theme.colorScheme.onSurfaceVariant,
                          handleColor: theme.colorScheme.secondary,
                          // The deck paints its own three-level ruler in design
                          // tokens; the shared painter's white/amber literals
                          // would double-draw underneath it (#416).
                          musicalMarkers: false,
                        ),
                      ),
                    ),
                    if (ticks.isNotEmpty)
                      Positioned(
                        left: contentLeft,
                        width: contentWidth,
                        top: 0,
                        bottom: 0,
                        // A position tick rewrites `left`, which marks the
                        // Stack needing layout, and layout always ends in
                        // markNeedsPaint — so without a boundary of its own the
                        // ruler replays every tick (and every phrase
                        // TextPainter) at 30 Hz however cheap shouldRepaint is.
                        // The tick geometry is position-independent, so the
                        // boundary lets a pure translation reuse the recorded
                        // layer.
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: DjBeatRulerPainter(
                              ticks: ticks,
                              beatColor: beatToken.withValues(alpha: 0.28),
                              barColor: beatToken.withValues(alpha: 0.55),
                              phraseColor: beatToken.withValues(alpha: 0.85),
                              labelStyle: (theme.textTheme.labelSmall ??
                                      const TextStyle())
                                  .copyWith(
                                color: beatToken.withValues(alpha: 0.85),
                              ),
                            ),
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
                    // Peaks arrive from the per-track analysis endpoint long
                    // after the deck seed, and a lane with no frames paints a
                    // flat centre line that is indistinguishable from silence.
                    // Say which state the lane is in instead (#410).
                    //
                    // Held off the centre axis and painted last: the playhead's
                    // hairline is an opaque full-height surface band on that
                    // exact axis, so a centred label came out bisected
                    // ("Analy|zing…") on every deck entry.
                    if (analysisNotice != null) analysisNotice,
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
/// Retains ruler tick geometry over 30Hz deck-position updates.
class _DjRulerTickCache {
  const _DjRulerTickCache({
    required this.analysis,
    required this.durationMs,
    required this.contentWidth,
    required this.pixelsPerSecond,
    required this.ticks,
  });

  final TrackAnalysis? analysis;
  final int durationMs;
  final double contentWidth;
  final double pixelsPerSecond;
  final List<DjBeatTick> ticks;

  bool matches({
    required TrackAnalysis? analysis,
    required int durationMs,
    required double contentWidth,
    required double pixelsPerSecond,
  }) =>
      identical(this.analysis, analysis) &&
      this.durationMs == durationMs &&
      this.contentWidth == contentWidth &&
      this.pixelsPerSecond == pixelsPerSecond;
}

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
