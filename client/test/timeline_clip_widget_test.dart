import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/models/waveform.dart';
import 'package:open_music_player/widgets/timeline_clip_widget.dart';

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
}

Track _track() => Track(
      id: 't1',
      title: 'Dense clip',
      artist: 'Artist',
      duration: 120,
      addedAt: DateTime.utc(2026, 1, 1),
    );
