import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SharedIntentReceiver {
  SharedIntentReceiver()
      : _supportsPlatformChannels =
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const MethodChannel _methodChannel = MethodChannel(
    'open_music_player/share_intents',
  );
  static const EventChannel _eventChannel = EventChannel(
    'open_music_player/share_intents/events',
  );
  final bool _supportsPlatformChannels;

  Future<String?> initialSharedText() async {
    if (!_supportsPlatformChannels) return null;

    try {
      return await _methodChannel.invokeMethod<String>('getInitialSharedText');
    } on MissingPluginException {
      return null;
    }
  }

  Stream<String> sharedTextStream() async* {
    if (!_supportsPlatformChannels) return;

    await for (final event in _eventChannel.receiveBroadcastStream()) {
      if (event is String) yield event;
    }
  }
}
