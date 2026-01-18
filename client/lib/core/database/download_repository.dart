import 'package:sqflite/sqflite.dart';

import '../models/download_job.dart';
import 'database_helper.dart';

class DownloadRepository {
  Future<Database> get _db => DatabaseHelper.database;

  Future<void> upsertDownload(DownloadJob job) async {
    final db = await _db;
    await db.insert(
      'downloads',
      _jobToMap(job),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<DownloadJob?> getDownload(String id) async {
    final db = await _db;
    final results = await db.query(
      'downloads',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return _jobFromMap(results.first);
  }

  Future<DownloadJob?> getDownloadByTrackId(int trackId) async {
    final db = await _db;
    final results = await db.query(
      'downloads',
      where: 'track_id = ?',
      whereArgs: [trackId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    return _jobFromMap(results.first);
  }

  Future<List<DownloadJob>> getActiveDownloads() async {
    final db = await _db;
    final results = await db.query(
      'downloads',
      where: 'status IN (?, ?, ?)',
      whereArgs: ['queued', 'downloading', 'processing'],
      orderBy: 'started_at ASC',
    );
    return results.map(_jobFromMap).toList();
  }

  Future<List<DownloadJob>> getAllDownloads() async {
    final db = await _db;
    final results = await db.query('downloads', orderBy: 'started_at DESC');
    return results.map(_jobFromMap).toList();
  }

  Future<void> updateProgress(String id, double progress, int bytesDownloaded) async {
    final db = await _db;
    await db.update(
      'downloads',
      {'progress': progress, 'bytes_downloaded': bytesDownloaded},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateStatus(String id, DownloadStatus status, {String? errorMessage, String? localPath}) async {
    final db = await _db;
    final updates = <String, dynamic>{'status': status.name};
    if (errorMessage != null) updates['error_message'] = errorMessage;
    if (localPath != null) updates['local_path'] = localPath;
    if (status == DownloadStatus.completed) {
      updates['completed_at'] = DateTime.now().toIso8601String();
    }
    await db.update('downloads', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteDownload(String id) async {
    final db = await _db;
    await db.delete('downloads', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markTrackDownloaded(int trackId, String localPath, int fileSize) async {
    final db = await _db;
    await db.insert(
      'downloaded_tracks',
      {
        'track_id': trackId,
        'local_path': localPath,
        'downloaded_at': DateTime.now().toIso8601String(),
        'file_size_bytes': fileSize,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getLocalPath(int trackId) async {
    final db = await _db;
    final results = await db.query(
      'downloaded_tracks',
      columns: ['local_path'],
      where: 'track_id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return results.first['local_path'] as String?;
  }

  Future<bool> isTrackDownloaded(int trackId) async {
    final path = await getLocalPath(trackId);
    return path != null;
  }

  Future<void> removeDownloadedTrack(int trackId) async {
    final db = await _db;
    await db.delete('downloaded_tracks', where: 'track_id = ?', whereArgs: [trackId]);
  }

  Future<int> getTotalDownloadedSize() async {
    final db = await _db;
    final result = await db.rawQuery('SELECT SUM(file_size_bytes) as total FROM downloaded_tracks');
    return (result.first['total'] as int?) ?? 0;
  }

  Future<int> getDownloadedTrackCount() async {
    final db = await _db;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM downloaded_tracks');
    return (result.first['count'] as int?) ?? 0;
  }

  Map<String, dynamic> _jobToMap(DownloadJob job) {
    return {
      'id': job.id,
      'track_id': job.trackId,
      'status': job.status.name,
      'progress': job.progress,
      'local_path': job.localPath,
      'error_message': job.errorMessage,
      'started_at': job.startedAt?.toIso8601String(),
      'completed_at': job.completedAt?.toIso8601String(),
      'bytes_downloaded': job.bytesDownloaded,
      'total_bytes': job.totalBytes,
    };
  }

  DownloadJob _jobFromMap(Map<String, dynamic> map) {
    return DownloadJob(
      id: map['id'] as String,
      trackId: map['track_id'] as int,
      status: DownloadStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => DownloadStatus.queued,
      ),
      progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
      localPath: map['local_path'] as String?,
      errorMessage: map['error_message'] as String?,
      startedAt: map['started_at'] != null
          ? DateTime.parse(map['started_at'] as String)
          : null,
      completedAt: map['completed_at'] != null
          ? DateTime.parse(map['completed_at'] as String)
          : null,
      bytesDownloaded: map['bytes_downloaded'] as int?,
      totalBytes: map['total_bytes'] as int?,
    );
  }
}
