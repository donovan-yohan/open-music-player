import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/timeline_viewport.dart';
import '../models/track.dart';
import '../models/waveform.dart';
import 'timeline_waveform_painter.dart';

/// Builds a view-only waveform from the provider-owned analysis while replacing
/// only its marker lists with the correction draft's single effective preview.
@visibleForTesting
TimelineWaveformData calibrationWaveformDataForTrack({
  required QueueTrack track,
  required List<int> beatsMs,
  required List<int> downbeatsMs,
  int sampleCount = 1024,
}) {
  final source = richWaveformForTrack(track, sampleCount: sampleCount);
  return TimelineWaveformData(
    frames: source.frames,
    durationMs: source.durationMs,
    beatsMs: List<int>.unmodifiable(beatsMs),
    downbeatsMs: List<int>.unmodifiable(downbeatsMs),
    transientsMs: source.transientsMs,
    silenceRanges: source.silenceRanges,
    analyzed: source.analyzed,
    resolutionLabel: source.resolutionLabel,
    sourceStartMs: source.sourceStartMs,
    coveredSourceFrameCount: source.coveredSourceFrameCount,
  );
}

/// Pointer-friendly, zoomable source-time view for desktop calibration.
///
/// The playhead is an observation supplied by the canonical playback timeline;
/// this widget owns only viewport pan/zoom state.
class AnalysisCalibrationWaveform extends StatefulWidget {
  const AnalysisCalibrationWaveform({
    super.key,
    required this.track,
    required this.beatsMs,
    required this.downbeatsMs,
    this.playheadMs,
  });

  final QueueTrack track;
  final List<int> beatsMs;
  final List<int> downbeatsMs;
  final int? playheadMs;

  @override
  State<AnalysisCalibrationWaveform> createState() =>
      _AnalysisCalibrationWaveformState();
}

class _AnalysisCalibrationWaveformState
    extends State<AnalysisCalibrationWaveform> {
  static const double _initialPixelsPerSecond = 32;
  static const double _maximumPixelsPerSecond = 256;

  double _pixelsPerSecond = _initialPixelsPerSecond;
  int _offsetMs = 0;
  bool _followPlayhead = true;

  void _zoom(double multiplier, double width) {
    final viewport = _viewport(width);
    final next = viewport.zoomAround(
      newPixelsPerSecond: (_pixelsPerSecond * multiplier).clamp(
        TimelineViewport.minPixelsPerSecond,
        _maximumPixelsPerSecond,
      ),
      focalXPx: width / 2,
    );
    setState(() {
      _pixelsPerSecond = next.pixelsPerSecond;
      _offsetMs = next.offsetMs;
      _followPlayhead = false;
    });
  }

  TimelineViewport _viewport(double width) {
    final base = TimelineViewport.clamped(
      durationMs: math.max(1, widget.track.durationMs),
      widthPx: width,
      pixelsPerSecond: _pixelsPerSecond,
      offsetMs: _offsetMs,
    );
    final playhead = widget.playheadMs;
    if (!_followPlayhead || playhead == null) return base;
    return base.panToOffsetMs(playhead - base.visibleDurationMs ~/ 2);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(1.0, constraints.maxWidth);
        final viewport = _viewport(width);
        final contentWidth = math.max(
          width,
          widget.track.durationMs / 1000 * viewport.pixelsPerSecond,
        );
        final sampleCount = contentWidth.ceil().clamp(256, 4096).toInt();
        final waveform = calibrationWaveformDataForTrack(
          track: widget.track,
          beatsMs: widget.beatsMs,
          downbeatsMs: widget.downbeatsMs,
          sampleCount: sampleCount,
        );
        final playhead = widget.playheadMs;
        final playheadX = playhead == null ? null : viewport.msToX(playhead);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Waveform preview',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  key: const ValueKey('analysis_workspace_zoom_out'),
                  tooltip: 'Zoom out',
                  onPressed: viewport.pixelsPerSecond <=
                          TimelineViewport.minPixelsPerSecond
                      ? null
                      : () => _zoom(0.5, width),
                  icon: const Icon(Icons.zoom_out),
                ),
                IconButton(
                  key: const ValueKey('analysis_workspace_zoom_in'),
                  tooltip: 'Zoom in',
                  onPressed: viewport.pixelsPerSecond >= _maximumPixelsPerSecond
                      ? null
                      : () => _zoom(2, width),
                  icon: const Icon(Icons.zoom_in),
                ),
                IconButton(
                  key: const ValueKey('analysis_workspace_follow_playhead'),
                  tooltip: 'Follow playhead',
                  onPressed: playhead == null
                      ? null
                      : () => setState(() => _followPlayhead = true),
                  icon: Icon(
                    _followPlayhead
                        ? Icons.gps_fixed
                        : Icons.gps_not_fixed_outlined,
                  ),
                ),
              ],
            ),
            Semantics(
              label:
                  'Waveform with ${widget.beatsMs.length} short beat markers, '
                  '${widget.downbeatsMs.length} full-height downbeat markers'
                  '${playhead == null ? '' : ', and the live playhead'}',
              child: Container(
                key: const ValueKey('analysis_workspace_waveform'),
                height: 220,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors.outlineVariant),
                ),
                clipBehavior: Clip.hardEdge,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    final next = viewport.panByPixels(-details.delta.dx);
                    setState(() {
                      _offsetMs = next.offsetMs;
                      _followPlayhead = false;
                    });
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        left: -(viewport.offsetMs / 1000) *
                            viewport.pixelsPerSecond,
                        top: 0,
                        bottom: 0,
                        width: contentWidth,
                        child: CustomPaint(
                          painter: TimelineWaveformPainter(
                            peaks: waveform.peaks,
                            waveform: waveform,
                            laneIdentity: widget.track.queueItemId,
                            viewportPixelsPerMs:
                                viewport.pixelsPerSecond / 1000,
                            viewportOriginMs: 0,
                            color: colors.primary,
                            dimColor: colors.onSurfaceVariant,
                            handleColor: colors.secondary,
                          ),
                        ),
                      ),
                      if (playheadX != null &&
                          playheadX >= 0 &&
                          playheadX <= width)
                        Positioned(
                          key: const ValueKey(
                            'analysis_workspace_live_playhead',
                          ),
                          left: playheadX - 1,
                          top: 0,
                          bottom: 0,
                          width: 2,
                          child: ColoredBox(color: colors.error),
                        ),
                      if (!waveform.analyzed)
                        const Center(
                          child: Text(
                            'Waveform detail loading — timing markers remain '
                            'available',
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                _MarkerLegend(height: 12, width: 1, label: 'Beat — short tick'),
                _MarkerLegend(
                  height: 22,
                  width: 3,
                  label: 'Downbeat — full-height accent',
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _MarkerLegend extends StatelessWidget {
  const _MarkerLegend({
    required this.height,
    required this.width,
    required this.label,
  });

  final double height;
  final double width;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 12,
          height: 24,
          child: Center(
            child: Container(
              width: width,
              height: height,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}
