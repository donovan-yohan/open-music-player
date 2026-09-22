import 'package:shared_preferences/shared_preferences.dart';

import '../audio/queue_persistence.dart';
import 'secure_storage.dart';

enum SearchHistoryKind { discover, library }

/// Local, account-scoped history. Storage failures must never block a search.
class SearchHistoryStore {
  SearchHistoryStore({
    required this.kind,
    Future<SharedPreferences> Function()? prefs,
    Future<String?> Function()? accountId,
  })  : _prefs = prefs ?? SharedPreferences.getInstance,
        _accountId = accountId ?? _storedAccountId;

  final SearchHistoryKind kind;
  final Future<SharedPreferences> Function() _prefs;
  final Future<String?> Function() _accountId;
  static const maxEntries = 20;

  // All instances share the same preferences backend. Serialize read/modify/
  // write operations, including clear, so rapid submissions cannot lose data.
  static Future<void>? _pending;

  static Future<String?> _storedAccountId() async =>
      accountIdFromAccessToken(await SecureStorage().getAccessToken());

  Future<T> _serialized<T>(Future<T> Function() action, T fallback) {
    final result = (_pending ?? Future<void>.value())
        .then((_) => action())
        .catchError((Object _) => fallback);
    late final Future<void> tail;
    tail = result.then<void>((_) {
      if (identical(_pending, tail)) _pending = null;
    });
    _pending = tail;
    return result;
  }

  Future<String?> _key() async {
    try {
      final id = await _accountId();
      return id == null || id.isEmpty
          ? null
          : 'search_history.${kind.name}.$id';
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> load() => _serialized(() async {
        final key = await _key();
        if (key == null) return const <String>[];
        final values = (await _prefs()).getStringList(key) ?? const <String>[];
        if (key != await _key()) return const <String>[];
        return List<String>.unmodifiable(values.take(maxEntries));
      }, const <String>[]);

  Future<void> add(String query) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return;
    // Capture the owner at submission, not when queued storage work executes.
    final owner = _key();
    await _serialized(() async {
      final key = await owner;
      if (key == null || key != await _key()) return false;
      final prefs = await _prefs();
      final current = prefs.getStringList(key) ?? const <String>[];
      final next = <String>[
        normalized,
        ...current
            .where((item) => item.toLowerCase() != normalized.toLowerCase()),
      ].take(maxEntries).toList(growable: false);
      return prefs.setStringList(key, next);
    }, false);
  }

  Future<void> clear() async {
    final owner = _key();
    await _serialized(() async {
      final key = await owner;
      if (key == null) return false;
      return (await _prefs()).remove(key);
    }, false);
  }
}
