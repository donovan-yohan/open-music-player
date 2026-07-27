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
  final double clickAuditionVolume;
  final bool clickAuditionDownbeatAccentEnabled;
  final ClickAuditionOutputOffsets clickAuditionOutputOffsets;

  const SettingsModel({
    this.crossfadeDuration = 0,
    this.themeMode = AppThemeMode.system,
    this.keyNotation = KeyNotation.camelot,
    this.clickAuditionVolume = defaultClickAuditionVolume,
    this.clickAuditionDownbeatAccentEnabled = true,
    this.clickAuditionOutputOffsets = const ClickAuditionOutputOffsets._(),
  });

  SettingsModel copyWith({
    int? crossfadeDuration,
    AppThemeMode? themeMode,
    KeyNotation? keyNotation,
    double? clickAuditionVolume,
    bool? clickAuditionDownbeatAccentEnabled,
    ClickAuditionOutputOffsets? clickAuditionOutputOffsets,
  }) {
    return SettingsModel(
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      themeMode: themeMode ?? this.themeMode,
      keyNotation: keyNotation ?? this.keyNotation,
      clickAuditionVolume: _clampVolume(
        clickAuditionVolume ?? this.clickAuditionVolume,
      ),
      clickAuditionDownbeatAccentEnabled: clickAuditionDownbeatAccentEnabled ??
          this.clickAuditionDownbeatAccentEnabled,
      clickAuditionOutputOffsets:
          clickAuditionOutputOffsets ?? this.clickAuditionOutputOffsets,
    );
  }

  int clickAuditionOutputOffsetMsFor(ClickAuditionOutputRoute route) =>
      clickAuditionOutputOffsets.forRoute(route);

  Map<String, dynamic> toJson() {
    return {
      'crossfadeDuration': crossfadeDuration,
      'themeMode': themeMode.index,
      'keyNotation': keyNotation.name,
      'clickAuditionVolume': clickAuditionVolume,
      'clickAuditionDownbeatAccentEnabled': clickAuditionDownbeatAccentEnabled,
      'clickAuditionOutputOffsetsMs': clickAuditionOutputOffsets.toJson(),
    };
  }

  factory SettingsModel.fromJson(Map<String, dynamic> json) {
    return SettingsModel(
      crossfadeDuration: _readInt(json['crossfadeDuration']) ?? 0,
      themeMode: _themeModeFromJson(json['themeMode']),
      keyNotation: _keyNotationFromJson(json['keyNotation']),
      clickAuditionVolume: _readVolume(json['clickAuditionVolume']),
      clickAuditionDownbeatAccentEnabled: _readBool(
        json['clickAuditionDownbeatAccentEnabled'],
        fallback: true,
      ),
      clickAuditionOutputOffsets: ClickAuditionOutputOffsets.fromJson(
        json['clickAuditionOutputOffsetsMs'],
      ),
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
