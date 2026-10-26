import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite/sqflite.dart';

import '../api/api_endpoint.dart';
import 'fixture_tokens.dart';

/// EPHEMERAL STORAGE renderer diagnostic. No app-side input/output files.
/// Compiler/artifact/source-byte verification belongs to the external owner.
class PerformanceFixture {
  PerformanceFixture._(this._descriptor);
  static PerformanceFixture? active;
  final Map<String, String> _descriptor;
  String get email => _descriptor['email']!;
  String get password => _descriptor['password']!;
  Map<String, String> get provenance => {
        for (final key in [
          'source_commit',
          'source_tree',
          'source_manifest_sha256',
          'run_id',
        ])
          key: _descriptor[key]!,
      };
  late final _preferences = InMemorySharedPreferencesStore.empty();
  late final _paths = FixturePaths();
  late final CacheManager artworkCache = CacheManager(
    Config(
      'soundq-fixture-ephemeral',
      repo: NonStoringObjectProvider(),
      fileSystem: MemoryCacheSystem(),
    ),
  );

  static void verifyIsolation() {
    if (!performanceFixtureEnabled) return;
    final fixture = active;
    if (fixture == null ||
        !identical(
          SharedPreferencesStorePlatform.instance,
          fixture._preferences,
        ) ||
        !identical(PathProviderPlatform.instance, fixture._paths) ||
        !identical(
          CachedNetworkImageProvider.defaultCacheManager,
          fixture.artworkCache,
        )) {
      throw StateError('fixture-isolation-lost');
    }
  }

  // A legacy default lookup can never discover a personal path. Nothing creates
  // this impossible root; the sole OfflineDatabase explicitly opens :memory:.
  static const refusedDatabaseRoot = '/dev/null/soundq-fixture-no-disk';
  static Future<void> configureDatabases() async {
    if (!performanceFixtureEnabled) return;
    verifyIsolation();
    await configureDatabaseRoot(databaseFactory);
  }

  @visibleForTesting
  static Future<void> configureDatabaseRoot(DatabaseFactory factory) async {
    await factory.setDatabasesPath(refusedDatabaseRoot);
    if (await factory.getDatabasesPath() != refusedDatabaseRoot) {
      throw StateError('fixture-database-isolation-lost');
    }
  }

  static Future<void> preflight() async {
    if (!performanceFixtureEnabled) return;
    if (active != null) throw StateError('fixture-already-initialized');
    var stage = 'profile';
    try {
      if (!Platform.isMacOS || !kProfileMode) {
        throw StateError('fixture-macos-profile-required');
      }
      final environment = Platform.environment;
      stage = 'descriptor';
      if (environment['SOUNDQ_FIXTURE_DISPOSABLE'] != '1') {
        throw StateError('fixture-disposable-ack-required');
      }
      final descriptor = validateDescriptor(
        environment['SOUNDQ_FIXTURE_DESCRIPTOR'] ?? '',
        endpoint: const String.fromEnvironment('OMP_API_BASE_URL'),
        resolvedEndpoint: ApiEndpoint.baseUrl,
        commit: const String.fromEnvironment('SOUNDQ_FIXTURE_SOURCE_COMMIT'),
        tree: const String.fromEnvironment('SOUNDQ_FIXTURE_SOURCE_TREE'),
        manifestHash: const String.fromEnvironment(
          'SOUNDQ_FIXTURE_SOURCE_SHA256',
        ),
      );
      stage = 'adapters';
      final fixture = PerformanceFixture._(descriptor);
      SharedPreferencesStorePlatform.instance = fixture._preferences;
      PathProviderPlatform.instance = fixture._paths;
      CachedNetworkImageProvider.defaultCacheManager = fixture.artworkCache;
      installFixtureTokens();
      active = fixture;
    } catch (_) {
      // Never log the descriptor, credentials, token or exception text.
      stderr.writeln('soundq-fixture-preflight-refused:$stage');
      throw StateError('fixture-preflight-refused');
    }
  }

  @visibleForTesting
  static Map<String, String> validateDescriptor(
    String raw, {
    required String endpoint,
    required String resolvedEndpoint,
    required String commit,
    required String tree,
    required String manifestHash,
  }) {
    try {
      if (utf8.encode(raw).length > 16 * 1024) throw StateError('size');
      final value = jsonDecode(raw);
      const keys = {
        'schema',
        'endpoint',
        'email',
        'password',
        'run_id',
        'source_commit',
        'source_tree',
        'source_manifest_sha256',
        'report_token',
      };
      if (value is! Map<String, dynamic> ||
          value.length != keys.length ||
          !value.keys.toSet().containsAll(keys) ||
          value.values.any((v) => v is! String) ||
          // Token count also refuses duplicate JSON keys discarded by jsonDecode.
          RegExp(r'"(?:[^"\\]|\\.)*"|[{}:,]|\S').allMatches(raw).length !=
              keys.length * 4 + 1) {
        throw StateError('shape');
      }
      final descriptor = value.cast<String, String>();
      validateIdentity(
        endpoint: endpoint,
        resolvedEndpoint: resolvedEndpoint,
        commit: commit,
        tree: tree,
        manifestHash: manifestHash,
        run: descriptor['run_id']!,
      );
      if (descriptor['schema'] != 'soundq.flutter.fixture.process.v1' ||
          descriptor['endpoint'] != endpoint ||
          descriptor['source_commit'] != commit ||
          descriptor['source_tree'] != tree ||
          descriptor['source_manifest_sha256'] != manifestHash ||
          descriptor['email']!.isEmpty ||
          utf8.encode(descriptor['email']!).length > 320 ||
          descriptor['password']!.isEmpty ||
          utf8.encode(descriptor['password']!).length > 4096 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(descriptor['report_token']!)) {
        throw StateError('value');
      }
      return Map.unmodifiable(descriptor);
    } catch (_) {
      throw StateError('fixture-descriptor-invalid');
    }
  }

  @visibleForTesting
  static void validateIdentity({
    required String endpoint,
    required String resolvedEndpoint,
    required String commit,
    required String tree,
    required String manifestHash,
    required String run,
  }) {
    if (endpoint != 'http://127.0.0.1:54761/api/v1' ||
        resolvedEndpoint != endpoint ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit) ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(tree) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(manifestHash) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$').hasMatch(run)) {
      throw StateError('fixture-identity-invalid');
    }
  }

  Future<String> databasePath() async => inMemoryDatabasePath;
  Future<String> downloadDirectory() async =>
      throw StateError('fixture-filesystem-refused');
  Future<String> cacheDirectory() async =>
      throw StateError('fixture-filesystem-refused');

  Future<void> exportReport(Map<String, Object?> report) => sendReport(
        report,
        provenance: provenance,
        reportToken: _descriptor['report_token']!,
      );

  /// Fixed destination, bounded request/ack, no proxy or redirect. A successful
  /// journey is not exported successfully until durable custody is acknowledged.
  @visibleForTesting
  static Future<void> sendReport(
    Map<String, Object?> report, {
    required Map<String, String> provenance,
    required String reportToken,
  }) async {
    HttpClient? client;
    try {
      final body = encodeReport(report, provenance);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(reportToken)) {
        throw StateError('token');
      }
      client = HttpClient();
      client.findProxy = (_) => 'DIRECT';
      client.connectionTimeout = const Duration(seconds: 5);
      await (() async {
        final request = await client!.postUrl(
          Uri.parse('http://127.0.0.1:54762/report'),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $reportToken',
        );
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) throw StateError('status');
        final ack = <int>[];
        await for (final chunk in response) {
          if (ack.length + chunk.length > 4096) throw StateError('ack-size');
          ack.addAll(chunk);
        }
        validateAcknowledgement(
          ack,
          provenance['run_id']!,
          sha256.convert(body).toString(),
        );
      })()
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      stderr.writeln('soundq-fixture-report-export-failed');
      throw StateError('fixture-report-export-failed');
    } finally {
      client?.close(force: true);
    }
  }

  @visibleForTesting
  static List<int> encodeReport(
    Map<String, Object?> report,
    Map<String, String> provenance,
  ) {
    const keys = {
      'schema',
      'source_commit',
      'source_tree',
      'source_manifest_sha256',
      'run_id',
      'pid',
      'build_mode',
      'entrypoint',
      'route',
      'status',
      'hold',
      'preferences',
      'storage',
      'artwork',
      'excluded_operations',
      'audio',
      'full_app_accepted',
      'framework_error_count',
      'loaded_list_slots',
      'witnessed_row_ids',
      'physical_viewport',
      'scale',
      'clock',
      'boundary_clock',
      'boundary_frames_requested',
      'windows',
      'scroll_legs',
      'rawFrames',
    };
    if (report.length != keys.length ||
        !report.keys.toSet().containsAll(keys) ||
        report['schema'] != 'soundq.flutter.actual-root.profile.v1' ||
        provenance.entries.any((e) => report[e.key] != e.value)) {
      throw StateError('fixture-report-invalid');
    }
    const fixed = {
      'build_mode': 'profile',
      'entrypoint': 'production.main',
      'route': '/library',
      'preferences': 'ephemeral-plugin-adapter',
      'storage': 'EPHEMERAL STORAGE',
      'artwork': 'placeholder-only-memory-cache',
      'audio': 'unavailable-native-readback-not-proven',
      'full_app_accepted': false,
      'clock': 'flutter-frame-timing',
      'boundary_clock': 'SchedulerBinding.currentSystemFrameTimeStamp',
      'boundary_frames_requested': true,
    };
    void require(bool valid) {
      if (!valid) throw StateError('fixture-report-invalid');
    }

    require(fixed.entries.every((e) => report[e.key] == e.value));
    require(['failed', 'completed-diagnostic'].contains(report['status']));
    require(
      [
        'journey-incomplete',
        'journey-failed',
        'audio-native-readback-unavailable',
        'renderer-population-unavailable',
        'fixture-framework-error',
      ].contains(report['hold']),
    );
    require(
      jsonEncode(report['excluded_operations']) ==
          jsonEncode([
            'disk',
            'downloads',
            'playback-cache',
            'artwork-acquisition',
            'audio',
          ]),
    );
    for (final key in ['pid', 'framework_error_count', 'loaded_list_slots']) {
      require(report[key] is int && (report[key] as int) >= 0);
    }
    bool finite(Object? v) => v is num && v.isFinite;
    require(finite(report['scale']) && (report['scale'] as num) > 0);
    final viewport = report['physical_viewport'];
    require(viewport is List && viewport.length == 2 && viewport.every(finite));
    final rows = report['witnessed_row_ids'];
    require(rows is List && rows.every((v) => v is int));
    void records(
      String key,
      Set<String> fields,
      bool Function(Map<String, Object?>) valid,
    ) {
      final value = report[key];
      require(value is List);
      for (final row in value as List) {
        require(row is Map<String, Object?>);
        final record = row as Map<String, Object?>;
        require(
          record.length == fields.length &&
              record.keys.toSet().containsAll(fields),
        );
        require(valid(record));
      }
    }

    records(
        'rawFrames',
        {
          'frameNumber',
          'vsyncStart',
          'buildStart',
          'buildFinish',
          'rasterStart',
          'rasterFinish',
          'rasterFinishWallTime',
          'uiUs',
          'rasterUs',
          'totalSpanUs',
          'vsyncOverheadUs',
        },
        (r) => r.values.every((v) => v is int));
    records(
      'scroll_legs',
      {'target', 'offset', 'elapsed_us', 'requested_us'},
      (r) =>
          finite(r['target']) &&
          finite(r['offset']) &&
          r['elapsed_us'] is int &&
          r['requested_us'] is int,
    );
    records(
      'windows',
      {
        'name',
        'clock',
        'start',
        'end',
        'audio_active',
        'cursor',
        'scroll_start',
        'scroll_end',
        'scroll_max_extent',
        'scroll_distance',
        'motion',
        'frame_count',
      },
      (r) =>
          [
            'populated-idle',
            'populated-scroll-audio-unavailable',
          ].contains(r['name']) &&
          r['clock'] == 'flutter-frame-timing' &&
          r['start'] is int &&
          r['end'] is int &&
          r['frame_count'] is int &&
          r['audio_active'] == false &&
          r['cursor'] == null &&
          r['motion'] is bool &&
          [
            'scroll_start',
            'scroll_end',
            'scroll_max_extent',
            'scroll_distance',
          ].every((key) => finite(r[key])),
    );
    final body = utf8.encode(jsonEncode(report));
    if (body.length > 16 * 1024 * 1024) {
      throw StateError('fixture-report-too-large');
    }
    return body;
  }

  @visibleForTesting
  static void validateAcknowledgement(
    List<int> bytes,
    String run,
    String hash,
  ) {
    if (bytes.length > 4096) throw StateError('fixture-report-ack-invalid');
    final ack = jsonDecode(utf8.decode(bytes));
    if (ack is! Map<String, dynamic> ||
        RegExp(r'"(?:[^"\\]|\\.)*"|true|false|[{}:,]|\S')
                .allMatches(utf8.decode(bytes))
                .length !=
            13 ||
        ack.length != 3 ||
        ack['run_id'] != run ||
        ack['sha256'] != hash ||
        ack['persisted'] != true) {
      throw StateError('fixture-report-ack-invalid');
    }
  }
}

/// Refuse every path_provider destination, including Android-only methods.
@visibleForTesting
class FixturePaths extends PathProviderPlatform {
  Never _refuse() => throw StateError('fixture-filesystem-refused');
  @override
  Future<String?> getTemporaryPath() async => _refuse();
  @override
  Future<String?> getApplicationSupportPath() async => _refuse();
  @override
  Future<String?> getApplicationDocumentsPath() async => _refuse();
  @override
  Future<String?> getApplicationCachePath() async => _refuse();
  @override
  Future<String?> getLibraryPath() async => _refuse();
  @override
  Future<String?> getDownloadsPath() async => _refuse();
  @override
  Future<String?> getExternalStoragePath() async => _refuse();
  @override
  Future<List<String>?> getExternalCachePaths() async => _refuse();
  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async =>
      _refuse();
}
