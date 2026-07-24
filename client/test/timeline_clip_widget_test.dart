import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/timeline_clip_widget.dart';
import 'package:open_music_player/widgets/timeline_waveform_painter.dart';

void main() {
  testWidgets('dense waveform remains below the opaque gain badge', (
    tester,
  ) async {
    Future<({Uint8List bytes, int width})> capture({
      required double peak,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('clip_boundary'),
              child: SizedBox(
                width: 300,
                height: 80,
                child: TimelineClipWidget(
                  track: _track(),
                  peaks: List<double>.filled(2048, peak),
                  waveform: TimelineWaveformData(
                    durationMs: 120000,
                    frames: List<WaveformFrame>.filled(
                      2048,
                      WaveformFrame(
                        peak: peak,
                        rms: peak,
                        low: peak,
                        mid: peak,
                        high: peak,
                      ),
                    ),
                  ),
                  viewportPixelsPerMs: 1,
                  viewportOriginMs: 0,
                  trim: TrimRange.full(120000),
                  role: LaneRole.current,
                  accent: Colors.orange,
                  stateLabel: 'Now playing',
                  gain: 1,
                  showGainBadge: true,
                  showInLaneChip: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('clip_boundary')),
      );
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final width = image.width;
        image.dispose();
        return (bytes: bytes!.buffer.asUint8List(), width: width);
      });
      return pixels!;
    }

    final dense = await capture(peak: 1);
    final badge =
        tester.getRect(find.byKey(const ValueKey('timeline_gain_t1')));
    final boundary =
        tester.getRect(find.byKey(const ValueKey('clip_boundary')));
    final sampleX = (badge.left - boundary.left + 3).floor();
    final sampleY = (badge.center.dy - boundary.top).floor();
    final offset = (sampleY * dense.width + sampleX) * 4;
    final densePixel = dense.bytes.sublist(offset, offset + 4);

    final quiet = await capture(peak: 0);
    final quietPixel = quiet.bytes.sublist(offset, offset + 4);

    expect(densePixel, orderedEquals(quietPixel));
  });

  testWidgets('DPR3 border overlays an 8px waveform without insetting it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 8,
            height: 8,
            child: TimelineClipWidget(
              track: _track(),
              peaks: const [1, 1],
              viewportPixelsPerMs: 1,
              viewportOriginMs: 0,
              trim: TrimRange.full(120000),
              role: LaneRole.current,
              accent: Colors.orange,
              stateLabel: 'Now playing',
              showInLaneChip: false,
            ),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('timeline_waveform_t1'))),
      const Size(8, 8),
      reason: 'the 2.5px active border must paint over, not reduce, the body',
    );
  });

  testWidgets('projects beat density only within tempo-scaled segments', (
    tester,
  ) async {
    final waveform = TimelineWaveformData.fromPeaks(
      const [0.5],
      durationMs: 1000,
      beatsMs: const [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000],
      downbeatsMs: const [0, 400, 800],
    );
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'scaled',
        trackId: 't1',
        sourceDurationMs: 1000,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        timelineStartMs: 0,
      ),
      rateAutomation: const PlaybackRateAutomation(
        segments: [
          PlaybackRateSegment(
            startMs: 200,
            endMs: 400,
            startRate: 1,
            endRate: 1,
            tempoScale: 2,
          ),
          PlaybackRateSegment(
            startMs: 600,
            endMs: 800,
            startRate: 1,
            endRate: 1,
            tempoScale: 0.5,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 80,
          child: TimelineClipWidget(
            track: _track(),
            peaks: const [0.5],
            waveform: waveform,
            mixClip: clip,
            viewportPixelsPerMs: 1,
            viewportOriginMs: 0,
            trim: TrimRange.full(1000),
            role: LaneRole.current,
            accent: Colors.orange,
            stateLabel: 'Now playing',
            showInLaneChip: false,
          ),
        ),
      ),
    );

    final painter = tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('timeline_waveform_t1')),
        )
        .painter! as TimelineWaveformPainter;

    expect(identical(painter.waveform, waveform), isTrue);
    expect(
      painter.projectedBeatMarkers,
      [0, 100, 200, 250, 300, 350, 400, 500, 600, 800, 900, 1000],
    );
    expect(painter.waveform!.downbeatsMs, waveform.downbeatsMs);
  });

  testWidgets('projects trimmed waveform beats using absolute source positions',
      (
    tester,
  ) async {
    const sourceStartMs = 5000;
    const waveform = TimelineWaveformData(
      durationMs: 1000,
      sourceStartMs: sourceStartMs,
      frames: [
        WaveformFrame(peak: 0.5, rms: 0.5, low: 0.5, mid: 0.5, high: 0.5),
      ],
      beatsMs: [
        0,
        100,
        200,
        300,
        400,
        500,
        600,
        700,
        800,
        900,
        1000,
      ],
    );
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'trimmed-scaled',
        trackId: 't1',
        sourceDurationMs: 6000,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceStartMs + 1000,
        timelineStartMs: 0,
      ),
      rateAutomation: const PlaybackRateAutomation(
        segments: [
          PlaybackRateSegment(
            startMs: 200,
            endMs: 400,
            startRate: 1,
            endRate: 1,
            tempoScale: 2,
          ),
          PlaybackRateSegment(
            startMs: 600,
            endMs: 800,
            startRate: 1,
            endRate: 1,
            tempoScale: 0.5,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 80,
          child: TimelineClipWidget(
            track: _track(),
            peaks: const [0.5],
            waveform: waveform,
            mixClip: clip,
            viewportPixelsPerMs: 1,
            viewportOriginMs: 0,
            trim: TrimRange.full(1000),
            role: LaneRole.current,
            accent: Colors.orange,
            stateLabel: 'Now playing',
            showInLaneChip: false,
          ),
        ),
      ),
    );

    final painter = tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('timeline_waveform_t1')),
        )
        .painter! as TimelineWaveformPainter;

    expect(
      painter.projectedBeatMarkers,
      [0, 100, 200, 250, 300, 350, 400, 500, 600, 800, 900, 1000],
    );
    expect(
      painter.projectedBeatMarkers!.every(
        (marker) => marker >= 0 && marker <= waveform.durationMs,
      ),
      isTrue,
      reason: 'painter markers must remain local to the trimmed waveform',
    );
  });

  testWidgets('scaled rebuilds retain waveform and paint cache identity', (
    tester,
  ) async {
    final waveform = TimelineWaveformData.fromPeaks(
      const [0.2, 0.5, 0.8, 0.4],
      durationMs: 1000,
      beatsMs: const [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000],
      downbeatsMs: const [0, 400, 800],
    );
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'scaled-cache',
        trackId: 't1',
        sourceDurationMs: 1000,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        timelineStartMs: 0,
      ),
      rateAutomation: const PlaybackRateAutomation(
        segments: [
          PlaybackRateSegment(
            startMs: 200,
            endMs: 400,
            startRate: 1,
            endRate: 1,
            tempoScale: 2,
          ),
          PlaybackRateSegment(
            startMs: 600,
            endMs: 800,
            startRate: 1,
            endRate: 1,
            tempoScale: 0.5,
          ),
        ],
      ),
    );
    final cache = TimelineWaveformPaintCache();

    Widget build(Color accent) => MaterialApp(
          home: SizedBox(
            width: 300,
            height: 80,
            child: TimelineClipWidget(
              track: _track(),
              peaks: waveform.peaks,
              waveform: waveform,
              mixClip: clip,
              mappingRevision: clip.rateAutomation,
              paintCache: cache,
              viewportPixelsPerMs: 0.3,
              viewportOriginMs: 0,
              trim: TrimRange.full(1000),
              role: LaneRole.current,
              accent: accent,
              stateLabel: 'Now playing',
              showInLaneChip: false,
            ),
          ),
        );

    await tester.pumpWidget(build(Colors.orange));
    final first = tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('timeline_waveform_t1')),
        )
        .painter! as TimelineWaveformPainter;
    expect(identical(first.waveform, waveform), isTrue);
    expect(cache.frameGeometryBuildCount, 1);
    expect(cache.markerGeometryBuildCount, 1);

    await tester.pumpWidget(build(Colors.teal));
    final rebuilt = tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('timeline_waveform_t1')),
        )
        .painter! as TimelineWaveformPainter;
    expect(identical(rebuilt.waveform, waveform), isTrue);
    expect(
      identical(rebuilt.projectedBeatMarkers, first.projectedBeatMarkers),
      isTrue,
    );
    expect(clip.projectedBeatMarkerCacheEntryCount, 1);
    expect(cache.paintCount, 2);
    expect(cache.frameGeometryBuildCount, 1);
    expect(cache.markerGeometryBuildCount, 1);
  });

  testWidgets('preserves waveform identity when no tempo scale is selected', (
    tester,
  ) async {
    final waveform = TimelineWaveformData.fromPeaks(
      const [0.5],
      durationMs: 1000,
      beatsMs: const [0, 500, 1000],
    );
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'unscaled',
        trackId: 't1',
        sourceDurationMs: 1000,
        sourceStartMs: 0,
        sourceEndMs: 1000,
        timelineStartMs: 0,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 80,
          child: TimelineClipWidget(
            track: _track(),
            peaks: const [0.5],
            waveform: waveform,
            mixClip: clip,
            viewportPixelsPerMs: 1,
            viewportOriginMs: 0,
            trim: TrimRange.full(1000),
            role: LaneRole.current,
            accent: Colors.orange,
            stateLabel: 'Now playing',
            showInLaneChip: false,
          ),
        ),
      ),
    );

    final painter = tester
        .widget<CustomPaint>(
          find.byKey(const ValueKey('timeline_waveform_t1')),
        )
        .painter! as TimelineWaveformPainter;

    expect(identical(painter.waveform, waveform), isTrue);
  });
}

QueueTrack _track() => QueueTrack(
      id: 't1',
      title: 'Dense clip',
      artist: 'Artist',
      duration: 120,
      addedAt: DateTime.utc(2026, 1, 1),
    );
