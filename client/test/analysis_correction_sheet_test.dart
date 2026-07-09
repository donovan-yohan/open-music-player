import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/widgets/analysis_correction_sheet.dart';

void main() {
  test('correction fields generate beat grid and downbeat phrase markers', () {
    final overrides = analysisOverridesFromCorrectionFields(
      durationMs: 8000,
      bpm: 120,
      firstDownbeatMs: 1000,
      phraseBeats: 4,
      musicalKey: 'A minor',
      camelot: '8A',
    );

    expect(overrides.bpm, 120);
    expect(overrides.beatsMs?.take(5).toList(), [0, 500, 1000, 1500, 2000]);
    expect(overrides.downbeatsMs, [1000, 3000, 5000, 7000]);
    expect(overrides.musicalKey, 'A minor');
    expect(overrides.camelot, '8A');
  });
}
