import 'dart:io';

/// Deletes [path] if it exists, swallowing any error. A failed unlink must
/// never break the calling flow (cleanup is always best-effort).
Future<void> deleteFileQuietly(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {
    // Best-effort cleanup.
  }
}

/// Deletes every file directly inside [dirPath] (best-effort). Used to sweep
/// orphan artifacts that a row-keyed delete would miss (e.g. a leftover `.part`
/// from an interrupted transfer). Silently does nothing if the directory is
/// absent or unreadable.
Future<void> sweepDirectoryFiles(String dirPath) async {
  try {
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          await deleteFileQuietly(entity.path);
        }
      }
    }
  } catch (_) {
    // Best-effort sweep.
  }
}
