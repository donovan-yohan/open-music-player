import 'track.dart';

class QueueState {
  final List<QueueTrack> tracks;

  QueueState({
    required this.tracks,
  });

  factory QueueState.empty() {
    return QueueState(
      tracks: [],
    );
  }

  factory QueueState.fromJson(Map<String, dynamic> json) {
    return QueueState(
      tracks: _parseTracks(json),
    );
  }

  static List<QueueTrack> _parseTracks(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is List) {
      return items
          .map((item) => QueueTrack.fromJson(item as Map<String, dynamic>))
          .toList();
    }

    return [];
  }

  bool get isEmpty => tracks.isEmpty;
  bool get isNotEmpty => tracks.isNotEmpty;
  int get length => tracks.length;
}
