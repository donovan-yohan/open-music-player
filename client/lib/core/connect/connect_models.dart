import 'dart:convert';
import '../audio/playback_queue_projection.dart';
import '../audio/playback_session.dart';

/// Private, whitelist-only host metadata. No source URI, artwork or extras.
class ConnectPlayback {
  const ConnectPlayback(
      {required this.sessionId,
      required this.queueItemId,
      required this.trackId,
      required this.title,
      required this.artist,
      required this.playing,
      required this.processingState,
      required this.positionMs,
      required this.durationMs,
      required this.activeVoiceCount});
  final String sessionId;
  final String? queueItemId;
  final int? trackId;
  final String title, artist, processingState;
  final bool playing;
  final int positionMs, durationMs, activeVoiceCount;

  static ConnectPlayback? fromSnapshot(PlaybackSnapshot snapshot) {
    final cue = currentCueFor(snapshot);
    final item = cue?.mediaItem ?? snapshot.currentMediaItem;
    if (item == null) return null;
    final id = RegExp(r'^[1-9][0-9]*$').hasMatch(item.id)
        ? int.tryParse(item.id)
        : null;
    return ConnectPlayback(
        sessionId: _safeIdentity(snapshot.sessionId),
        queueItemId: cue == null ? null : _safeIdentity(cue.queueItemId),
        trackId: id,
        title: _bounded(item.title, 200),
        artist: _bounded(item.artist ?? '', 200),
        playing: snapshot.playing,
        processingState: snapshot.processingState.name,
        positionMs:
            snapshot.localPosition.inMilliseconds.clamp(0, 0x1fffffffffffff),
        durationMs:
            snapshot.localDuration.inMilliseconds.clamp(0, 0x1fffffffffffff),
        activeVoiceCount: snapshot.activeVoiceCount.clamp(0, 4));
  }

  factory ConnectPlayback.fromJson(Map<String, dynamic> json) {
    final track = _map(json['track']);
    final id = track['trackId'];
    if (id != null && (id is! int || id <= 0)) {
      throw const FormatException('Invalid trackId');
    }
    final queue = json['queueItemId'];
    if (queue != null) _string(queue, 128);
    if (json['playing'] is! bool) {
      throw const FormatException('Invalid playing');
    }
    final processing = _string(json['processingState'], 16);
    if (!{'idle', 'loading', 'buffering', 'ready', 'completed'}
        .contains(processing)) {
      throw const FormatException('Invalid processing state');
    }
    return ConnectPlayback(
        sessionId: _string(json['sessionId'], 128),
        queueItemId: queue as String?,
        trackId: id as int?,
        title: _string(track['title'], 200),
        artist: _string(track['artist'], 200),
        playing: json['playing'] as bool,
        processingState: processing,
        positionMs: _integer(json['positionMs']),
        durationMs: _integer(json['durationMs']),
        activeVoiceCount: _integer(json['activeVoiceCount'], max: 4));
  }
  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'queueItemId': queueItemId,
        'track': {'trackId': trackId, 'title': title, 'artist': artist},
        'playing': playing,
        'processingState': processingState,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'activeVoiceCount': activeVoiceCount
      };
  String get semanticKey => jsonEncode({...toJson()}..remove('positionMs'));
}

class ConnectedDevice {
  const ConnectedDevice(
      {required this.deviceId,
      required this.leaseId,
      required this.label,
      required this.platform,
      required this.sequence,
      required this.lastSeenAt,
      required this.leaseExpiresAt,
      required this.playback});
  final String deviceId, leaseId, label, platform;
  final int sequence;
  final DateTime lastSeenAt, leaseExpiresAt;
  final ConnectPlayback? playback;
  factory ConnectedDevice.fromJson(Map<String, dynamic> json) {
    final platform = _string(json['platform'], 16);
    if (!{'android', 'ios', 'macos', 'windows', 'linux', 'web'}
        .contains(platform)) {
      throw const FormatException('Invalid platform');
    }
    return ConnectedDevice(
        deviceId: _uuid(json['deviceId']),
        leaseId: _uuid(json['leaseId']),
        label: _string(json['label'], 64),
        platform: platform,
        sequence: _integer(json['sequence']),
        lastSeenAt: _date(json['lastSeenAt']),
        leaseExpiresAt: _date(json['leaseExpiresAt']),
        playback: json['playback'] == null
            ? null
            : ConnectPlayback.fromJson(_map(json['playback'])));
  }
}

class ConnectedDevices {
  ConnectedDevices(
      {required List<ConnectedDevice> devices, required this.serverTime})
      : devices = List.unmodifiable(devices);
  final List<ConnectedDevice> devices;
  final DateTime serverTime;
  factory ConnectedDevices.fromJson(Map<String, dynamic> json) {
    final devices = json['devices'];
    if (devices is! List || devices.length > 8) {
      throw const FormatException('Invalid device list');
    }
    return ConnectedDevices(
        devices: devices.map((e) => ConnectedDevice.fromJson(_map(e))).toList(),
        serverTime: _date(json['serverTime']));
  }
}

Map<String, dynamic> connectObject(Object? value) => _map(value);
Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected object');
  }
  return value;
}

String _string(Object? value, int max) {
  if (value is! String || utf8.encode(value).length > max) {
    throw const FormatException('Invalid text');
  }
  return value;
}

int _integer(Object? value, {int min = 0, int max = 0x1fffffffffffff}) {
  if (value is! int || value < min || value > max) {
    throw const FormatException('Invalid integer');
  }
  return value;
}

String _uuid(Object? value) {
  final text = _string(value, 36);
  if (!RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
      .hasMatch(text)) {
    throw const FormatException('Invalid UUID');
  }
  return text;
}

DateTime _date(Object? value) {
  final text = _string(value, 40), parsed = DateTime.tryParse(value as String);
  if (parsed == null || !RegExp(r'(Z|[+-]00:00)$').hasMatch(text)) {
    throw const FormatException('Invalid UTC time');
  }
  return parsed.toUtc();
}

String _bounded(String value, int max) {
  final out = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune), size = utf8.encode(char).length;
    if (bytes + size > max) break;
    out.write(char);
    bytes += size;
  }
  return out.toString();
}

String _safeIdentity(String value) =>
    RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(value) ? value : 'redacted';
