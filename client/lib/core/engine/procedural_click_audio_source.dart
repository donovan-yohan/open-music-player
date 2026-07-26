// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import 'click_audition_projection.dart';

typedef ClickAudioOutputFactory = ClickAudioOutput Function();
typedef ClickAudioOutputFailureHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Injection seam between click scheduling and the one auxiliary native player.
abstract interface class ClickAudioOutput {
  bool get isLoaded;
  bool get isPlaying;
  int? get positionMs;

  void setAsyncFailureHandler(ClickAudioOutputFailureHandler? handler);
  Future<void> load(
    ProjectedClickTrack track, {
    required int initialPositionMs,
  });
  Future<void> seek(int positionMs);
  Future<void> setVolume(double linearGain);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> dispose();
}

/// One auxiliary player owned by the engine's click auditioner.
///
/// Interruption and audio-session activation handling stay with the app's
/// canonical audio-focus coordinator.
class JustAudioClickOutput implements ClickAudioOutput {
  JustAudioClickOutput({AudioPlayer? player})
      : _player = player ??
            AudioPlayer(
              handleInterruptions: false,
              handleAudioSessionActivation: false,
            );

  final AudioPlayer _player;
  bool _isLoaded = false;
  ClickAudioOutputFailureHandler? _asyncFailureHandler;

  @override
  bool get isLoaded => _isLoaded;

  @override
  bool get isPlaying => _player.playing;

  @override
  int? get positionMs => _isLoaded ? _player.position.inMilliseconds : null;

  @override
  void setAsyncFailureHandler(ClickAudioOutputFailureHandler? handler) {
    _asyncFailureHandler = handler;
  }

  @override
  Future<void> load(
    ProjectedClickTrack track, {
    required int initialPositionMs,
  }) async {
    _isLoaded = false;
    await _player.setAudioSource(
      ProceduralClickAudioSource(track),
      initialPosition: Duration(
        milliseconds: initialPositionMs.clamp(0, track.durationMs),
      ),
    );
    _isLoaded = true;
  }

  @override
  Future<void> seek(int positionMs) =>
      _player.seek(Duration(milliseconds: math.max(0, positionMs)));

  @override
  Future<void> setVolume(double linearGain) =>
      _player.setVolume(linearGain.clamp(0.0, 1.0));

  @override
  Future<void> play() async {
    // just_audio's play future completes at end of media. Scheduling must not
    // hold the auditioner operation queue for the full target clip. Its errors
    // are still surfaced to the generation-scoped auditioner.
    unawaited(
      _player.play().then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          try {
            _asyncFailureHandler?.call(error, stackTrace);
          } catch (_) {
            // A diagnostic callback must not create a second unhandled error.
          }
        },
      ),
    );
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    _isLoaded = false;
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    _isLoaded = false;
    _asyncFailureHandler = null;
    await _player.dispose();
  }
}

/// Pull-based PCM/WAV click track for one selected queue item.
///
/// The source is deliberately low-rate, mono, and clip-local. Native platforms
/// request byte ranges without a giant in-memory PCM allocation. just_audio's
/// web adapter may join the response, but it joins only this target clip at
/// roughly 16 KB per second rather than the multi-track queue.
class ProceduralClickAudioSource extends StreamAudioSource {
  ProceduralClickAudioSource(
    ProjectedClickTrack track, {
    this.sampleRate = 8000,
  })  : assert(sampleRate >= 4000),
        _durationMs = math.max(1, track.durationMs),
        _markers = List<_PcmClickMarker>.unmodifiable([
          for (final marker in track.markers)
            _PcmClickMarker(
              sampleIndex: _sampleIndexFor(
                marker.localOutputPositionMs(track.timelineStartMs),
                sampleRate,
              ),
              isAccent: marker.isAccent,
            ),
        ]..sort((a, b) => a.sampleIndex.compareTo(b.sampleIndex)));

  static const int wavHeaderLength = 44;
  static const int bytesPerSample = 2;
  static const int clickDurationMs = 18;
  static const int _maxResponseChunkBytes = 16 * 1024;

  final int sampleRate;
  final int _durationMs;
  final List<_PcmClickMarker> _markers;

  late final int _sampleCount = ((_durationMs * sampleRate) / 1000).ceil();
  late final int _dataLength = _sampleCount * bytesPerSample;
  late final int _sourceLength = wavHeaderLength + _dataLength;
  late final Uint8List _header = _buildWavHeader(
    sampleRate: sampleRate,
    dataLength: _dataLength,
  );

  int get durationMs => _durationMs;
  int get sourceLength => _sourceLength;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final rangeStart = (start ?? 0).clamp(0, _sourceLength).toInt();
    final rangeEnd =
        (end ?? _sourceLength).clamp(rangeStart, _sourceLength).toInt();
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: _sourceLength,
      contentLength: rangeEnd - rangeStart,
      offset: rangeStart,
      contentType: 'audio/wav',
      stream: _streamRange(rangeStart, rangeEnd),
    );
  }

  Stream<List<int>> _streamRange(int start, int end) async* {
    for (var cursor = start; cursor < end;) {
      final chunkEnd = math.min(end, cursor + _maxResponseChunkBytes);
      yield _renderRange(cursor, chunkEnd);
      cursor = chunkEnd;
    }
  }

  Uint8List _renderRange(int start, int end) {
    final bytes = Uint8List(end - start);
    var markerIndex = _markerIndexAtOrBefore(
      math.max(0, (start - wavHeaderLength) ~/ bytesPerSample),
    );
    var cachedSampleIndex = -1;
    var cachedSample = 0;
    for (var absolute = start; absolute < end; absolute++) {
      final destination = absolute - start;
      if (absolute < wavHeaderLength) {
        bytes[destination] = _header[absolute];
        continue;
      }
      final pcmByte = absolute - wavHeaderLength;
      final sampleIndex = pcmByte ~/ bytesPerSample;
      while (markerIndex + 1 < _markers.length &&
          _markers[markerIndex + 1].sampleIndex <= sampleIndex) {
        markerIndex++;
      }
      if (cachedSampleIndex != sampleIndex) {
        cachedSampleIndex = sampleIndex;
        cachedSample = _sampleAt(sampleIndex, markerIndex);
      }
      bytes[destination] =
          pcmByte.isEven ? cachedSample & 0xff : (cachedSample >> 8) & 0xff;
    }
    return bytes;
  }

  int _sampleAt(int sampleIndex, int markerIndex) {
    if (markerIndex < 0 || markerIndex >= _markers.length) return 0;
    final marker = _markers[markerIndex];
    final clickSample = sampleIndex - marker.sampleIndex;
    final clickSamples = (clickDurationMs * sampleRate) ~/ 1000;
    if (clickSample < 0 || clickSample >= clickSamples) return 0;

    final progress = clickSample / math.max(1, clickSamples - 1);
    final envelope = math.pow(1 - progress, 2).toDouble();
    final frequency = marker.isAccent ? 1320.0 : 880.0;
    final amplitude = marker.isAccent ? 0.90 : 0.55;
    final sample =
        math.sin(2 * math.pi * frequency * clickSample / sampleRate) *
            envelope *
            amplitude;
    return (sample * 32767).round().clamp(-32768, 32767);
  }

  int _markerIndexAtOrBefore(int sampleIndex) {
    var low = 0;
    var high = _markers.length - 1;
    var match = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_markers[middle].sampleIndex <= sampleIndex) {
        match = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return match;
  }

  static int _sampleIndexFor(int positionMs, int sampleRate) =>
      (positionMs * sampleRate / 1000).round();

  static Uint8List _buildWavHeader({
    required int sampleRate,
    required int dataLength,
  }) {
    final header = ByteData(wavHeaderLength);
    void ascii(int offset, String value) {
      for (var index = 0; index < value.length; index++) {
        header.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * bytesPerSample, Endian.little);
    header.setUint16(32, bytesPerSample, Endian.little);
    header.setUint16(34, bytesPerSample * 8, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataLength, Endian.little);
    return header.buffer.asUint8List();
  }
}

class _PcmClickMarker {
  const _PcmClickMarker({
    required this.sampleIndex,
    required this.isAccent,
  });

  final int sampleIndex;
  final bool isAccent;
}
