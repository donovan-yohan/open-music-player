import 'dart:async';

import 'package:open_music_player/core/services/stems_service.dart';

class GatedStemsService implements StemsService {
  final gets = <(int, Completer<TrackStems>)>[];
  final posts = <(int, Completer<StemsRequestResult>)>[];

  @override
  Future<TrackStems> getTrackStems(int trackId,
      {String channelSet = defaultStemChannelSet}) {
    final response = Completer<TrackStems>();
    gets.add((trackId, response));
    return response.future;
  }

  @override
  Future<StemsRequestResult> requestSeparation(int trackId,
      {String channelSet = defaultStemChannelSet}) {
    final response = Completer<StemsRequestResult>();
    posts.add((trackId, response));
    return response.future;
  }
}
