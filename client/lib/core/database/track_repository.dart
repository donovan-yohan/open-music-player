import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/track.dart';
import 'database_helper.dart';

class TrackRepository {
  Future<Database> get _db => DatabaseHelper.database;

  Future<void> upsertTrack(Track track) async {
    final db = await _db;
    await db.insert(
      'tracks',
      _trackToMap(track),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertTracks(List<Track> tracks) async {
    final db = await _db;
    final batch = db.batch();
    for (final track in tracks) {
      batch.insert(
        'tracks',
        _trackToMap(track),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Track?> getTrack(int id) async {
    final db = await _db;
    final results = await db.query(
      'tracks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return _trackFromMap(results.first);
  }

  Future<List<Track>> getAllTracks() async {
    final db = await _db;
    final results = await db.query('tracks', orderBy: 'added_at DESC');
    return results.map(_trackFromMap).toList();
  }

  Future<List<Track>> getDownloadedTracks() async {
    final db = await _db;
    final results = await db.rawQuery('''
      SELECT t.* FROM tracks t
      INNER JOIN downloaded_tracks dt ON t.id = dt.track_id
      ORDER BY dt.downloaded_at DESC
    ''');
    return results.map(_trackFromMap).toList();
  }

  Future<List<Track>> searchTracks(String query) async {
    final db = await _db;
    final results = await db.query(
      'tracks',
      where: 'title LIKE ? OR artist LIKE ? OR album LIKE ?',
      whereArgs: ['%$query%', '%$query%', '%$query%'],
      orderBy: 'title ASC',
    );
    return results.map(_trackFromMap).toList();
  }

  Future<void> deleteTrack(int id) async {
    final db = await _db;
    await db.delete('tracks', where: 'id = ?', whereArgs: [id]);
  }

  Map<String, dynamic> _trackToMap(Track track) {
    return {
      'id': track.id,
      'title': track.title,
      'artist': track.artist,
      'album': track.album,
      'duration_ms': track.durationMs,
      'version': track.version,
      'mb_recording_id': track.mbRecordingId,
      'mb_release_id': track.mbReleaseId,
      'mb_artist_id': track.mbArtistId,
      'mb_verified': track.mbVerified ? 1 : 0,
      'source_url': track.sourceUrl,
      'source_type': track.sourceType,
      'storage_key': track.storageKey,
      'file_size_bytes': track.fileSizeBytes,
      'metadata': track.metadata != null ? jsonEncode(track.metadata) : null,
      'added_at': track.addedAt?.toIso8601String(),
    };
  }

  Track _trackFromMap(Map<String, dynamic> map) {
    return Track(
      id: map['id'] as int,
      title: map['title'] as String,
      artist: map['artist'] as String,
      album: map['album'] as String?,
      durationMs: map['duration_ms'] as int,
      version: map['version'] as String?,
      mbRecordingId: map['mb_recording_id'] as String?,
      mbReleaseId: map['mb_release_id'] as String?,
      mbArtistId: map['mb_artist_id'] as String?,
      mbVerified: (map['mb_verified'] as int?) == 1,
      sourceUrl: map['source_url'] as String?,
      sourceType: map['source_type'] as String?,
      storageKey: map['storage_key'] as String?,
      fileSizeBytes: map['file_size_bytes'] as int?,
      metadata: map['metadata'] != null
          ? jsonDecode(map['metadata'] as String) as Map<String, dynamic>
          : null,
      addedAt: map['added_at'] != null
          ? DateTime.parse(map['added_at'] as String)
          : null,
    );
  }
}
