import '../models/queue_state.dart';
import '../models/track.dart';
import '../models/trim_range.dart';
import 'queue_repository.dart';

/// In-memory [QueueRepository] used for the mobile-web queue skeleton and for
/// widget tests. No network, no platform channels — safe in `flutter test`.
///
/// Seeds a small demo queue plus a searchable catalog so the UI has something
/// to render on a staging web build.
class MockQueueRepository implements QueueRepository {
  MockQueueRepository({DateTime? now}) : _now = now ?? _fixedEpoch {
    _catalog = _buildCatalog();
    _queue = _seedQueue();
  }

  // Fixed timestamp so the repo is deterministic in tests (no Date.now()).
  static final DateTime _fixedEpoch = DateTime.utc(2026, 1, 1);
  final DateTime _now;

  late List<Track> _catalog;
  late QueueState _queue;
  final Map<String, TrimRange> _trimRanges = {};
  int _mixPlanCounter = 0;

  Track _track(String id, String title, String artist, int duration) => Track(
        id: id,
        title: title,
        artist: artist,
        duration: duration,
        addedAt: _now,
      );

  List<Track> _buildCatalog() => [
        _track('t1', 'Midnight Drive', 'Neon Coast', 214),
        _track('t2', 'Paper Planes', 'The Foldables', 188),
        _track('t3', 'Glass Horizon', 'Aria Vale', 241),
        _track('t4', 'Slow Tide', 'Harbor Lights', 196),
        _track('t5', 'Echo Chamber', 'Static Bloom', 203),
        _track('t6', 'Velvet Static', 'Neon Coast', 175),
        _track('t7', 'Low Orbit', 'Aria Vale', 228),
        _track('t8', 'Citrus Sky', 'The Foldables', 167),
        _track('t9', 'Undertow', 'Harbor Lights', 212),
        _track('t10', 'Afterglow', 'Static Bloom', 199),
      ];

  QueueState _seedQueue() => QueueState(
        tracks: [
          _catalog[0],
          _catalog[1],
          _catalog[2],
          _catalog[3],
        ],
        currentIndex: 0,
      );

  Track? _catalogById(String id) {
    for (final t in _catalog) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<QueueState> getQueue() async => _queue;

  @override
  Future<List<Track>> searchTracks(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return _catalog.where((t) {
      final hay = '${t.title} ${t.artist ?? ''}'.toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Future<QueueState> addTracks(List<String> trackIds,
      {bool playNext = false}) async {
    final additions =
        trackIds.map(_catalogById).whereType<Track>().toList(growable: false);
    if (additions.isEmpty) return _queue;

    final tracks = List<Track>.from(_queue.tracks);
    var currentIndex = _queue.currentIndex;
    if (playNext && currentIndex >= 0) {
      tracks.insertAll(currentIndex + 1, additions);
    } else {
      tracks.addAll(additions);
    }
    if (currentIndex < 0 && tracks.isNotEmpty) {
      currentIndex = 0;
    }
    _queue = _copyWith(tracks: tracks, currentIndex: currentIndex);
    return _queue;
  }

  @override
  Future<QueueState> removeAt(int position) async {
    if (position < 0 || position >= _queue.tracks.length) return _queue;
    final tracks = List<Track>.from(_queue.tracks);
    final removed = tracks.removeAt(position);
    _trimRanges.remove(removed.id);

    var index = _queue.currentIndex;
    if (position < index) {
      index--;
    } else if (position == index) {
      index = index.clamp(-1, tracks.length - 1);
    }
    _queue = _copyWith(tracks: tracks, currentIndex: index);
    return _queue;
  }

  @override
  Future<QueueState> reorder(int fromIndex, int toIndex) async {
    if (fromIndex == toIndex) return _queue;
    final tracks = List<Track>.from(_queue.tracks);
    if (fromIndex < 0 || fromIndex >= tracks.length) return _queue;
    final track = tracks.removeAt(fromIndex);
    final dest = toIndex.clamp(0, tracks.length);
    tracks.insert(dest, track);

    var index = _queue.currentIndex;
    if (fromIndex == index) {
      index = dest;
    } else if (fromIndex < index && dest >= index) {
      index--;
    } else if (fromIndex > index && dest <= index) {
      index++;
    }
    _queue = _copyWith(tracks: tracks, currentIndex: index);
    return _queue;
  }

  @override
  Future<QueueState> clear() async {
    _queue = QueueState.empty();
    _trimRanges.clear();
    return _queue;
  }

  @override
  Future<QueueState> shuffle() async {
    final upcoming = _queue.upNext;
    if (upcoming.length < 2) return _queue;
    // Deterministic, dependency-free "shuffle": reverse the upcoming tracks.
    // Enough to prove the affordance without Math.random in tests.
    final head = _queue.tracks.sublist(0, _queue.currentIndex + 1);
    final shuffled = upcoming.reversed.toList();
    _queue = _copyWith(
      tracks: [...head, ...shuffled],
      shuffled: true,
    );
    return _queue;
  }

  @override
  Map<String, TrimRange> get trimRanges => Map.unmodifiable(_trimRanges);

  @override
  Future<void> setTrimRange(String trackId, TrimRange range) async {
    if (range.isFullTrack) {
      _trimRanges.remove(trackId);
    } else {
      _trimRanges[trackId] = range;
    }
  }

  @override
  Future<MixPlan> saveMixPlan(
      QueueState queue, Map<String, TrimRange> trims) async {
    _mixPlanCounter++;
    return MixPlan(
      id: 'mix-$_mixPlanCounter',
      trackCount: queue.tracks.length,
      savedAt: _now,
    );
  }

  QueueState _copyWith({
    List<Track>? tracks,
    int? currentIndex,
    RepeatMode? repeatMode,
    bool? shuffled,
  }) =>
      QueueState(
        tracks: tracks ?? _queue.tracks,
        currentIndex: currentIndex ?? _queue.currentIndex,
        repeatMode: repeatMode ?? _queue.repeatMode,
        shuffled: shuffled ?? _queue.shuffled,
      );
}
