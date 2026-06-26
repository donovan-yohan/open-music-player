import 'dart:async';

import 'package:flutter/services.dart';

class SharedIntentReceiver {
  static const MethodChannel _methodChannel = MethodChannel(
    'open_music_player/share_intents',
  );
  static const EventChannel _eventChannel = EventChannel(
    'open_music_player/share_intents/events',
  );

  Future<String?> initialSharedText() async {
    try {
      return await _methodChannel.invokeMethod<String>('getInitialSharedText');
    } on MissingPluginException {
      return null;
    }
  }

  Stream<String> sharedTextStream() async* {
    await for (final event in _eventChannel.receiveBroadcastStream()) {
      if (event is String) yield event;
    }
  }
}
