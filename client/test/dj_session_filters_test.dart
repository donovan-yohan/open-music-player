import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj_session/dj_session_filters.dart';

void main() {
  group('parseDjVibeText', () {
    test('maps high-energy words locally without a query', () {
      expect(
        parseDjVibeText('Need a hype gym party mix'),
        const DjSessionFilters(energy: DjEnergy.high),
      );
    });

    test('maps calm and focus words locally without a query', () {
      expect(
        parseDjVibeText('calm study session'),
        const DjSessionFilters(energy: DjEnergy.low),
      );
    });

    test('maps literal high energy / low energy phrases', () {
      expect(
        parseDjVibeText('high energy please'),
        const DjSessionFilters(energy: DjEnergy.high),
      );
      expect(
        parseDjVibeText('something low-energy'),
        const DjSessionFilters(energy: DjEnergy.low),
      );
    });

    test('passes unrelated free text through as q', () {
      expect(
        parseDjVibeText('late-night synthwave'),
        const DjSessionFilters(query: 'late-night synthwave'),
      );
    });

    test('trims empty input into no active filters', () {
      expect(parseDjVibeText('   '), const DjSessionFilters());
    });
  });

  group('djPresetFilters', () {
    test('keeps Chill and Focus low energy, Workout and Party high energy', () {
      expect(djPresetFilters(DjVibePreset.chill).energy, DjEnergy.low);
      expect(djPresetFilters(DjVibePreset.focus).energy, DjEnergy.low);
      expect(djPresetFilters(DjVibePreset.workout).energy, DjEnergy.high);
      expect(djPresetFilters(DjVibePreset.party).energy, DjEnergy.high);
    });
  });
}
