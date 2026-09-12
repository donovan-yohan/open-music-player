import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/queue_ordering.dart';

MediaItem _item(String id, {String? origin}) => MediaItem(
      id: id,
      title: id,
      extras: origin == null ? null : {'itemOrigin': origin},
    );

void main() {
  group('playCollectionOrder', () {
    test('preserves collection order for a normal launch', () {
      final source = [1, 2, 3];

      final ordered = playCollectionOrder(source);

      expect(ordered, [1, 2, 3]);
      expect(ordered, isNot(same(source)));
    });

    test('uses the injected RNG for a one-shot shuffled launch', () {
      final source = [for (var index = 0; index < 8; index++) index];

      final first = playCollectionOrder(
        source,
        shuffled: true,
        random: Random(7),
      );
      final second = playCollectionOrder(
        source,
        shuffled: true,
        random: Random(7),
      );

      expect(first, second);
      expect(first, isNot(source));
      expect(first.toSet(), source.toSet());
      expect(source, [0, 1, 2, 3, 4, 5, 6, 7]);
    });
  });

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

  group('unplayedManualItems', () {
    test('keeps only the manual items still ahead of the playhead', () {
      final q = [
        _item('c1'),
        _item('m1', origin: queueOriginManual),
        _item('c2'),
        _item('m2', origin: queueOriginManual),
        _item('c3'),
      ];

      expect(
        unplayedManualItems(q, 0).map((item) => item.id),
        ['m1', 'm2'],
      );
      // m1 is now playing: the listener is leaving it, not re-queueing it.
      expect(unplayedManualItems(q, 1).map((item) => item.id), ['m2']);
      expect(unplayedManualItems(q, 3), isEmpty);
    });

    test('nothing playing yet means the whole queue is still ahead', () {
      final q = [_item('m1', origin: queueOriginManual), _item('c1')];
      expect(unplayedManualItems(q, null).map((item) => item.id), ['m1']);
    });

    test('continuation items are not user-built and never carry over', () {
      final q = [
        _item('c1'),
        _item('x1', origin: queueOriginContinuation),
        _item('m1', origin: queueOriginManual),
      ];
      expect(unplayedManualItems(q, 0).map((item) => item.id), ['m1']);
    });
  });

  group('withCarriedOverManualItems', () {
    test('lands the user queue after the track that started the context', () {
      final merged = withCarriedOverManualItems(
        [_item('b1'), _item('b2'), _item('b3')],
        [_item('m1', origin: queueOriginManual)],
        startIndex: 1,
      );

      expect(
        merged.map((item) => item.id),
        ['b1', 'b2', 'm1', 'b3'],
      );
    });

    test('keeps the relative order of the carried-over items', () {
      final merged = withCarriedOverManualItems(
        [_item('b1'), _item('b2')],
        [
          _item('m1', origin: queueOriginManual),
          _item('m2', origin: queueOriginManual),
        ],
        startIndex: 0,
      );

      expect(merged.map((item) => item.id), ['b1', 'm1', 'm2', 'b2']);
    });

    test('an empty user queue leaves the context untouched', () {
      final contextItems = [_item('b1'), _item('b2')];
      expect(
        withCarriedOverManualItems(contextItems, const [], startIndex: 0),
        same(contextItems),
      );
    });

    test('an out-of-range start index still splices after the last item', () {
      final merged = withCarriedOverManualItems(
        [_item('b1')],
        [_item('m1', origin: queueOriginManual)],
        startIndex: 9,
      );

      expect(merged.map((item) => item.id), ['b1', 'm1']);
    });
  });
}
