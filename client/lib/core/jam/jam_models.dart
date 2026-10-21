import 'dart:convert';
import 'dart:math';
import '../audio/playback_session.dart';
import '../connect/connect_models.dart';

Map<String, dynamic> jamObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid Jam object');
  }
  return value;
}

void jamKeys(Map<String, dynamic> j, List<String> required,
    [List<String> optional = const []]) {
  if (required.any((k) => !j.containsKey(k)) ||
      j.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
    throw const FormatException('Invalid Jam fields');
  }
}

String jamText(Object? v, int max, {bool nonempty = false}) {
  if (v is! String || utf8.encode(v).length > max || (nonempty && v.isEmpty)) {
    throw const FormatException('Invalid Jam text');
  }
  return v;
}

int jamInt(Object? v, {int min = 0, int max = 0x1fffffffffffff}) {
  if (v is! int || v < min || v > max) {
    throw const FormatException('Invalid Jam integer');
  }
  return v;
}

String jamUuid(Object? v) {
  final s = jamText(v, 36);
  if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(s) ||
      s == '00000000-0000-0000-0000-000000000000') {
    throw const FormatException('Invalid Jam UUID');
  }
  return s;
}

DateTime jamDate(Object? v) {
  final s = jamText(v, 40);
  final d = DateTime.tryParse(s);
  if (d == null || !RegExp(r'T.*(Z|[+-]00:00)$').hasMatch(s)) {
    throw const FormatException('Invalid Jam date');
  }
  return d.toUtc();
}

List<T> _list<T>(Object? v, int max, T Function(Map<String, dynamic>) decode) {
  if (v is! List || v.length > max) {
    throw const FormatException('Invalid Jam list');
  }
  return List.unmodifiable(v.map((e) => decode(jamObject(e))));
}

String newJamId() {
  final r = Random.secure(), b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final s = b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

class JamAdmissionReceipt {
  const JamAdmissionReceipt(
      {required this.requestId,
      required this.sessionId,
      required this.occurrenceId});
  final String requestId, sessionId, occurrenceId;
  factory JamAdmissionReceipt.fromJson(Map<String, dynamic> j) {
    jamKeys(j, ['requestId', 'sessionId', 'occurrenceId']);
    return JamAdmissionReceipt(
        requestId: jamUuid(j['requestId']),
        sessionId: jamText(j['sessionId'], 128, nonempty: true),
        occurrenceId: jamText(j['occurrenceId'], 128, nonempty: true));
  }
  Map<String, Object> toJson() => {
        'requestId': requestId,
        'sessionId': sessionId,
        'occurrenceId': occurrenceId
      };
}

class JamRequest {
  const JamRequest(
      {required this.requestId,
      required this.catalogItemId,
      required this.displayName,
      required this.status,
      this.trackId,
      this.receipt});
  final String requestId, catalogItemId, displayName, status;
  final int? trackId;
  final JamAdmissionReceipt? receipt;
  factory JamRequest.fromJson(Map<String, dynamic> j, {bool host = false}) {
    jamKeys(
        j,
        [
          'requestId',
          'catalogItemId',
          'displayName',
          'status',
          if (host) 'trackId'
        ],
        host ? ['receipt'] : []);
    final status = jamText(j['status'], 16);
    if (!{'pending', 'queued', 'declined', 'uncertain'}.contains(status)) {
      throw const FormatException('Invalid Jam request status');
    }
    final receipt = j['receipt'] == null
        ? null
        : JamAdmissionReceipt.fromJson(jamObject(j['receipt']));
    final id = jamUuid(j['requestId']);
    if (host &&
        ((status == 'queued' && receipt == null) ||
            (receipt != null &&
                (receipt.requestId != id || status != 'queued')))) {
      throw const FormatException('Invalid admission receipt');
    }
    return JamRequest(
        requestId: id,
        catalogItemId: jamUuid(j['catalogItemId']),
        displayName: jamText(j['displayName'], 32),
        status: status,
        trackId: host ? jamInt(j['trackId'], min: 1) : null,
        receipt: receipt);
  }
}

class JamCatalogItem {
  const JamCatalogItem(
      {required this.id,
      required this.title,
      required this.artist,
      required this.durationMs});
  final String id, title, artist;
  final int durationMs;
  factory JamCatalogItem.fromJson(Map<String, dynamic> j) {
    jamKeys(j, ['catalogItemId', 'title', 'artist', 'durationMs']);
    return JamCatalogItem(
        id: jamUuid(j['catalogItemId']),
        title: jamText(j['title'], 200),
        artist: jamText(j['artist'], 200),
        durationMs: jamInt(j['durationMs'], max: 86400000));
  }
}

class JamNowPlaying {
  const JamNowPlaying(
      {required this.title,
      required this.artist,
      required this.playing,
      required this.positionMs,
      required this.durationMs});
  final String title, artist;
  final bool playing;
  final int positionMs, durationMs;
  factory JamNowPlaying.fromJson(Map<String, dynamic> j) {
    jamKeys(j, ['title', 'artist', 'playing', 'positionMs', 'durationMs']);
    if (j['playing'] is! bool) {
      throw const FormatException('Invalid Jam playing');
    }
    return JamNowPlaying(
        title: jamText(j['title'], 200),
        artist: jamText(j['artist'], 200),
        playing: j['playing'] as bool,
        positionMs: jamInt(j['positionMs'], max: 86400000),
        durationMs: jamInt(j['durationMs'], max: 86400000));
  }
  static JamNowPlaying? fromSnapshot(PlaybackSnapshot s) {
    final p = ConnectPlayback.fromSnapshot(s);
    if (p == null) return null;
    return JamNowPlaying(
        title: p.title,
        artist: p.artist,
        playing: p.playing,
        positionMs: p.positionMs.clamp(0, 86400000),
        durationMs: p.durationMs.clamp(0, 86400000));
  }

  Map<String, Object> toJson() => {
        'title': title,
        'artist': artist,
        'playing': playing,
        'positionMs': positionMs,
        'durationMs': durationMs
      };
}

class JamSnapshot {
  JamSnapshot._(
      this.jamId,
      this.version,
      this.state,
      this.serverTime,
      this.expiresAt,
      this.hostSeenAt,
      this.nowPlaying,
      this.catalog,
      this.requests,
      this.hostRequests,
      this.memberCount);
  final String jamId, state;
  final int version, memberCount;
  final DateTime serverTime, expiresAt, hostSeenAt;
  final JamNowPlaying? nowPlaying;
  final List<JamCatalogItem> catalog;
  final List<JamRequest> requests, hostRequests;
  factory JamSnapshot.fromJson(Map<String, dynamic> j, {bool host = false}) {
    jamKeys(j, [
      'jamId',
      'version',
      'state',
      'serverTime',
      'expiresAt',
      'hostSeenAt',
      'nowPlaying',
      'catalog',
      'requests',
      if (host) 'hostRequests',
      if (host) 'memberCount'
    ]);
    final state = jamText(j['state'], 16);
    if (!{'open', 'hostOffline', 'closed', 'expired'}.contains(state)) {
      throw const FormatException('Invalid Jam state');
    }
    final catalog = _list(j['catalog'], 20, JamCatalogItem.fromJson);
    final requests = _list(j['requests'], 50, JamRequest.fromJson);
    final private = host
        ? _list(
            j['hostRequests'], 50, (j) => JamRequest.fromJson(j, host: true))
        : <JamRequest>[];
    if (catalog.isEmpty ||
        catalog.map((e) => e.id).toSet().length != catalog.length ||
        requests.map((e) => e.requestId).toSet().length != requests.length ||
        requests.any((r) => !catalog.any((c) => c.id == r.catalogItemId))) {
      throw const FormatException('Invalid Jam references');
    }
    if (host &&
        (private.length != requests.length ||
            private.any((r) => !requests.any((p) =>
                p.requestId == r.requestId &&
                p.status == r.status &&
                p.catalogItemId == r.catalogItemId &&
                p.displayName == r.displayName)))) {
      throw const FormatException('Invalid host projection');
    }
    return JamSnapshot._(
        jamUuid(j['jamId']),
        jamInt(j['version'], min: 1),
        state,
        jamDate(j['serverTime']),
        jamDate(j['expiresAt']),
        jamDate(j['hostSeenAt']),
        j['nowPlaying'] == null
            ? null
            : JamNowPlaying.fromJson(jamObject(j['nowPlaying'])),
        catalog,
        requests,
        List.unmodifiable(private),
        host ? jamInt(j['memberCount'], max: 16) : 0);
  }
  bool get terminal => state == 'closed' || state == 'expired';
}

Uri validateJamOrigin(String value) {
  final u = Uri.tryParse(value);
  if (u == null ||
      !u.hasAuthority ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment ||
      (u.path.isNotEmpty && u.path != '/') ||
      !(u.scheme == 'https' ||
          (u.scheme == 'http' &&
              {'localhost', '127.0.0.1', '::1'}.contains(u.host)))) {
    throw const FormatException('Enter an HTTPS guest origin');
  }
  return Uri.parse(u.origin);
}

class JamInvite {
  JamInvite._(this._token, this.expiresAt);
  final String _token;
  final DateTime expiresAt;
  factory JamInvite.fromJson(Map<String, dynamic> j) {
    jamKeys(j, ['joinToken', 'inviteExpiresAt']);
    final token = jamText(j['joinToken'], 43);
    try {
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
          base64Url.encode(base64Url.decode('$token=')).replaceAll('=', '') !=
              token) {
        throw const FormatException();
      }
    } catch (_) {
      throw const FormatException('Invalid Jam invitation');
    }
    return JamInvite._(token, jamDate(j['inviteExpiresAt']));
  }
  Uri link(Uri origin, String jamId) {
    final base = validateJamOrigin(origin.toString());
    jamUuid(jamId);
    return base.replace(
        path: '/join',
        fragment:
            Uri(queryParameters: {'jamId': jamId, 'invite': _token}).query);
  }

  @override
  String toString() => 'JamInvite';
}
