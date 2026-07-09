import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/transition_diagnostics.dart';
import 'package:open_music_player/models/timeline_clip.dart';

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
}

MixClip _clip(
  String id,
  int timelineStartMs, {
  ClipTempoMetadata tempo = ClipTempoMetadata.empty,
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
  );
}
