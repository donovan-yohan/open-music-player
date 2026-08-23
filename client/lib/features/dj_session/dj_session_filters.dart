import 'package:flutter/foundation.dart';

enum DjEnergy { low, medium, high }

extension DjEnergyWireValue on DjEnergy {
  String get wireValue => name;

  String get label => switch (this) {
        DjEnergy.low => 'Low',
        DjEnergy.medium => 'Mid',
        DjEnergy.high => 'High',
      };

  /// Copy-table label for active-filter chips: `Low energy`, `Mid energy`,
  /// `High energy`.
  String get chipLabel => label;
}

enum DjVibePreset { chill, workout, focus, party }

extension DjVibePresetLabel on DjVibePreset {
  String get label => switch (this) {
        DjVibePreset.chill => 'Chill',
        DjVibePreset.workout => 'Workout',
        DjVibePreset.focus => 'Focus',
        DjVibePreset.party => 'Party',
      };
}

@immutable
class DjSessionFilters {
  const DjSessionFilters({this.energy, this.query});

  final DjEnergy? energy;
  final String? query;

  bool get isEmpty => energy == null && (query == null || query!.isEmpty);

  DjSessionFilters copyWith({
    DjEnergy? energy,
    String? query,
    bool clearEnergy = false,
    bool clearQuery = false,
  }) {
    return DjSessionFilters(
      energy: clearEnergy ? null : energy ?? this.energy,
      query: clearQuery ? null : query ?? this.query,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DjSessionFilters &&
        other.energy == energy &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(energy, query);
}

/// Parses a request locally so this purely presentational convenience never
/// makes an extra network request. Strong energy terms take precedence when a
/// phrase happens to contain both high- and low-energy vocabulary.
DjSessionFilters parseDjVibeText(String rawText) {
  final query = rawText.trim();
  if (query.isEmpty) return const DjSessionFilters();

  final normalized = query.toLowerCase();
  if (_highEnergyWords.hasMatch(normalized)) {
    return const DjSessionFilters(energy: DjEnergy.high);
  }
  if (_lowEnergyWords.hasMatch(normalized)) {
    return const DjSessionFilters(energy: DjEnergy.low);
  }
  return DjSessionFilters(query: query);
}

/// The lineup API currently exposes energy rather than a BPM target. Focus is
/// deliberately low-energy for now; keeping this mapping here makes that
/// temporary product choice explicit instead of pretending a BPM filter exists.
DjSessionFilters djPresetFilters(DjVibePreset preset) {
  return switch (preset) {
    DjVibePreset.chill ||
    DjVibePreset.focus =>
      const DjSessionFilters(energy: DjEnergy.low),
    DjVibePreset.workout ||
    DjVibePreset.party =>
      const DjSessionFilters(energy: DjEnergy.high),
  };
}

/// A local, time-of-day prompt suggestion shown when the request bar is empty.
@immutable
class DjPromptSuggestion {
  const DjPromptSuggestion({required this.label, required this.text});

  /// Short chip label. Also the deterministic rotation key.
  final String label;

  /// Text submitted through the typed-request pipeline when tapped.
  final String text;
}

/// The two time-of-day suggestions for [now], paired with the always-present
/// "Something new". The time-of-day pair rotates deterministically by
/// day-of-week so the pairing changes daily without any network call:
///
/// - morning (before 11:00): "Slow start", "Coffee first"
/// - midday (11:00–18:00):   "Focus mode", "Reset"
/// - evening (18:00+):       "Wind down", "Late drive"
List<DjPromptSuggestion> djPromptSuggestions({DateTime? now}) {
  final moment = now ?? DateTime.now();
  const morningPair = [
    DjPromptSuggestion(label: 'Slow start', text: 'slow start'),
    DjPromptSuggestion(label: 'Coffee first', text: 'coffee first'),
  ];
  const middayPair = [
    DjPromptSuggestion(label: 'Focus mode', text: 'focus mode'),
    DjPromptSuggestion(label: 'Reset', text: 'reset'),
  ];
  const eveningPair = [
    DjPromptSuggestion(label: 'Wind down', text: 'wind down'),
    DjPromptSuggestion(label: 'Late drive', text: 'late drive'),
  ];

  final pair = switch (moment.hour) {
    < 11 => morningPair,
    >= 18 => eveningPair,
    _ => middayPair,
  };
  // Rotate within the pair by day-of-week; "Something new" is always present.
  final rotated = moment.weekday.isOdd ? pair : [pair[1], pair[0]];
  return [
    ...rotated,
    const DjPromptSuggestion(label: 'Something new', text: 'something new'),
  ];
}

final _highEnergyWords = RegExp(r'\b(energetic|hype|gym|party|dance|high[ -]energy)\b');
final _lowEnergyWords = RegExp(r'\b(chill|calm|sleep|focus|study|low[ -]energy)\b');
