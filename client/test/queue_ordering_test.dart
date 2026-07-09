import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';

MediaItem _item(String id, {String? origin}) => MediaItem(
      id: id,
      title: id,
      extras: origin == null ? null : {'itemOrigin': origin},
    );

void main() {
  group('itemOrigin / markOrigin', () {
    test('defaults to context when unmarked', () {
      expect(itemOrigin(_item('a')), queueOriginContext);
      expect(
          itemOrigin(_item('a', origin: queueOriginManual)), queueOriginManual);
    });

    test('markOrigin tags the item without dropping existing extras', () {
      final tagged = markOrigin(
        const MediaItem(id: 'x', title: 'x', extras: {'url': 'u'}),
        queueOriginManual,
      );
      expect(tagged.extras?['itemOrigin'], queueOriginManual);
      expect(tagged.extras?['url'], 'u');
    });
  });

  group('manualEnqueueIndex', () {
    test('empty queue inserts at 0', () {
      expect(manualEnqueueIndex(const [], null), 0);
    });

    test('all-context upcoming: insert right after the current item', () {
      final q = [_item('cur'), _item('c1'), _item('c2')];
      expect(manualEnqueueIndex(q, 0), 1);
    });

    test('inserts after existing upcoming manual items, before context', () {
      final q = [
        _item('cur'),
        _item('m1', origin: queueOriginManual),
        _item('c1'),
      ];
      expect(manualEnqueueIndex(q, 0), 2);
    });

    test('all upcoming manual: append at the end', () {
      final q = [
        _item('cur'),
        _item('m1', origin: queueOriginManual),
        _item('m2', origin: queueOriginManual),
      ];
      expect(manualEnqueueIndex(q, 0), 3);
    });

    test('nothing playing yet (null index) with a context queue: insert at 0',
        () {
      final q = [_item('c1'), _item('c2')];
      expect(manualEnqueueIndex(q, null), 0);
    });

    test('current item is the last one: append', () {
      final q = [_item('c1'), _item('c2')];
      expect(manualEnqueueIndex(q, 1), 2);
    });
  });
}
