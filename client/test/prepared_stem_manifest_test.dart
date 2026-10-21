import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart'; // Installed transitive dependency; no pub get.
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/prepared_stem_manifest.dart';

// ignore_for_file: depend_on_referenced_packages

const preparedModel = 'audio-separator-htdemucs-ft-4s-v1+lr4-180';
const preparedSet = 'stems5-hybrid-v1';
final preparedNow = DateTime.utc(2026, 10, 21);
final preparedSource = 'sha256:${'a' * 64}';
const preparedRoles = ['vocals', 'melody', 'bass', 'kick', 'perc', 'drums'];
List<int> preparedBytes(String channel) =>
    utf8.encode('encoded-$channel-bytes');

Map<String, dynamic> preparedStatus({String? objectOrigin}) {
  final objects = [
    for (final channel in preparedRoles)
      <String, dynamic>{
        'channel': channel,
        'key': 'stems/42/$preparedModel/${'a' * 64}/g7/'
            '${channel == 'melody' ? 'other' : channel}/'
            '${sha256.convert(preparedBytes(channel))}.opus',
        'sha256': sha256.convert(preparedBytes(channel)).toString(),
        'bytes': preparedBytes(channel).length,
        'duration_ms': 1000,
        'derivation': ['kick', 'perc'].contains(channel)
            ? 'dsp-crossover-lr4-180'
            : 'separator',
        'sample_frames': 48000,
        'sample_rate_hz': 48000,
        'channels': 2,
        'origin_frame': 0,
        'delay_frames': 0,
        'encoder_delay_frames': 312,
        'delay_provenance': 'ffmpeg-ogg-opus-preskip-end-trim-v1',
      }
  ];
  final artifacts = {
    'objects': objects,
    'codec': {'name': 'libopus', 'sample_rate_hz': 48000, 'channels': 2},
    'null_sum': {
      'pair': ['kick', 'perc'],
      'against': 'drums',
      'passed': true,
      'residual_db': -120,
      'threshold_db': -80,
    },
    'energy': {
      'frame_hz': 80,
      'frame_count': 80,
      'encoding': 'uint8-linear',
      'channels': {
        for (final channel in preparedRoles)
          channel: base64Encode(List.filled(80, 0))
      },
    },
  };
  return {
    'trackId': 42,
    'channelSet': preparedSet,
    'stemModelVersion': preparedModel,
    'schemaVersion': 1,
    'generation': 7,
    'status': 'ready',
    'sourceFileHash': preparedSource,
    'artifacts': artifacts,
    'publishedManifest': {
      'track_id': 42,
      'channel_set': preparedSet,
      'stem_model_version': preparedModel,
      'schema_version': 1,
      'generation': 7,
      'source_file_hash': preparedSource,
      'source_storage_key': 'tracks/canonical.mp3',
      'duration_ms': 1000,
      'provenance': {
        'worker': 'stemsep-worker',
        'worker_version': '2026-08-30-1'
      },
      'artifacts': artifacts,
    },
    'memberDownloads': [
      for (final member in objects)
        {
          'channel': member['channel'],
          'key': member['key'],
          'sha256': member['sha256'],
          'bytes': member['bytes'],
          'url':
              '${objectOrigin ?? 'https://objects.invalid'}/${member['key']}?signature=one',
          'expiresAt':
              preparedNow.add(const Duration(minutes: 10)).toIso8601String(),
        }
    ],
  };
}

PreparedStemManifest parsePrepared(Map<String, dynamic> body,
        {bool allowLoopbackHttp = false}) =>
    PreparedStemManifest.fromStatusJson(body,
        expectedTrackId: 42,
        channelSet: preparedSet,
        expectedSourceFileHash: preparedSource,
        expectedGeneration: 7,
        now: preparedNow,
        allowLoopbackHttp: allowLoopbackHttp);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rejects incomplete, mismatched, unsafe or unaligned publications', () {
    final mutations = <String, void Function(Map<String, dynamic>)>{
      'missing member': (s) =>
          (s['publishedManifest']['artifacts']['objects'] as List).removeLast(),
      'duplicate member': (s) => s['publishedManifest']['artifacts']['objects']
          [5] = s['publishedManifest']['artifacts']['objects'][0],
      'missing download': (s) => (s['memberDownloads'] as List).removeLast(),
      'duplicate download': (s) =>
          s['memberDownloads'][5] = s['memberDownloads'][0],
      'download hash': (s) => s['memberDownloads'][0]['sha256'] = 'b' * 64,
      'download bytes': (s) => s['memberDownloads'][0]['bytes'] = 1,
      'download key': (s) => s['memberDownloads'][0]['key'] = 'unrelated',
      'wrong model': (s) =>
          s['publishedManifest']['stem_model_version'] = 'unknown',
      'wrong source': (s) =>
          s['publishedManifest']['source_file_hash'] = 'sha256:${'b' * 64}',
      'wrong generation': (s) => s['publishedManifest']['generation'] = 8,
      'wrong schema': (s) => s['schemaVersion'] = 2,
      'fractional identity': (s) => s['publishedManifest']['track_id'] = 42.0,
      'wrong worker': (s) =>
          s['publishedManifest']['provenance']['worker_version'] = 'old',
      'expired': (s) =>
          s['memberDownloads'][0]['expiresAt'] = preparedNow.toIso8601String(),
      'relative URL': (s) => s['memberDownloads'][0]['url'] = '/relative',
      'unsafe scheme': (s) =>
          s['memberDownloads'][0]['url'] = 'file:///etc/passwd',
      'nonlocal HTTP': (s) =>
          s['memberDownloads'][0]['url'] = 'http://objects.invalid/stem',
      'credential URL': (s) => s['memberDownloads'][0]['url'] =
          'https://dummy-user:dummy-pass@objects.invalid/stem',
      'origin': (s) =>
          s['publishedManifest']['artifacts']['objects'][0]['origin_frame'] = 1,
      'delay': (s) =>
          s['publishedManifest']['artifacts']['objects'][0]['delay_frames'] = 1,
      'priming mismatch': (s) => s['publishedManifest']['artifacts']['objects']
          [0]['encoder_delay_frames'] = 313,
      'missing delay': (s) => s['publishedManifest']['artifacts']['objects'][0]
          .remove('encoder_delay_frames'),
      'rate': (s) => s['publishedManifest']['artifacts']['objects'][0]
          ['sample_rate_hz'] = 44100,
      'channels': (s) =>
          s['publishedManifest']['artifacts']['objects'][0]['channels'] = 1,
      'frames': (s) => s['publishedManifest']['artifacts']['objects'][0]
          ['sample_frames'] = 47999,
      'zero bytes': (s) =>
          s['publishedManifest']['artifacts']['objects'][0]['bytes'] = 0,
      'nonfinite bytes': (s) => s['publishedManifest']['artifacts']['objects']
          [0]['bytes'] = double.infinity,
      'fractional frames': (s) => s['publishedManifest']['artifacts']['objects']
          [0]['sample_frames'] = 48000.1,
      'member path': (s) =>
          s['publishedManifest']['artifacts']['objects'][0]['path'] = '/tmp/no',
      'alias key': (s) => s['publishedManifest']['artifacts']['objects'][1]
          ['key'] = 'stems/42/melody.opus',
      'duration': (s) => s['publishedManifest']['duration_ms'] = 2,
      'codec': (s) =>
          s['publishedManifest']['artifacts']['codec']['name'] = 'aac',
      'derivation': (s) => s['publishedManifest']['artifacts']['objects'][3]
          ['derivation'] = 'separator',
      'null sum': (s) =>
          s['publishedManifest']['artifacts']['null_sum']['passed'] = false,
      'energy is not PCM': (s) => s['publishedManifest']['artifacts']['objects']
          [0]['sample_frames'] = 80,
      'energy count': (s) =>
          s['publishedManifest']['artifacts']['energy']['frame_count'] = 48000,
      'energy channels': (s) => s['publishedManifest']['artifacts']['energy']
              ['channels']
          .remove('drums'),
      'energy bytes': (s) => s['publishedManifest']['artifacts']['energy']
          ['channels']['vocals'] = 'AA==',
      'energy base64': (s) => s['publishedManifest']['artifacts']['energy']
          ['channels']['vocals'] = '!!!',
      'energy rate': (s) =>
          s['publishedManifest']['artifacts']['energy']['frame_hz'] = 40,
    };
    for (final entry in mutations.entries) {
      final body = preparedStatus();
      entry.value(body);
      expect(() => parsePrepared(body), throwsFormatException,
          reason: entry.key);
    }
  });
  test('loopback HTTP is explicitly opted in and URLs do not affect identity',
      () {
    final local = preparedStatus(objectOrigin: 'http://127.0.0.1:18888');
    expect(() => parsePrepared(local), throwsFormatException);
    expect(parsePrepared(local, allowLoopbackHttp: true).identity,
        parsePrepared(preparedStatus()).identity);
    final first = parsePrepared(preparedStatus());
    expect(() => first.members.clear(), throwsUnsupportedError);
    expect(() => first.channels.clear(), throwsUnsupportedError);
  });
  test('member identity is content-bound and independent of JSON ordering', () {
    final original = parsePrepared(preparedStatus());
    final reordered = preparedStatus();
    reordered['publishedManifest']['artifacts']['objects'] =
        (reordered['publishedManifest']['artifacts']['objects'] as List)
            .reversed
            .toList();
    final result = parsePrepared(reordered);
    expect(result.members.keys, preparedRoles);
    expect(result.identity, original.identity);
    final changed = preparedStatus();
    final object = changed['publishedManifest']['artifacts']['objects'][0];
    final before = object['sha256'] as String;
    final key = (object['key'] as String).replaceFirst(before, 'b' * 64);
    object['sha256'] = 'b' * 64;
    object['key'] = key;
    changed['memberDownloads'][0]['sha256'] = 'b' * 64;
    changed['memberDownloads'][0]['key'] = key;
    expect(parsePrepared(changed).identity, isNot(original.identity));
  });
  test('known four-channel manifest keeps other distinct from hybrid melody',
      () {
    final body = preparedStatus();
    const set = PreparedStemManifest.fourChannelSet;
    const model = 'audio-separator-htdemucs-ft-4s-v1';
    final published = body['publishedManifest'];
    body['channelSet'] = set;
    body['stemModelVersion'] = model;
    published['channel_set'] = set;
    published['stem_model_version'] = model;
    final artifacts = published['artifacts'];
    (artifacts['objects'] as List)
        .removeWhere((m) => ['kick', 'perc'].contains(m['channel']));
    (body['memberDownloads'] as List)
        .removeWhere((m) => ['kick', 'perc'].contains(m['channel']));
    final energy = artifacts['energy']['channels'] as Map;
    energy['other'] = energy.remove('melody');
    energy.remove('kick');
    energy.remove('perc');
    for (final member in artifacts['objects']) {
      if (member['channel'] == 'melody') member['channel'] = 'other';
      member['key'] =
          (member['key'] as String).replaceFirst(preparedModel, model);
    }
    for (final download in body['memberDownloads']) {
      if (download['channel'] == 'melody') download['channel'] = 'other';
      download['key'] =
          (download['key'] as String).replaceFirst(preparedModel, model);
    }
    final result = PreparedStemManifest.fromStatusJson(body,
        expectedTrackId: 42,
        channelSet: set,
        expectedSourceFileHash: preparedSource,
        now: preparedNow);
    expect(result.channels, ['vocals', 'drums', 'bass', 'other']);
    expect(result.members.length, 4);
    expect(result.members['other']!.key, contains('/other/'));
  });
  test(
      'request identity rejects unsupported or malformed values before API access',
      () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = PreparedAdapter((options) {
        requests.add(options);
        return preparedStatus();
      });
    final service = StemsService(ApiClient(dio: dio));
    await expectLater(
        service.getPreparedManifest(42,
            channelSet: 'stems5-unknown',
            expectedSourceFileHash: preparedSource),
        throwsFormatException);
    await expectLater(
        service.getPreparedManifest(42,
            expectedSourceFileHash: 'SHA256:${'a' * 64}'),
        throwsFormatException);
    await expectLater(
        service.getPreparedManifest(0, expectedSourceFileHash: preparedSource),
        throwsFormatException);
    await expectLater(
        service.getPreparedManifest(42,
            expectedSourceFileHash: preparedSource, expectedGeneration: 0),
        throwsFormatException);
    expect(requests, isEmpty);
  });
  test(
      'authenticated typed resolution requests signed URLs without changing UI DTO',
      () async {
    FlutterSecureStorage.setMockInitialValues({'access_token': 'test-token'});
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..httpClientAdapter = PreparedAdapter((options) {
        requests.add(options);
        return preparedStatus();
      });
    final service = StemsService(ApiClient(dio: dio));
    final manifest = await service.getPreparedManifest(42,
        expectedSourceFileHash: preparedSource,
        expectedGeneration: 7,
        now: preparedNow);
    expect(requests.single.uri.path, endsWith('/tracks/42/stems'));
    expect(requests.single.uri.queryParameters,
        {'channelSet': preparedSet, 'includeUrls': '1'});
    expect(requests.single.headers['Authorization'], 'Bearer test-token');
    expect(manifest.channels, ['vocals', 'melody', 'bass', 'kick', 'perc']);
    expect(manifest.members.length,
        6); // drums is the null-sum reference, not a sixth DJ bus.
    expect(manifest.members['melody']!.key, contains('/other/'));
    expect(manifest.sampleFrames, 48000); // Not energy.frame_count = 80.
    expect(manifest.sampleRateHz, 48000);
    expect(manifest.members['vocals']!.encoderDelayFrames, 312);
    final ui = await service.getTrackStems(42);
    expect(requests.last.uri.queryParameters, {'channelSet': preparedSet});
    expect(ui.channels, preparedRoles);
  });
}

class PreparedAdapter implements HttpClientAdapter {
  PreparedAdapter(this.body);
  final Map<String, dynamic> Function(RequestOptions) body;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      ResponseBody.fromString(jsonEncode(body(options)), 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      });
  @override
  void close({bool force = false}) {}
}
