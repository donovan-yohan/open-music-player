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

final _highEnergyWords = RegExp(r'\b(energetic|hype|gym|party|dance|high[ -]energy)\b');
final _lowEnergyWords = RegExp(r'\b(chill|calm|sleep|focus|study|low[ -]energy)\b');
