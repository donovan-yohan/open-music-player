import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/performance/performance_fixture_io.dart';

final provenance = <String, String>{
  'source_commit': 'a' * 40,
  'source_tree': 'b' * 40,
  'source_manifest_sha256': 'c' * 64,
  'run_id': 'run-01',
};
Map<String, Object?> report() => {
      'schema': 'soundq.flutter.actual-root.profile.v1',
      ...provenance,
      'pid': 1,
      'build_mode': 'profile',
      'entrypoint': 'production.main',
      'route': '/library',
      'status': 'failed',
      'hold': 'journey-failed',
      'preferences': 'ephemeral-plugin-adapter',
      'storage': 'EPHEMERAL STORAGE',
      'artwork': 'placeholder-only-memory-cache',
      'excluded_operations': [
        'disk',
        'downloads',
        'playback-cache',
        'artwork-acquisition',
        'audio',
      ],
      'audio': 'unavailable-native-readback-not-proven',
      'full_app_accepted': false,
      'framework_error_count': 0,
      'loaded_list_slots': 0,
      'witnessed_row_ids': <int>[],
      'physical_viewport': [1280.0, 800.0],
      'scale': 2.0,
      'clock': 'flutter-frame-timing',
      'boundary_clock': 'SchedulerBinding.currentSystemFrameTimeStamp',
      'boundary_frames_requested': true,
      'windows': <Map<String, Object?>>[],
      'scroll_legs': <Map<String, Object?>>[],
      'rawFrames': <Map<String, int>>[],
    };

void main() {
  test(
    'report rejects unknown keys source mutation nonfinite values and oversize',
    () {
      expect(PerformanceFixture.encodeReport(report(), provenance), isNotEmpty);
      for (final mutation in <Map<String, Object?>>[
        {'email': 'private'},
        {'report_token': 'd' * 64},
        {'output': '/personal'},
        {'source_commit': 'b' * 40},
        {'scale': double.nan},
        {'scale': double.infinity},
        {
          'physical_viewport': [double.negativeInfinity, 800],
        },
        {
          'rawFrames': [
            {'password': 'private'},
          ],
        },
        {'status': 'success'},
        {'full_app_accepted': true},
      ]) {
        expect(
          () => PerformanceFixture.encodeReport({
            ...report(),
            ...mutation,
          }, provenance),
          throwsStateError,
        );
      }
      final large = report()
        ..['witnessed_row_ids'] = List.filled(1800000, 1234567890);
      expect(
        () => PerformanceFixture.encodeReport(large, provenance),
        throwsStateError,
      );
    },
  );
  test(
    'fixed report transport requires exact persisted acknowledgement',
    () async {
      for (final mode in [
        'ok',
        'wrong-run',
        'wrong-hash',
        'not-persisted',
        'redirect',
        'oversize',
        'invalid-json',
        'disconnect',
      ]) {
        final client = _Client(mode);
        final action = HttpOverrides.runZoned(
          () => PerformanceFixture.sendReport(
            report(),
            provenance: provenance,
            reportToken: 'd' * 64,
          ),
          createHttpClient: (_) => client,
        );
        if (mode == 'ok') {
          await action;
        } else {
          await expectLater(
            action,
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'fixture-report-export-failed',
              ),
            ),
          );
        }
        expect(client.uri.toString(), 'http://127.0.0.1:54762/report');
        expect(client.proxy!(client.uri!), 'DIRECT');
        expect(client.connectionTimeout, const Duration(seconds: 5));
        expect(client.request.followRedirects, isFalse);
        expect(
          client.request.headers.values['authorization'],
          'Bearer ${'d' * 64}',
        );
        expect(client.request.contentLength, client.request.body.length);
        expect(client.closed, isTrue);
        final body = utf8.decode(client.request.body);
        expect(body, isNot(contains('report_token')));
        expect(body, isNot(contains('password')));
      }
    },
  );
}

class _Client implements HttpClient {
  _Client(String mode) : request = _Request(mode);
  final _Request request;
  Uri? uri;
  bool closed = false;
  String Function(Uri)? proxy;
  @override
  Duration? connectionTimeout;
  @override
  set findProxy(String Function(Uri)? value) => proxy = value;
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    uri = url;
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final values = <String, Object>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.mode);
  final String mode;
  final body = <int>[];
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int contentLength = -1;
  @override
  void add(List<int> bytes) => body.addAll(bytes);
  @override
  Future<HttpClientResponse> close() async {
    if (mode == 'disconnect') throw const SocketException('test-disconnect');
    final ack = {
      'run_id': mode == 'wrong-run' ? 'other' : 'run-01',
      'sha256':
          mode == 'wrong-hash' ? '0' * 64 : sha256.convert(body).toString(),
      'persisted': mode != 'not-persisted',
    };
    final bytes = mode == 'oversize'
        ? List.filled(4097, 32)
        : utf8.encode(mode == 'invalid-json' ? 'invalid' : jsonEncode(ack));
    return _Response(mode == 'redirect' ? 302 : 200, bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.bytes);
  @override
  final int statusCode;
  final List<int> bytes;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream.value(bytes).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
