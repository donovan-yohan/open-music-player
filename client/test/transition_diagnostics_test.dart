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

  test('distinguishes low-confidence downbeat markers from missing markers',
      () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
          downbeatConfidence: 0.9,
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000, 16000],
          downbeatConfidence: 0.419,
        ),
      ),
    );

    final warning = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.lowDownbeatConfidence,
    );
    expect(warning.label, 'Incoming downbeat confidence 42%');
    expect(warning.isDownbeatLockAdvisory, isTrue);
    expect(
      diagnostics.diagnostics.map((diagnostic) => diagnostic.code),
      isNot(contains(TransitionDiagnosticCode.missingDownbeats)),
    );
  });

  test('marks downbeat advisories informational when snap mode is free', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000],
          downbeatConfidence: 0.9,
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [0, 8000],
          downbeatConfidence: 0.419,
        ),
      ),
      snapMode: BeatSnapMode.free,
    );

    final warning = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.lowDownbeatConfidence,
    );
    expect(warning.severity, TransitionDiagnosticSeverity.info);
    expect(diagnostics.hasWarnings, isFalse);
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

  test('validates downbeat lock through tempo automation timing', () {
    final model = TimelineModel(
      clips: [
        _clip(
          'outgoing',
          0,
          durationMs: 24000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 120,
            bpmConfidence: 0.9,
            downbeatsMs: [0, 4000, 8000, 12000, 16000, 20000],
          ),
        ),
        _clip(
          'incoming',
          13500,
          durationMs: 24000,
          tempo: const ClipTempoMetadata(
            nativeBpm: 150,
            bpmConfidence: 0.9,
            downbeatsMs: [2000, 3600, 5200, 6800],
          ),
        ),
      ],
    );
    final diagnostics = diagnoseTransition(model.clips[0], model.clips[1]);
    final codes = diagnostics.diagnostics.map((item) => item.code).toList();

    expect(codes, contains(TransitionDiagnosticCode.beatLocked));
    expect(codes, isNot(contains(TransitionDiagnosticCode.downbeatOffset)));
  });

  test('beat lock requires both markers inside the exact overlap', () {
    final outside = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [7999],
          downbeatConfidence: 0.9,
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [1],
          downbeatConfidence: 0.9,
        ),
      ),
    );
    final inside = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [8001],
          downbeatConfidence: 0.9,
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [1],
          downbeatConfidence: 0.9,
        ),
      ),
    );

    expect(
      outside.diagnostics.map((diagnostic) => diagnostic.code),
      isNot(contains(TransitionDiagnosticCode.beatLocked)),
    );
    expect(
      outside.diagnostics.map((diagnostic) => diagnostic.code),
      contains(TransitionDiagnosticCode.downbeatOffset),
    );
    expect(
      inside.diagnostics.map((diagnostic) => diagnostic.code),
      contains(TransitionDiagnosticCode.beatLocked),
    );
  });

  test('markers at the overlap end cannot prove beat lock', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [16000],
          downbeatConfidence: 0.9,
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [8000],
          downbeatConfidence: 0.9,
        ),
      ),
    );
    final codes = diagnostics.diagnostics.map((item) => item.code);

    expect(diagnostics.overlapEndMs, 16000);
    expect(codes, isNot(contains(TransitionDiagnosticCode.beatLocked)));
    expect(codes, contains(TransitionDiagnosticCode.downbeatOffset));
    expect(
      diagnostics.diagnostics
          .firstWhere(
            (item) => item.code == TransitionDiagnosticCode.downbeatOffset,
          )
          .label,
      'Downbeat +0ms',
    );
  });

  test('inside pair takes precedence over a nearer tolerance-only pair', () {
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [9000, 16000],
          downbeatConfidence: 0.9,
        ),
      ),
      _clip(
        'incoming',
        8000,
        tempo: const ClipTempoMetadata(
          nativeBpm: 120,
          bpmConfidence: 0.9,
          downbeatsMs: [1010, 8001],
          downbeatConfidence: 0.9,
        ),
      ),
    );
    final codes = diagnostics.diagnostics.map((item) => item.code);
    final lock = diagnostics.diagnostics.firstWhere(
      (item) => item.code == TransitionDiagnosticCode.beatLocked,
    );

    expect(codes, contains(TransitionDiagnosticCode.beatLocked));
    expect(codes, isNot(contains(TransitionDiagnosticCode.downbeatOffset)));
    expect(lock.detail, 'Nearest downbeats are 10ms apart.');
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
      diagnostics.diagnostics.map((diagnostic) => diagnostic.code),
      contains(TransitionDiagnosticCode.missingDownbeats),
    );
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
    expect(correctedTempo.downbeatConfidence, 1.0);
    expect(correctedTempo.downbeatProvenance, manualTempoProvenance);
    expect(codes, isNot(contains(TransitionDiagnosticCode.missingBpm)));
    expect(codes, isNot(contains(TransitionDiagnosticCode.missingDownbeats)));
    expect(codes, contains(TransitionDiagnosticCode.beatLocked));
  });

  test('manual downbeat correction clears the analyzer confidence warning', () {
    final correctedTempo = ClipTempoMetadata.fromAnalysisSummary(
      {
        'bpm': {'value': 120, 'confidence': 0.9},
        'downbeats': {
          'positions_ms': [0, 4000, 8000, 12000],
          'confidence': 0.419,
        },
      },
      overrides: const {
        'downbeats': {
          'positions_ms': [100, 4100, 8100, 12100],
        },
      },
    );
    final diagnostics = diagnoseTransition(
      _clip('outgoing', 0, tempo: correctedTempo),
      _clip('incoming', 8000, tempo: correctedTempo),
    );

    expect(correctedTempo.downbeatConfidence, 1.0);
    expect(correctedTempo.downbeatProvenance, manualTempoProvenance);
    expect(
      diagnostics.diagnostics.map((diagnostic) => diagnostic.code),
      isNot(contains(TransitionDiagnosticCode.lowDownbeatConfidence)),
    );
  });

  test('reports trustworthy markers outside selected clips as unusable', () {
    const trustworthyMarkers = ClipTempoMetadata(
      nativeBpm: 120,
      bpmConfidence: 0.9,
      downbeatsMs: [0],
      downbeatConfidence: 0.9,
    );
    final diagnostics = diagnoseTransition(
      _clip(
        'outgoing',
        0,
        sourceStartMs: 8000,
        tempo: trustworthyMarkers,
      ),
      _clip(
        'incoming',
        4000,
        sourceStartMs: 8000,
        tempo: trustworthyMarkers,
      ),
    );

    final warning = diagnostics.diagnostics.firstWhere(
      (diagnostic) =>
          diagnostic.code == TransitionDiagnosticCode.noUsableDownbeatMarker,
    );
    expect(warning.label, 'No usable downbeat');
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
          nativeBpm: 500,
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
  int durationMs = 16000,
  int sourceStartMs = 0,
  int? sourceEndMs,
  ClipTempoMetadata tempo = ClipTempoMetadata.empty,
  String pitchMode = pitchModePreserve,
}) {
  return MixClip(
    placement: TimelineClip.clamped(
      id: id,
      trackId: id,
      sourceDurationMs: durationMs,
      sourceStartMs: sourceStartMs,
      sourceEndMs: sourceEndMs ?? durationMs,
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
