import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../../shared/models/models.dart';

class OfflineDatabase {
  static Database? _database;
  static const String _dbName = 'open_music_player.db';
  static const int _dbVersion = 1;

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
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
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE playlist_tracks (
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
      CREATE TABLE downloaded_tracks (
        track_id INTEGER PRIMARY KEY,
        local_path TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        status TEXT NOT NULL,
        progress REAL,
        error TEXT,
        downloaded_at TEXT NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE library_tracks (
        track_id INTEGER PRIMARY KEY,
        added_at TEXT NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('CREATE INDEX idx_tracks_identity_hash ON tracks(identity_hash)');
    await db.execute('CREATE INDEX idx_downloaded_tracks_status ON downloaded_tracks(status)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Handle future migrations here
  }

  // Track operations
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

  // Downloaded track operations
  Future<void> insertDownloadedTrack(DownloadedTrack download) async {
    final db = await database;
    await db.insert(
      'downloaded_tracks',
      download.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

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

  Future<List<DownloadedTrack>> getAllDownloadedTracks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT d.*, t.* FROM downloaded_tracks d
      INNER JOIN tracks t ON d.track_id = t.id
      WHERE d.status = 'completed'
      ORDER BY d.downloaded_at DESC
    ''');

    return maps.map((m) {
      final track = Track.fromDbMap(m);
      return DownloadedTrack.fromDbMap(m, track: track);
    }).toList();
  }

  Future<List<DownloadedTrack>> getDownloadingTracks() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT d.*, t.* FROM downloaded_tracks d
      INNER JOIN tracks t ON d.track_id = t.id
      WHERE d.status IN ('pending', 'downloading')
      ORDER BY d.downloaded_at ASC
    ''');

    return maps.map((m) {
      final track = Track.fromDbMap(m);
      return DownloadedTrack.fromDbMap(m, track: track);
    }).toList();
  }

  Future<bool> isTrackDownloaded(int trackId) async {
    final db = await database;
    final result = await db.query(
      'downloaded_tracks',
      where: 'track_id = ? AND status = ?',
      whereArgs: [trackId, 'completed'],
    );
    return result.isNotEmpty;
  }

  Future<void> deleteDownloadedTrack(int trackId) async {
    final db = await database;
    await db.delete(
      'downloaded_tracks',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

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

    final whereClause = conditions.isNotEmpty
        ? 'WHERE ${conditions.join(' AND ')}'
        : '';

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

    final whereClause = conditions.isNotEmpty
        ? 'WHERE ${conditions.join(' AND ')}'
        : '';

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
