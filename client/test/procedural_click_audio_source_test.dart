import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/click_audition_projection.dart';
import 'package:open_music_player/core/engine/procedural_click_audio_source.dart';

void main() {
  test('streams a seekable low-rate mono PCM WAV without one PCM allocation',
      () async {
    final source = ProceduralClickAudioSource(
      _track(durationMs: 1000),
      sampleRate: 8000,
    );

    final response = await source.request();
    final chunks = await response.stream.toList();
    final bytes = Uint8List.fromList(chunks.expand((chunk) => chunk).toList());

    expect(response.rangeRequestsSupported, isTrue);
    expect(response.contentType, 'audio/wav');
    expect(response.sourceLength, 44 + 8000 * 2);
    expect(chunks.every((chunk) => chunk.length <= 16 * 1024), isTrue);
    expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
    expect(_uint32(bytes, 24), 8000);
    expect(_uint16(bytes, 22), 1);
    expect(_uint16(bytes, 34), 16);
  });

  test('range requests reproduce exact arbitrary WAV byte slices', () async {
    final source = ProceduralClickAudioSource(_track(durationMs: 300));
    final fullResponse = await source.request();
    final full = await _collect(fullResponse.stream);
    final rangeResponse = await source.request(37, 317);
    final range = await _collect(rangeResponse.stream);

    expect(rangeResponse.offset, 37);
    expect(rangeResponse.contentLength, 280);
    expect(range, full.sublist(37, 317));
  });

  test('accent click has higher peak than the ordinary beat', () async {
    final source = ProceduralClickAudioSource(_track(durationMs: 500));
    final response = await source.request();
    final bytes = await _collect(response.stream);
    final beatPeak = _peak(
      bytes,
      startMs: 100,
      endMs: 118,
      sampleRate: source.sampleRate,
    );
    final accentPeak = _peak(
      bytes,
      startMs: 250,
      endMs: 268,
      sampleRate: source.sampleRate,
    );

    expect(beatPeak, greaterThan(0));
    expect(accentPeak, greaterThan(beatPeak));
  });

  test('native click output delegates focus and session activation', () {
    final source = File(
      'lib/core/engine/procedural_click_audio_source.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(RegExp(r'handleInterruptions\s*:\s*false')),
    );
    expect(
      source,
      contains(RegExp(r'handleAudioSessionActivation\s*:\s*false')),
    );
  });
}

ProjectedClickTrack _track({required int durationMs}) {
  return ProjectedClickTrack(
    queueItemId: 'queue-1',
    clipId: 'clip-1',
    timelineStartMs: 1000,
    timelineEndMs: 1000 + durationMs,
    markers: const [
      ProjectedClickMarker(
        sourcePositionMs: 100,
        timelinePositionMs: 1100,
        outputPositionMs: 1100,
        isAccent: false,
      ),
      ProjectedClickMarker(
        sourcePositionMs: 250,
        timelinePositionMs: 1250,
        outputPositionMs: 1250,
        isAccent: true,
      ),
    ],
  );
}

Future<Uint8List> _collect(Stream<List<int>> stream) async =>
    Uint8List.fromList(
      (await stream.toList()).expand((chunk) => chunk).toList(),
    );

int _uint16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint16(offset, Endian.little);

int _uint32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset, Endian.little);

int _peak(
  Uint8List bytes, {
  required int startMs,
  required int endMs,
  required int sampleRate,
}) {
  final data = ByteData.sublistView(bytes);
  final startSample = (startMs * sampleRate / 1000).floor();
  final endSample = (endMs * sampleRate / 1000).ceil();
  var peak = 0;
  for (var sample = startSample; sample < endSample; sample++) {
    final value = data.getInt16(
      ProceduralClickAudioSource.wavHeaderLength + sample * 2,
      Endian.little,
    );
    if (value.abs() > peak) peak = value.abs();
  }
  return peak;
}
