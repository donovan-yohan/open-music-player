import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj_session/dj_session_models.dart';

void main() {
  group('DjLineupRequest anchorTrackId', () {
    test('is sent when the queue has a tail', () {
      const request = DjLineupRequest(blocks: 3, perBlock: 5, anchorTrackId: 42);

      expect(request.toQueryParameters()['anchorTrackId'], 42);
    });

    test('key is absent when there is no queue tail', () {
      const request = DjLineupRequest(blocks: 3, perBlock: 5);

      // Absent, not null: an omitted key is wire-identical to a client that
      // never learned about the harmonic anchor at all.
      expect(request.toQueryParameters().containsKey('anchorTrackId'), isFalse);
    });
  });
}
