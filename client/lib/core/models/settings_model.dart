/// Theme mode options
enum AppThemeMode {
  system,
  light,
  dark;

  String get displayName {
    switch (this) {
      case AppThemeMode.system:
        return 'System';
      case AppThemeMode.light:
        return 'Light';
      case AppThemeMode.dark:
        return 'Dark';
    }
  }
}

enum KeyNotation {
  camelot,
  musical;

  String get displayName => switch (this) {
        KeyNotation.camelot => 'Camelot',
        KeyNotation.musical => 'Musical key',
      };
}

/// What playback does when the listening queue reaches its natural end with
/// repeat off (#352).
///
/// [off] is the historical behavior: the player publishes `completed` and goes
/// silent. [shuffleLibrary] appends a shuffled batch of library tracks as an
/// auto-continuation segment and keeps playing.
///
/// Phase 2 of #352 adds a third mode, similar-track radio. It is deliberately
/// NOT declared here yet: no recommendation source exists, so a selectable
/// option would be a lie in the UI and would persist a value the playback core
/// could not honor on the next launch. Adding it is a one-line enum value plus
/// a `QueueContinuationSource` implementation — see
/// `lib/core/audio/queue_continuation.dart`.
enum EndOfQueueMode {
  off,
  shuffleLibrary;
  // similarRadio, — phase 2 (#352).

  String get displayName => switch (this) {
        EndOfQueueMode.off => 'Off',
        EndOfQueueMode.shuffleLibrary => 'Shuffle library',
      };

  String get description => switch (this) {
        EndOfQueueMode.off => 'Playback stops when the queue runs out',
        EndOfQueueMode.shuffleLibrary =>
          'Keep playing shuffled tracks from your library',
      };
}

/// Where a "queue this track" gesture drops the track in the user queue.
///
/// Both modes tag the item `queueOriginManual`, so both survive a context
/// switch the same way; they differ only in where inside the user queue the
/// track lands. [addToQueue] appends after everything already queued by hand,
/// [playNext] jumps the line and plays right after the current track.
enum QueueInsertMode {
  addToQueue,
  playNext;

  String get displayName => switch (this) {
        QueueInsertMode.addToQueue => 'Add to queue',
        QueueInsertMode.playNext => 'Play next',
      };

  String get description => switch (this) {
        QueueInsertMode.addToQueue =>
          'Queue after anything you have already queued',
        QueueInsertMode.playNext => 'Queue ahead of anything you have '
            'already queued',
      };

  /// Confirmation copy for a completed queue gesture on [title]. Kept beside
  /// the mode so every surface that offers the gesture reports the same thing.
  String confirmationFor(String title) => switch (this) {
        QueueInsertMode.addToQueue => 'Added "$title" to queue',
        QueueInsertMode.playNext => 'Playing "$title" next',
      };
}

const double defaultClickAuditionVolume = 0.20;
const int minClickAuditionOutputOffsetMs = -500;
const int maxClickAuditionOutputOffsetMs = 500;

/// Stable, device-local calibration buckets for click audition.
///
/// These keys describe a coarse output category, not a server-side or
/// track-analysis fact.
enum ClickAuditionOutputRoute {
  bluetooth,
  wired,
  speaker,
  other,
  unknown,
}

/// Immutable route-specific output offsets for click audition.
///
/// Offsets compensate for local output latency. They must never be applied to
/// beat-grid timestamps or serialized as track analysis.
class ClickAuditionOutputOffsets {
  final int bluetooth;
  final int wired;
  final int speaker;
  final int other;
  final int unknown;

  const ClickAuditionOutputOffsets._({
    this.bluetooth = 0,
    this.wired = 0,
    this.speaker = 0,
    this.other = 0,
    this.unknown = 0,
  });

  factory ClickAuditionOutputOffsets({
    int bluetooth = 0,
    int wired = 0,
    int speaker = 0,
    int other = 0,
    int unknown = 0,
  }) {
    return ClickAuditionOutputOffsets._(
      bluetooth: _clampOutputOffset(bluetooth),
      wired: _clampOutputOffset(wired),
      speaker: _clampOutputOffset(speaker),
      other: _clampOutputOffset(other),
      unknown: _clampOutputOffset(unknown),
    );
  }

  factory ClickAuditionOutputOffsets.fromJson(Object? value) {
    if (value is! Map) return const ClickAuditionOutputOffsets._();

    return ClickAuditionOutputOffsets(
      bluetooth: _readOutputOffset(value['bluetooth']),
      wired: _readOutputOffset(value['wired']),
      speaker: _readOutputOffset(value['speaker']),
      other: _readOutputOffset(value['other']),
      unknown: _readOutputOffset(value['unknown']),
    );
  }

  int forRoute(ClickAuditionOutputRoute route) {
    return switch (route) {
      ClickAuditionOutputRoute.bluetooth => bluetooth,
      ClickAuditionOutputRoute.wired => wired,
      ClickAuditionOutputRoute.speaker => speaker,
      ClickAuditionOutputRoute.other => other,
      ClickAuditionOutputRoute.unknown => unknown,
    };
  }

  ClickAuditionOutputOffsets withOffset(
    ClickAuditionOutputRoute route,
    int offsetMs,
  ) {
    final clamped = _clampOutputOffset(offsetMs);
    return ClickAuditionOutputOffsets(
      bluetooth:
          route == ClickAuditionOutputRoute.bluetooth ? clamped : bluetooth,
      wired: route == ClickAuditionOutputRoute.wired ? clamped : wired,
      speaker: route == ClickAuditionOutputRoute.speaker ? clamped : speaker,
      other: route == ClickAuditionOutputRoute.other ? clamped : other,
      unknown: route == ClickAuditionOutputRoute.unknown ? clamped : unknown,
    );
  }

  /// A stable-order, immutable view suitable for UI iteration.
  Map<String, int> get asMap => Map.unmodifiable(toJson());

  /// Returns a fresh canonical map for JSON encoding.
  Map<String, int> toJson() => {
        for (final route in ClickAuditionOutputRoute.values)
          route.name: forRoute(route),
      };

  @override
  bool operator ==(Object other) {
    return other is ClickAuditionOutputOffsets &&
        other.bluetooth == bluetooth &&
        other.wired == wired &&
        other.speaker == speaker &&
        other.other == this.other &&
        other.unknown == unknown;
  }

  @override
  int get hashCode => Object.hash(bluetooth, wired, speaker, other, unknown);
}

/// Application settings model
class SettingsModel {
  final int crossfadeDuration;
  final AppThemeMode themeMode;
  final KeyNotation keyNotation;

  /// What happens when the listening queue reaches its natural end. Defaults to
  /// [EndOfQueueMode.off] so an upgrade preserves the existing "stop when the
  /// queue runs out" behavior until the listener opts in.
  final EndOfQueueMode endOfQueueMode;

  /// Where a swipe-to-queue gesture drops the track. Defaults to
  /// [QueueInsertMode.addToQueue], which is what the swipe has always done, so
  /// the setting only ever changes the gesture for listeners who ask it to.
  final QueueInsertMode swipeQueueMode;

  /// Whether the user queue outlives the passive queue it was built on top of.
  ///
  /// Defaults to true: manually queued tracks are the listener's own choices,
  /// and starting a different playlist is a statement about what plays *after*
  /// them, not a request to throw them away. Turning it off restores the older
  /// behavior where starting a new collection replaces the whole queue.
  final bool preserveManualQueue;
  final double clickAuditionVolume;
  final bool clickAuditionDownbeatAccentEnabled;
  final ClickAuditionOutputOffsets clickAuditionOutputOffsets;

  /// Whether the experimental DJ deck entry point is offered.
  ///
  /// The deck drives two audio voices of its own, outside the
  /// `QueueTimelineController` that ADR 0001 makes the single playback
  /// authority. That exception is sanctioned but scoped (see the ADR 0001
  /// addendum), and this flag is the runtime switch that bounds it: turning it
  /// off removes the only way into the deck, so normal playback runs with the
  /// canonical voice pool alone.
  final bool djModeEnabled;

  const SettingsModel({
    this.crossfadeDuration = 0,
    this.themeMode = AppThemeMode.system,
    this.keyNotation = KeyNotation.camelot,
    this.endOfQueueMode = EndOfQueueMode.off,
    this.swipeQueueMode = QueueInsertMode.addToQueue,
    this.preserveManualQueue = true,
    this.clickAuditionVolume = defaultClickAuditionVolume,
    this.clickAuditionDownbeatAccentEnabled = true,
    this.clickAuditionOutputOffsets = const ClickAuditionOutputOffsets._(),
    this.djModeEnabled = true,
  });

  SettingsModel copyWith({
    int? crossfadeDuration,
    AppThemeMode? themeMode,
    KeyNotation? keyNotation,
    EndOfQueueMode? endOfQueueMode,
    QueueInsertMode? swipeQueueMode,
    bool? preserveManualQueue,
    double? clickAuditionVolume,
    bool? clickAuditionDownbeatAccentEnabled,
    ClickAuditionOutputOffsets? clickAuditionOutputOffsets,
    bool? djModeEnabled,
  }) {
    return SettingsModel(
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      themeMode: themeMode ?? this.themeMode,
      keyNotation: keyNotation ?? this.keyNotation,
      endOfQueueMode: endOfQueueMode ?? this.endOfQueueMode,
      swipeQueueMode: swipeQueueMode ?? this.swipeQueueMode,
      preserveManualQueue: preserveManualQueue ?? this.preserveManualQueue,
      clickAuditionVolume: _clampVolume(
        clickAuditionVolume ?? this.clickAuditionVolume,
      ),
      clickAuditionDownbeatAccentEnabled: clickAuditionDownbeatAccentEnabled ??
          this.clickAuditionDownbeatAccentEnabled,
      clickAuditionOutputOffsets:
          clickAuditionOutputOffsets ?? this.clickAuditionOutputOffsets,
      djModeEnabled: djModeEnabled ?? this.djModeEnabled,
    );
  }

  int clickAuditionOutputOffsetMsFor(ClickAuditionOutputRoute route) =>
      clickAuditionOutputOffsets.forRoute(route);

  Map<String, dynamic> toJson() {
    return {
      'crossfadeDuration': crossfadeDuration,
      'themeMode': themeMode.index,
      'keyNotation': keyNotation.name,
      'endOfQueueMode': endOfQueueMode.name,
      'swipeQueueMode': swipeQueueMode.name,
      'preserveManualQueue': preserveManualQueue,
      'clickAuditionVolume': clickAuditionVolume,
      'clickAuditionDownbeatAccentEnabled': clickAuditionDownbeatAccentEnabled,
      'clickAuditionOutputOffsetsMs': clickAuditionOutputOffsets.toJson(),
      'djModeEnabled': djModeEnabled,
    };
  }

  factory SettingsModel.fromJson(Map<String, dynamic> json) {
    return SettingsModel(
      crossfadeDuration: _readInt(json['crossfadeDuration']) ?? 0,
      themeMode: _themeModeFromJson(json['themeMode']),
      keyNotation: _keyNotationFromJson(json['keyNotation']),
      endOfQueueMode: _endOfQueueModeFromJson(json['endOfQueueMode']),
      swipeQueueMode: _queueInsertModeFromJson(json['swipeQueueMode']),
      // Absent means the listener upgraded without choosing, which lands on
      // the default rather than silently opting them out of the feature.
      preserveManualQueue: _readBool(
        json['preserveManualQueue'],
        fallback: true,
      ),
      clickAuditionVolume: _readVolume(json['clickAuditionVolume']),
      clickAuditionDownbeatAccentEnabled: _readBool(
        json['clickAuditionDownbeatAccentEnabled'],
        fallback: true,
      ),
      clickAuditionOutputOffsets: ClickAuditionOutputOffsets.fromJson(
        json['clickAuditionOutputOffsetsMs'],
      ),
      // Absent from an existing stored blob means "never chosen", which lands
      // on the default rather than silently disabling the feature on upgrade.
      djModeEnabled: _readBool(json['djModeEnabled'], fallback: true),
    );
  }
}

AppThemeMode _themeModeFromJson(Object? value) {
  final index = _readInt(value);
  if (index == null || index < 0 || index >= AppThemeMode.values.length) {
    return AppThemeMode.system;
  }
  return AppThemeMode.values[index];
}

KeyNotation _keyNotationFromJson(Object? value) {
  if (value is int && value >= 0 && value < KeyNotation.values.length) {
    return KeyNotation.values[value];
  }
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'musical' || 'musical_key' || 'raw' => KeyNotation.musical,
    _ => KeyNotation.camelot,
  };
}

/// Reads a persisted [EndOfQueueMode], defaulting to [EndOfQueueMode.off].
///
/// Unknown names fall back to `off` on purpose: a snapshot written by a newer
/// build (phase 2's radio mode, say) must degrade to "stop at the end of the
/// queue" rather than to some other continuation the running build would drive
/// without the listener having chosen it.
EndOfQueueMode _endOfQueueModeFromJson(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'shufflelibrary' || 'shuffle_library' => EndOfQueueMode.shuffleLibrary,
    _ => EndOfQueueMode.off,
  };
}

/// Reads a persisted [QueueInsertMode], defaulting to
/// [QueueInsertMode.addToQueue] — the behavior swipe-to-queue shipped with.
QueueInsertMode _queueInsertModeFromJson(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'playnext' || 'play_next' => QueueInsertMode.playNext,
    _ => QueueInsertMode.addToQueue,
  };
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    if (parsed != null && parsed.isFinite) return parsed.round();
  }
  return null;
}

int _readOutputOffset(Object? value) {
  return _clampOutputOffset(_readInt(value) ?? 0);
}

int _clampOutputOffset(int value) {
  return value.clamp(
    minClickAuditionOutputOffsetMs,
    maxClickAuditionOutputOffsetMs,
  );
}

double _readVolume(Object? value) {
  if (value is num && value.isFinite) return _clampVolume(value.toDouble());
  if (value is String) {
    final parsed = double.tryParse(value.trim());
    if (parsed != null && parsed.isFinite) return _clampVolume(parsed);
  }
  return defaultClickAuditionVolume;
}

double _clampVolume(double value) {
  if (!value.isFinite) return defaultClickAuditionVolume;
  return value.clamp(0.0, 1.0);
}

bool _readBool(Object? value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) {
    if (value == 1) return true;
    if (value == 0) return false;
  }
  return switch (value?.toString().trim().toLowerCase()) {
    'true' => true,
    'false' => false,
    _ => fallback,
  };
}
