/// Audio quality options for streaming and downloads
enum AudioQuality {
  low,
  normal,
  high;

  String get displayName {
    switch (this) {
      case AudioQuality.low:
        return 'Low (128 kbps)';
      case AudioQuality.normal:
        return 'Normal (256 kbps)';
      case AudioQuality.high:
        return 'High (320 kbps)';
    }
  }

  int get bitrate {
    switch (this) {
      case AudioQuality.low:
        return 128;
      case AudioQuality.normal:
        return 256;
      case AudioQuality.high:
        return 320;
    }
  }
}

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

/// Application settings model
class SettingsModel {
  final AudioQuality streamingQuality;
  final AudioQuality downloadQuality;
  final bool gaplessPlayback;
  final int crossfadeDuration;
  final AppThemeMode themeMode;
  final KeyNotation keyNotation;

  const SettingsModel({
    this.streamingQuality = AudioQuality.high,
    this.downloadQuality = AudioQuality.high,
    this.gaplessPlayback = true,
    this.crossfadeDuration = 0,
    this.themeMode = AppThemeMode.system,
    this.keyNotation = KeyNotation.camelot,
  });

  SettingsModel copyWith({
    AudioQuality? streamingQuality,
    AudioQuality? downloadQuality,
    bool? gaplessPlayback,
    int? crossfadeDuration,
    AppThemeMode? themeMode,
    KeyNotation? keyNotation,
  }) {
    return SettingsModel(
      streamingQuality: streamingQuality ?? this.streamingQuality,
      downloadQuality: downloadQuality ?? this.downloadQuality,
      gaplessPlayback: gaplessPlayback ?? this.gaplessPlayback,
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      themeMode: themeMode ?? this.themeMode,
      keyNotation: keyNotation ?? this.keyNotation,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'streamingQuality': streamingQuality.index,
      'downloadQuality': downloadQuality.index,
      'gaplessPlayback': gaplessPlayback,
      'crossfadeDuration': crossfadeDuration,
      'themeMode': themeMode.index,
      'keyNotation': keyNotation.name,
    };
  }

  factory SettingsModel.fromJson(Map<String, dynamic> json) {
    return SettingsModel(
      streamingQuality: AudioQuality.values[json['streamingQuality'] ?? 2],
      downloadQuality: AudioQuality.values[json['downloadQuality'] ?? 2],
      gaplessPlayback: json['gaplessPlayback'] ?? true,
      crossfadeDuration: json['crossfadeDuration'] ?? 0,
      themeMode: AppThemeMode.values[json['themeMode'] ?? 0],
      keyNotation: _keyNotationFromJson(json['keyNotation']),
    );
  }
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
