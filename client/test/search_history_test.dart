import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/storage/search_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  SearchHistoryStore store(SearchHistoryKind kind, {String account = 'a'}) =>
      SearchHistoryStore(kind: kind, accountId: () async => account);

  test(
      'trim, case-insensitive promote, bounded persistence and separate scopes',
      () async {
    final discover = store(SearchHistoryKind.discover);
    final library = store(SearchHistoryKind.library);
    await discover.add('  Bjork  ');
    await discover.add('Radiohead');
    await discover.add('bjork');
    await discover.add('   ');
    await library.add('Library only');
    expect(
        await store(SearchHistoryKind.discover).load(), ['bjork', 'Radiohead']);
    expect(await library.load(), ['Library only']);
    expect(
        await store(SearchHistoryKind.discover, account: 'b').load(), isEmpty);
    await discover.clear();
    expect(await discover.load(), isEmpty);
    expect(await library.load(), ['Library only']);
    for (var i = 0; i < 25; i++) {
      await discover.add('query $i');
    }
    final saved = await discover.load();
    expect(saved, hasLength(SearchHistoryStore.maxEntries));
    expect(saved.first, 'query 24');
    expect(saved.last, 'query 5');
  });

  test('rapid submissions across instances and clear preserve invocation order',
      () async {
    final first = store(SearchHistoryKind.discover);
    final second = store(SearchHistoryKind.discover);
    await Future.wait(
        [first.add('one'), second.add('two'), first.add('three')]);
    expect(await first.load(), ['three', 'two', 'one']);
    await Future.wait([first.add('four'), second.clear(), first.add('five')]);
    expect(await second.load(), ['five']);
  });

  test('missing identity and unavailable storage never block callers',
      () async {
    final anonymous = SearchHistoryStore(
      kind: SearchHistoryKind.discover,
      accountId: () async => null,
    );
    await anonymous.add('private');
    expect(await anonymous.load(), isEmpty);
    final broken = SearchHistoryStore(
      kind: SearchHistoryKind.library,
      accountId: () async => 'a',
      prefs: () => Future.error(StateError('unavailable')),
    );
    await broken.add('private');
    await broken.clear();
    expect(await broken.load(), isEmpty);
    final working = store(SearchHistoryKind.library);
    await working.add('recovered');
    expect(await working.load(), ['recovered']);
  });

  test('late reads cannot expose the previous account history', () async {
    await store(SearchHistoryKind.discover).add('private');
    var account = 'a';
    final barrier = Completer<SharedPreferences>();
    final requested = Completer<void>();
    final history = SearchHistoryStore(
      kind: SearchHistoryKind.discover,
      accountId: () async => account,
      prefs: () {
        requested.complete();
        return barrier.future;
      },
    );
    final read = history.load();
    await requested.future;
    account = 'b';
    barrier.complete(await SharedPreferences.getInstance());
    expect(await read, isEmpty);
  });

  test(
      'queued writes retain their original owner and cannot seed a new account',
      () async {
    var account = 'a';
    final barrier = Completer<SharedPreferences>();
    final requested = Completer<void>();
    final slow = SearchHistoryStore(
      kind: SearchHistoryKind.discover,
      accountId: () async => account,
      prefs: () {
        requested.complete();
        return barrier.future;
      },
    );
    final first = slow.add('first');
    await requested.future;
    final queued = slow.add('queued');
    account = 'b';
    barrier.complete(await SharedPreferences.getInstance());
    await Future.wait([first, queued]);
    expect(
        await store(SearchHistoryKind.discover, account: 'b').load(), isEmpty);
  });
}
