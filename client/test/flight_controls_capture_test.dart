// Production widget raster receipts. No app process, account, network or audio.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flight_controls_geometry_test.dart';

void main() {
  final output = Platform.environment['SOUNDQ_FLIGHT_CONTROLS_CAPTURE_DIR'];
  testWidgets('capture actual Queue header and transport operating grid',
      (tester) async {
    await loadFlightFonts(tester);
    final receipts = <Map<String, Object?>>[];
    for (final width in [960.0, 1200.0, 1440.0, 2560.0]) {
      for (final scale in [1.0, 2.0]) {
        const root = ValueKey('flight-controls-capture');
        final playback = FlightPlayback();
        await pumpFlightControls(tester,
            width: width, scale: scale, playback: playback, captureKey: root);
        expectFullFlightLabel(tester, 'Timeline');
        expectFullFlightLabel(tester, 'List');
        final timeline = flightLabel(tester, 'Timeline');
        final seek = find.byKey(const ValueKey('soundq_desktop_seek'));
        final transport =
            find.byKey(const ValueKey('soundq_desktop_transport'));
        final header = find.byKey(const ValueKey('playback_queue_header'));
        expect(tester.getCenter(seek).dx, width / 2);
        expect(tester.getCenter(flightButton('Pause')).dx, width / 2);
        if (scale == 1) expect(tester.getSize(transport).height, 100);
        final entry = <String, Object?>{
          'width': width,
          'textScale': scale,
          'transport': tester.getRect(transport).toString(),
          'queueHeader': tester.getRect(header).toString(),
          'timelineParagraph': timeline.size.toString(),
          'timelineDidExceedMaxLines': timeline.didExceedMaxLines,
          'timelineGlyphs': timeline
              .getBoxesForSelection(
                  const TextSelection(baseOffset: 0, extentOffset: 8))
              .map((b) => b.toRect().toString())
              .toList(),
          'seekCenterX': tester.getCenter(seek).dx,
          'cells': {
            for (final label in [
              'Toggle shuffle',
              'Previous',
              'Pause',
              'Next',
              'Cycle repeat mode'
            ])
              label: {
                'hit': tester.getRect(flightButton(label)).toString(),
                'paint': flightPaint(tester, flightButton(label)).toString()
              }
          },
        };
        final name = 'flight-controls-${width.toInt()}-${scale.toInt()}x';
        Future<void> capture(String suffix) async {
          final boundary =
              tester.renderObject<RenderRepaintBoundary>(find.byKey(root));
          final regions = {
            'header': tester.getRect(header),
            'transport': tester.getRect(transport)
          };
          await tester.runAsync(() async {
            final directory = Directory(output!);
            await directory.create(recursive: true);
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$output/$name-$suffix.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            for (final region in regions.entries) {
              final recorder = ui.PictureRecorder();
              final canvas = Canvas(recorder);
              canvas.drawImageRect(image, region.value,
                  Offset.zero & region.value.size, Paint());
              final picture = recorder.endRecording();
              final crop = await picture.toImage(
                  region.value.width.ceil(), region.value.height.ceil());
              final png = await crop.toByteData(format: ui.ImageByteFormat.png);
              await File('$output/$name-$suffix-${region.key}.png')
                  .writeAsBytes(png!.buffer.asUint8List());
              crop.dispose();
              picture.dispose();
            }
            image.dispose();
          });
        }

        await capture('rest');
        if (scale == 1 && width == 1200) {
          final pointer =
              await tester.createGesture(kind: PointerDeviceKind.mouse);
          await pointer.addPointer(location: Offset.zero);
          await pointer.moveTo(tester.getCenter(flightButton('Next')));
          await tester.pumpAndSettle();
          await capture('hover-next');
          await pointer.removePointer();
          playback.allowNext = false;
          playback.changed();
          await tester.pumpAndSettle();
          await capture('disabled-next');
        }
        receipts.add(entry);
        await tester.runAsync(() async => File('$output/geometry.json')
            .writeAsString(
                const JsonEncoder.withIndent('  ').convert(receipts)));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    }
  },
      skip: output == null,
      variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
