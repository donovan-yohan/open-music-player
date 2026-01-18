import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static const _databaseName = 'open_music_player.db';
  static const _databaseVersion = 1;

  static Database? _database;

  static Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, _databaseName);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tracks (
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT,
        duration_ms INTEGER NOT NULL,
        version TEXT,
        mb_recording_id TEXT,
        mb_release_id TEXT,
        mb_artist_id TEXT,
        mb_verified INTEGER DEFAULT 0,
        source_url TEXT,
        source_type TEXT,
        storage_key TEXT,
        file_size_bytes INTEGER,
        metadata TEXT,
        added_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE downloads (
        id TEXT PRIMARY KEY,
        track_id INTEGER NOT NULL,
        status TEXT NOT NULL,
        progress REAL DEFAULT 0,
        local_path TEXT,
        error_message TEXT,
        started_at TEXT,
        completed_at TEXT,
        bytes_downloaded INTEGER,
        total_bytes INTEGER,
        FOREIGN KEY (track_id) REFERENCES tracks (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE downloaded_tracks (
        track_id INTEGER PRIMARY KEY,
        local_path TEXT NOT NULL,
        downloaded_at TEXT NOT NULL,
        file_size_bytes INTEGER NOT NULL,
        FOREIGN KEY (track_id) REFERENCES tracks (id)
      )
    ''');

    await db.execute('CREATE INDEX idx_tracks_artist ON tracks (artist)');
    await db.execute('CREATE INDEX idx_tracks_album ON tracks (album)');
    await db.execute('CREATE INDEX idx_downloads_status ON downloads (status)');
    await db.execute('CREATE INDEX idx_downloads_track_id ON downloads (track_id)');
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Handle future migrations
  }

  static Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
