import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/models/playlist_import.dart';

void main() {
  test(
    'parses playlist import progress and treats duplicate reuse as success',
    () {
      final status = PlaylistImportStatus.fromJson({
        'id': 'import-1',
        'playlistId': 42,
        'sourceUrl': 'https://music.youtube.com/playlist?list=PLabc',
        'sourceTitle': 'midnight nonsense',
        'status': 'partial_failure',
        'totalItems': 4,
        'importedItems': 2,
        'queuedItems': 0,
        'failedItems': 1,
        'skippedItems': 1,
        'maxItems': 500,
        'items': [
          {
            'id': 1,
            'sourceIndex': 0,
            'playlistPosition': 0,
            'title': 'already here',
            'status': 'skipped_duplicate',
            'trackId': 7,
          },
          {
            'id': 2,
            'sourceIndex': 1,
            'playlistPosition': 1,
            'title': 'missing video',
            'status': 'failed',
            'error': 'private video',
          },
        ],
      });

      expect(status.isTerminal, isTrue);
      expect(status.hasFailures, isTrue);
      expect(status.reusedItems, 1);
      expect(status.successfulOrReusedItems, 3);
      expect(status.progressFraction, 1);
      expect(status.items.first.isDuplicateReuse, isTrue);
      expect(status.items.first.isImported, isTrue);
      expect(status.items.last.isFailed, isTrue);
      expect(status.items.last.displayTitle, 'missing video');
    },
  );
}
