import 'track.dart';

class QueueState {
  final List<Track> tracks;
  final int currentIndex;

  QueueState({
    required this.tracks,
    required this.currentIndex,
  });

  factory QueueState.empty() {
    return QueueState(
      tracks: [],
      currentIndex: -1,
    );
  }

  factory QueueState.fromJson(Map<String, dynamic> json) {
    return QueueState(
      tracks: _parseTracks(json),
      currentIndex: json['currentPosition'] as int? ?? 0,
    );
  }

  static List<Track> _parseTracks(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is List) {
      return items
          .map((item) => Track.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    return [];
  }

  Track? get currentTrack {
    if (currentIndex >= 0 && currentIndex < tracks.length) {
      return tracks[currentIndex];
    }
    return null;
  }

  List<Track> get upNext {
    if (currentIndex < 0 || currentIndex >= tracks.length - 1) {
      return [];
    }
    return tracks.sublist(currentIndex + 1);
  }

  bool get isEmpty => tracks.isEmpty;
  bool get isNotEmpty => tracks.isNotEmpty;
  int get length => tracks.length;
}
