import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../../shared/models/models.dart';
import '../cache/playback_cache_entry.dart';
import '../cache/playback_cache_store.dart';
import 'offline_download_store.dart';

class OfflineDatabase implements OfflineDownloadStore, PlaybackCacheStore {
  static Database? _database;
  static Future<Database>? _openingDatabase;
  static const String _dbName = 'open_music_player.db';
  static const int _dbVersion = 4;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;

    final opening = _openingDatabase ??= _initDatabase();
    try {
      final db = await opening;
      _database = db;
      return db;
    } finally {
      if (identical(_openingDatabase, opening)) {
        _openingDatabase = null;
      }
    }
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tracks (
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
        analysis_status TEXT,
        analysis_summary TEXT,
        analysis_overrides TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_tracks (
        playlist_id INTEGER NOT NULL,
        track_id INTEGER NOT NULL,
        position INTEGER NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (playlist_id, track_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS downloaded_tracks (
        track_id INTEGER PRIMARY KEY,
        local_path TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        status TEXT NOT NULL,
        progress REAL,
        error TEXT,
        downloaded_at TEXT NOT NULL,
        expected_size_bytes INTEGER,
        etag TEXT,
        storage_key_version TEXT,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS library_tracks (
        track_id INTEGER PRIMARY KEY,
        added_at TEXT NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tracks_identity_hash '
      'ON tracks(identity_hash)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_downloaded_tracks_status '
      'ON downloaded_tracks(status)',
    );

    await _createPlaybackCacheTable(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v2: record signed descriptor identity on offline downloads so stale or
    // missing artifacts can be detected without trusting the completed flag.
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE downloaded_tracks ADD COLUMN expected_size_bytes INTEGER',
      );
      await db.execute(
        'ALTER TABLE downloaded_tracks ADD COLUMN etag TEXT',
      );
      await db.execute(
        'ALTER TABLE downloaded_tracks ADD COLUMN storage_key_version TEXT',
      );
    }

    // v3: bounded, evictable playback cache. Its own table (no FK to tracks):
    // cached playback artifacts are independent of the library/download rows so
    // eviction and clear can never reach an explicit download.
    if (oldVersion < 3) {
      await _createPlaybackCacheTable(db);
    }

    // v4: retain compact musical analysis for downloaded/offline song rows.
    if (oldVersion < 4) {
      await db.execute('ALTER TABLE tracks ADD COLUMN analysis_status TEXT');
      await db.execute('ALTER TABLE tracks ADD COLUMN analysis_summary TEXT');
      await db.execute('ALTER TABLE tracks ADD COLUMN analysis_overrides TEXT');
    }
  }

  Future<void> _createPlaybackCacheTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_cache (
        track_id INTEGER PRIMARY KEY,
        local_path TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        etag TEXT,
        storage_key_version TEXT,
        expected_size_bytes INTEGER,
        url_identity TEXT,
        last_accessed_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playback_cache_last_accessed '
      'ON playback_cache(last_accessed_at)',
    );
  }

  // Track operations
  @override
  Future<void> insertTrack(Track track) async {
    final db = await database;
    await db.insert(
      'tracks',
      track.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertTracks(List<Track> tracks) async {
    final db = await database;
    final batch = db.batch();
    for (final track in tracks) {
      batch.insert(
        'tracks',
        track.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Track?> getTrack(int id) async {
    final db = await database;
    final maps = await db.query('tracks', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Track.fromDbMap(maps.first);
  }

  Future<List<Track>> getAllTracks() async {
    final db = await database;
    final maps = await db.query('tracks', orderBy: 'title ASC');
    return maps.map((m) => Track.fromDbMap(m)).toList();
  }

  Future<void> updateTrackAnalysis(Track track) async {
    final db = await database;
    final values = track.toDbMap();
    final status = values['analysis_status'];
    final summary = values['analysis_summary'];
    final overrides = values['analysis_overrides'];
    await db.update(
      'tracks',
      {
        'analysis_status': status,
        'analysis_summary': summary,
        'analysis_overrides': overrides,
      },
      where: '''
        id = ? AND (
          analysis_status IS NOT ? OR
          analysis_summary IS NOT ? OR
          analysis_overrides IS NOT ?
        )
      ''',
      whereArgs: [track.id, status, summary, overrides],
    );
  }

  // Downloaded track operations
  @override
  Future<void> insertDownloadedTrack(DownloadedTrack download) async {
    final db = await database;
    await db.insert(
      'downloaded_tracks',
      download.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> updateDownloadStatus(
    int trackId,
    DownloadStatus status, {
    double? progress,
    String? error,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{'status': status.name};
    if (progress != null) updates['progress'] = progress;
    if (error != null) updates['error'] = error;

    await db.update(
      'downloaded_tracks',
      updates,
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  @override
  Future<void> markDownloadCompleted(
    int trackId, {
    required int fileSizeBytes,
    int? expectedSizeBytes,
    String? etag,
    String? storageKeyVersion,
  }) async {
    final db = await database;
    await db.update(
      'downloaded_tracks',
      {
        'status': DownloadStatus.completed.name,
        'progress': 1.0,
        'error': null,
        'file_size_bytes': fileSizeBytes,
        'expected_size_bytes': expectedSizeBytes,
        'etag': etag,
        'storage_key_version': storageKeyVersion,
      },
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  @override
  Future<DownloadedTrack?> getDownloadedTrack(int trackId) async {
    final db = await database;
    final maps = await db.query(
      'downloaded_tracks',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
    if (maps.isEmpty) return null;

    final track = await getTrack(trackId);
    return DownloadedTrack.fromDbMap(maps.first, track: track);
  }

  @override
  Future<List<DownloadedTrack>> getAllDownloadedTracks() async {
    final db = await database;
    // Re-select the download row's file_size_bytes last: it collides with
    // tracks.file_size_bytes, and we want the validated on-disk size (and to
    // avoid a NULL from the nullable tracks column) rather than the advertised
    // library size.
    final maps = await db.rawQuery('''
      SELECT d.*, t.*, d.file_size_bytes AS file_size_bytes FROM downloaded_tracks d
      INNER JOIN tracks t ON d.track_id = t.id
      WHERE d.status = 'completed'
      ORDER BY d.downloaded_at DESC
    ''');

    return maps.map((m) {
      final track = Track.fromDbMap(m);
      return DownloadedTrack.fromDbMap(m, track: track);
    }).toList();
  }

  @override
  Future<List<DownloadedTrack>> getDownloadingTracks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT d.*, t.*, d.file_size_bytes AS file_size_bytes FROM downloaded_tracks d
      INNER JOIN tracks t ON d.track_id = t.id
      WHERE d.status IN ('pending', 'downloading')
      ORDER BY d.downloaded_at ASC
    ''');

    return maps.map((m) {
      final track = Track.fromDbMap(m);
      return DownloadedTrack.fromDbMap(m, track: track);
    }).toList();
  }

  @override
  Future<bool> isTrackDownloaded(int trackId) async {
    final db = await database;
    final result = await db.query(
      'downloaded_tracks',
      where: 'track_id = ? AND status = ?',
      whereArgs: [trackId, 'completed'],
    );
    return result.isNotEmpty;
  }

  @override
  Future<void> deleteDownloadedTrack(int trackId) async {
    final db = await database;
    await db.delete(
      'downloaded_tracks',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  @override
  Future<void> deleteAllDownloads() async {
    final db = await database;
    await db.delete('downloaded_tracks');
  }

  Future<int> getTotalDownloadedSize() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(file_size_bytes), 0) as total
      FROM downloaded_tracks
      WHERE status = 'completed'
    ''');
    return (result.first['total'] as int?) ?? 0;
  }

  Future<int> getDownloadedTrackCount() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM downloaded_tracks
      WHERE status = 'completed'
    ''');
    return (result.first['count'] as int?) ?? 0;
  }

  // Playback cache operations (bounded, evictable; separate from downloads).
  @override
  Future<void> upsertEntry(PlaybackCacheEntry entry) async {
    final db = await database;
    await db.insert(
      'playback_cache',
      entry.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<PlaybackCacheEntry?> getEntry(int trackId) async {
    final db = await database;
    final maps = await db.query(
      'playback_cache',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
    if (maps.isEmpty) return null;
    return PlaybackCacheEntry.fromDbMap(maps.first);
  }

  @override
  Future<List<PlaybackCacheEntry>> getAllEntries() async {
    final db = await database;
    final maps = await db.query(
      'playback_cache',
      orderBy: 'last_accessed_at ASC',
    );
    return maps.map(PlaybackCacheEntry.fromDbMap).toList();
  }

  @override
  Future<void> touchEntry(int trackId, DateTime accessedAt) async {
    final db = await database;
    await db.update(
      'playback_cache',
      {'last_accessed_at': accessedAt.toIso8601String()},
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  @override
  Future<void> deleteEntry(int trackId) async {
    final db = await database;
    await db.delete(
      'playback_cache',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  @override
  Future<void> deleteAll() async {
    final db = await database;
    await db.delete('playback_cache');
  }

  @override
  Future<int> totalSizeBytes() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(file_size_bytes), 0) AS total FROM playback_cache',
    );
    return (result.first['total'] as int?) ?? 0;
  }

  // Playlist operations
  Future<void> insertPlaylist(Playlist playlist) async {
    final db = await database;
    await db.insert(
      'playlists',
      playlist.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Playlist>> getAllPlaylists() async {
    final db = await database;
    final maps = await db.query('playlists', orderBy: 'name ASC');
    return maps.map((m) => Playlist.fromDbMap(m)).toList();
  }

  // Library operations
  Future<void> addToLibrary(int trackId) async {
    final db = await database;
    await db.insert(
      'library_tracks',
      {
        'track_id': trackId,
        'added_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Track>> getLibraryTracks({
    bool downloadedOnly = false,
    VerificationFilter verificationFilter = VerificationFilter.all,
    int? limit,
    int offset = 0,
  }) async {
    final db = await database;
    final conditions = <String>[];

    if (downloadedOnly) {
      conditions.add("d.track_id IS NOT NULL AND d.status = 'completed'");
    }

    switch (verificationFilter) {
      case VerificationFilter.verifiedOnly:
        conditions.add('t.mb_verified = 1');
        break;
      case VerificationFilter.unverifiedOnly:
        conditions.add('t.mb_verified = 0');
        break;
      case VerificationFilter.all:
        break;
    }

    final whereClause =
        conditions.isNotEmpty ? 'WHERE ${conditions.join(' AND ')}' : '';

    final limitClause = limit != null ? 'LIMIT $limit OFFSET $offset' : '';

    final query = '''
      SELECT t.* FROM tracks t
      INNER JOIN library_tracks l ON t.id = l.track_id
      LEFT JOIN downloaded_tracks d ON t.id = d.track_id
      $whereClause
      ORDER BY l.added_at DESC
      $limitClause
    ''';

    final maps = await db.rawQuery(query);
    return maps.map((m) => Track.fromDbMap(m)).toList();
  }

  /// Returns library tracks with total count for pagination
  Future<({List<Track> tracks, int total})> getLibraryTracksWithCount({
    bool downloadedOnly = false,
    VerificationFilter verificationFilter = VerificationFilter.all,
    int limit = 20,
    int offset = 0,
  }) async {
    final db = await database;
    final conditions = <String>[];

    if (downloadedOnly) {
      conditions.add("d.track_id IS NOT NULL AND d.status = 'completed'");
    }

    switch (verificationFilter) {
      case VerificationFilter.verifiedOnly:
        conditions.add('t.mb_verified = 1');
        break;
      case VerificationFilter.unverifiedOnly:
        conditions.add('t.mb_verified = 0');
        break;
      case VerificationFilter.all:
        break;
    }

    final whereClause =
        conditions.isNotEmpty ? 'WHERE ${conditions.join(' AND ')}' : '';

    // Get count and data in parallel
    final countQuery = '''
      SELECT COUNT(*) as total FROM tracks t
      INNER JOIN library_tracks l ON t.id = l.track_id
      LEFT JOIN downloaded_tracks d ON t.id = d.track_id
      $whereClause
    ''';

    final dataQuery = '''
      SELECT t.* FROM tracks t
      INNER JOIN library_tracks l ON t.id = l.track_id
      LEFT JOIN downloaded_tracks d ON t.id = d.track_id
      $whereClause
      ORDER BY l.added_at DESC
      LIMIT $limit OFFSET $offset
    ''';

    final results = await Future.wait([
      db.rawQuery(countQuery),
      db.rawQuery(dataQuery),
    ]);

    final total = (results[0].first['total'] as int?) ?? 0;
    final tracks = results[1].map((m) => Track.fromDbMap(m)).toList();

    return (tracks: tracks, total: total);
  }

  Future<Map<VerificationFilter, int>> getLibraryTrackCounts() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT
        COUNT(*) as total,
        SUM(CASE WHEN t.mb_verified = 1 THEN 1 ELSE 0 END) as verified,
        SUM(CASE WHEN t.mb_verified = 0 THEN 1 ELSE 0 END) as unverified
      FROM tracks t
      INNER JOIN library_tracks l ON t.id = l.track_id
    ''');

    final row = result.first;
    return {
      VerificationFilter.all: (row['total'] as int?) ?? 0,
      VerificationFilter.verifiedOnly: (row['verified'] as int?) ?? 0,
      VerificationFilter.unverifiedOnly: (row['unverified'] as int?) ?? 0,
    };
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
