import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/transition_diagnostics.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/widgets/analysis_correction_sheet.dart';

void main() {
  test('reports beat lock, tempo match, and harmonic compatibility', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
          camelot: '8A',
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 124,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
          camelot: '9A',
        ),
      ),
    );

    expect(
      diagnostics.diagnostics.map((diagnostic) => diagnostic.code),
      containsAll([
        TransitionDiagnosticCode.tempoMatched,
        TransitionDiagnosticCode.beatLocked,
        TransitionDiagnosticCode.harmonicCompatible,
      ]),
    );
    expect(diagnostics.hasWarnings, isFalse);
  });

  test('warns when BPM is low confidence', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.2,
          downbeatsMs: [0, 8000],
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 122,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000],
        ),
      ),
    );

    expect(
      diagnostics.diagnostics.map((diagnostic) => diagnostic.code),
      contains(TransitionDiagnosticCode.lowBpmConfidence),
    );
    expect(diagnostics.hasWarnings, isTrue);
  });

  test('warns when downbeats are offset inside the overlap', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
        ),
      ),
      _clip(
        'incoming',
        8120,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
        ),
      ),
    );

    final warning = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.downbeatOffset,
    );
    expect(warning.label, 'Downbeat +120ms');
    expect(diagnostics.hasWarnings, isTrue);
  });

  test('missing BPM and downbeat labels identify the missing side', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
        ),
      ),
      _clip('incoming', 8000),
    );

    expect(diagnostics.compactLabels, [
      'No next BPM',
      'No next downbeat',
    ]);
    expect(
      diagnostics.diagnostics.first.detail,
      contains('Missing next BPM'),
    );
  });

  test('missing BPM and downbeat labels stay specific when both sides miss',
      () {
    final diagnostics = diagnoseTransition(
      _clip('outgoing', 0),
      _clip('incoming', 8000),
    );

    expect(diagnostics.compactLabels, [
      'No current/next BPM',
      'No current/next downbeat',
    ]);
    expect(
      diagnostics.diagnostics.first.detail,
      contains('Missing current and next BPM'),
    );
  });

  test('manual correction metadata clears missing BPM and downbeat warnings',
      () {
    final overrides = analysisOverridesFromCorrectionFields(
      durationMs: 16000,
      bpm: 141.18,
      firstDownbeatMs: 87,
      phraseBeats: 4,
    );
    final correctedTempo = ClipTempoMetadata.fromAnalysisSummary(
      null,
      overrides: overrides.toJson(),
    );

    final diagnostics = diagnoseTransition(
      _clip('outgoing', 0, tempo: correctedTempo),
      _clip('incoming', 8500, tempo: correctedTempo),
    );

    final codes = diagnostics.diagnostics.map((diagnostic) => diagnostic.code);
    expect(correctedTempo.nativeBpm, closeTo(141.18, 0.001));
    expect(correctedTempo.downbeatsMs.take(2).toList(), [87, 1787]);
    expect(codes, isNot(contains(TransitionDiagnosticCode.missingBpm)));
    expect(codes, isNot(contains(TransitionDiagnosticCode.missingDownbeats)));
    expect(codes, contains(TransitionDiagnosticCode.beatLocked));
  });

  test('warns on large tempo pulls and incompatible keys', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 90,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
          camelot: '8A',
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 128,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
          camelot: '2B',
        ),
      ),
    );

    expect(
      diagnostics.diagnostics.map((diagnostic) => diagnostic.code),
      containsAll([
        TransitionDiagnosticCode.largeTempoShift,
        TransitionDiagnosticCode.harmonicClash,
      ]),
    );
    expect(diagnostics.compactLabels.first, startsWith('Tempo'));
  });

  test('warns when BPM sync would exceed the safe playback-rate range', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 60,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 220,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
        ),
      ),
    );

    final warning = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.tempoOutOfRange,
    );
    expect(warning.label, 'Tempo range');
    expect(warning.detail, contains('0.5x-2.0x'));
    expect(diagnostics.hasWarnings, isTrue);
  });

  test('reports pitch lock when tempo matching preserves pitch', () {
    final diagnostics = diagnoseTransition(
      _clip('outgoing', 0, tempo: _tempo(nativeBpm: 120)),
      _clip('incoming', 8000, tempo: _tempo(nativeBpm: 130)),
    );

    final pitch = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.pitchLockRequired,
    );
    expect(pitch.label, 'Pitch lock');
    expect(pitch.detail, contains('current and next playback speed'));
    expect(pitch.detail, contains('key lock'));
    expect(diagnostics.hasWarnings, isFalse);
  });

  test('warns when tempo matching is configured to shift pitch', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: _tempo(nativeBpm: 100),
        pitchMode: pitchModeFollowTempo,
      ),
      _clip(
        'incoming',
        8000,
        tempo: _tempo(nativeBpm: 125),
        pitchMode: pitchModeFollowTempo,
      ),
    );

    final pitch = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.pitchFollowsTempo,
    );
    expect(pitch.label, 'Pitch shift');
    expect(pitch.detail, contains('pitch will follow tempo'));
    expect(diagnostics.hasWarnings, isTrue);
  });

  test('derives harmonic compatibility from musical keys without Camelot', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: _tempo(musicalKey: 'A minor'),
      ),
      _clip(
        'incoming',
        8000,
        tempo: _tempo(musicalKey: 'E minor'),
      ),
    );

    final harmonic = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.harmonicCompatible,
    );
    expect(harmonic.label, 'Harmonic 8A->9A');
    expect(diagnostics.hasWarnings, isFalse);
  });

  test('derives harmonic clashes from key shorthand and flats', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: _tempo(musicalKey: 'Am'),
      ),
      _clip(
        'incoming',
        8000,
        tempo: _tempo(musicalKey: 'Gb major'),
      ),
    );

    final harmonic = diagnostics.diagnostics.firstWhere(
      (diagnostic) => diagnostic.code == TransitionDiagnosticCode.harmonicClash,
    );
    expect(harmonic.label, 'Key clash 8A->2B');
    expect(diagnostics.hasWarnings, isTrue);
  });

  test('prefers explicit Camelot over derived musical key', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: _tempo(musicalKey: 'A minor', camelot: '2B'),
      ),
      _clip(
        'incoming',
        8000,
        tempo: _tempo(musicalKey: 'E minor', camelot: '8A'),
      ),
    );

    final harmonic = diagnostics.diagnostics.firstWhere(
      (diagnostic) => diagnostic.code == TransitionDiagnosticCode.harmonicClash,
    );
    expect(harmonic.label, 'Key clash 2B->8A');
  });
}

MixClip _clip(
  String id,
  int timelineStartMs, {
  ClipTempoMetadata tempo = ClipTempoMetadata.empty,
  String pitchMode = pitchModePreserve,
}) {
  return MixClip(
    placement: TimelineClip.clamped(
      id: id,
      trackId: id,
      sourceDurationMs: 16000,
      sourceStartMs: 0,
      sourceEndMs: 16000,
      timelineStartMs: timelineStartMs,
    ),
    tempo: tempo,
    pitchMode: pitchMode,
  );
}

ClipTempoMetadata _tempo({
  double nativeBpm = 120,
  String? musicalKey,
  String? camelot,
}) {
  return ClipTempoMetadata(
    nativeBpm: nativeBpm,
    bpmConfidence: 0.9,
    downbeatsMs: const [0, 8000, 16000],
    musicalKey: musicalKey,
    camelot: camelot,
  );
}
