import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/storage/offline_database.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/track.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('analysis backfill never sends null SQLite where arguments', () async {
    final database = _RecordingDatabase();
    final offline = OfflineDatabase(databaseProvider: () async => database);
    final track = Track(
      id: 44,
      identityHash: 'track-44',
      title: 'iPod Touch',
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: const TrackAnalysisSummary(
          bpm: AnalysisValue(value: 141.18),
          camelot: AnalysisValue(value: '11A'),
        ),
        updatedAt: DateTime.utc(2026, 1, 2),
      ),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

    await offline.updateTrackAnalysis(track);

    expect(database.table, 'tracks');
    expect(database.where, contains('analysis_overrides IS NOT NULL'));
    expect(database.where, contains('analysis_updated_at_us <= ?'));
    expect(database.whereArgs, isNot(contains(null)));
    expect(database.whereArgs, containsAll(<Object>[44, 'analyzed']));
  });

  test('v3 database migrates and backfills compact downloaded metadata',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('omp_offline_v3_');
    final path = '${directory.path}/open_music_player.db';
    addTearDown(() async {
      await databaseFactoryFfi.deleteDatabase(path);
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final v3 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE tracks (
              id INTEGER PRIMARY KEY,
              identity_hash TEXT NOT NULL,
              title TEXT NOT NULL,
              artist TEXT,
              album TEXT,
              duration_ms INTEGER,
              version TEXT,
              mb_recording_id TEXT,
              mb_release_id TEXT,
              mb_artist_id TEXT,
              mb_verified INTEGER DEFAULT 0,
              source_url TEXT,
              source_type TEXT,
              storage_key TEXT,
              file_size_bytes INTEGER,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE library_tracks (
              track_id INTEGER PRIMARY KEY,
              added_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE downloaded_tracks (
              track_id INTEGER PRIMARY KEY,
              local_path TEXT NOT NULL,
              file_size_bytes INTEGER NOT NULL,
              status TEXT NOT NULL,
              progress REAL,
              error TEXT,
              downloaded_at TEXT NOT NULL,
              expected_size_bytes INTEGER,
              etag TEXT,
              storage_key_version TEXT
            )
          ''');
          await db.insert('tracks', {
            'id': 44,
            'identity_hash': 'track-44',
            'title': 'iPod Touch',
            'artist': 'Ninajirachi',
            'duration_ms': 196000,
            'created_at': '2026-01-01T00:00:00.000Z',
            'updated_at': '2026-01-01T00:00:00.000Z',
          });
          await db.insert('downloaded_tracks', {
            'track_id': 44,
            'local_path': '/tmp/44.mp3',
            'file_size_bytes': 1024,
            'status': 'completed',
            'progress': 1.0,
            'downloaded_at': '2026-01-02T00:00:00.000Z',
          });
        },
      ),
    );
    await v3.close();

    final offline = OfflineDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePathProvider: () async => path,
    );
    final migrated = await offline.database;
    addTearDown(migrated.close);

    final version = await migrated.rawQuery('PRAGMA user_version');
    expect(version.single.values.single, 6);
    final columns = await migrated.rawQuery('PRAGMA table_info(tracks)');
    expect(
      columns.map((column) => column['name']),
      containsAll([
        'analysis_status',
        'analysis_summary',
        'analysis_overrides',
        'analysis_updated_at',
        'analysis_updated_at_us',
      ]),
    );

    final analysisRevision = DateTime.parse('2026-01-03T04:05:06.123Z');
    final analyzed = Track(
      id: 44,
      identityHash: 'track-44',
      title: 'iPod Touch',
      artist: 'Ninajirachi',
      durationMs: 196000,
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: const TrackAnalysisSummary(
          bpm: AnalysisValue(value: 141.18),
          camelot: AnalysisValue(value: '11A'),
          waveform: WaveformSummary(
            sampleCount: 4,
            peaks: [0.1, 0.5, 0.9, 0.2],
          ),
        ),
        updatedAt: analysisRevision,
      ),
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    await offline.updateTrackAnalysis(analyzed);

    final local = await offline.getLibraryTracksWithCount(downloadedOnly: true);
    expect(local.total, 1);
    expect(local.tracks.single.analysis?.summary?.bpm?.numericValue, 141.18);
    expect(local.tracks.single.analysis?.summary?.camelot?.textValue, '11A');
    expect(local.tracks.single.analysis?.summary?.waveform, isNull);
    expect(local.tracks.single.analysis?.updatedAt, analysisRevision);

    await offline.updateTrackAnalysis(
      analyzed.copyWith(
        analysis: TrackAnalysis(
          status: TrackAnalysisStatus.analyzed,
          summary: const TrackAnalysisSummary(
            bpm: AnalysisValue(value: 99),
          ),
          updatedAt: analysisRevision.subtract(const Duration(microseconds: 1)),
        ),
      ),
    );
    final afterStaleWrite =
        await offline.getLibraryTracksWithCount(downloadedOnly: true);
    expect(
      afterStaleWrite.tracks.single.analysis?.summary?.bpm?.numericValue,
      141.18,
    );
    expect(afterStaleWrite.tracks.single.analysis?.updatedAt, analysisRevision);

    await offline.insertTrack(
      analyzed.copyWith(
        analysis: TrackAnalysis(
          status: TrackAnalysisStatus.analyzed,
          summary: const TrackAnalysisSummary(
            bpm: AnalysisValue(value: 88),
          ),
          updatedAt: analysisRevision.subtract(const Duration(microseconds: 2)),
        ),
      ),
    );
    final afterStaleInsert =
        await offline.getLibraryTracksWithCount(downloadedOnly: true);
    expect(
      afterStaleInsert.tracks.single.analysis?.summary?.bpm?.numericValue,
      141.18,
    );
    expect(
        afterStaleInsert.tracks.single.analysis?.updatedAt, analysisRevision);

    final newerRevision = DateTime.parse('2026-01-03T04:05:06.123456Z');
    await offline.insertTracks([
      analyzed.copyWith(
        analysis: TrackAnalysis(
          status: TrackAnalysisStatus.analyzed,
          summary: const TrackAnalysisSummary(
            bpm: AnalysisValue(value: 150),
          ),
          updatedAt: newerRevision,
        ),
      ),
      analyzed.copyWith(
        analysis: TrackAnalysis(
          status: TrackAnalysisStatus.analyzed,
          summary: const TrackAnalysisSummary(
            bpm: AnalysisValue(value: 77),
          ),
          updatedAt: analysisRevision,
        ),
      ),
    ]);
    final afterDuplicateBulkInsert =
        await offline.getLibraryTracksWithCount(downloadedOnly: true);
    expect(
      afterDuplicateBulkInsert
          .tracks.single.analysis?.summary?.bpm?.numericValue,
      150,
    );
    expect(
      afterDuplicateBulkInsert.tracks.single.analysis?.updatedAt,
      newerRevision,
    );
  });
}

class _RecordingDatabase implements Database {
  String? table;
  String? where;
  List<Object?>? whereArgs;

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    this.table = table;
    this.where = where;
    this.whereArgs = whereArgs;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
