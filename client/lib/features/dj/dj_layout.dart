import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/dj_deck_state.dart';
import 'models/dj_hot_cue.dart';
import 'providers/dj_session_provider.dart';
import 'widgets/dj_crossfader.dart';
import 'widgets/dj_deck_header.dart';
import 'widgets/dj_hot_cue_pads.dart';
import 'widgets/dj_loop_panel.dart';
import 'widgets/dj_mixer_panel.dart';
import 'widgets/dj_overview_strip.dart';
import 'widgets/dj_panel_switcher.dart';
import 'widgets/dj_pitch_fader.dart';
import 'widgets/dj_stem_panel.dart';
import 'widgets/dj_transport.dart';
import 'widgets/dj_waveform_lane.dart';

class DjLayout extends StatefulWidget {
  const DjLayout({super.key});
  @override
  State<DjLayout> createState() => _DjLayoutState();
}

class _DjLayoutState extends State<DjLayout> {
  final _panels = <DjDeckId, DjPanel>{
    DjDeckId.a: DjPanel.cues,
    DjDeckId.b: DjPanel.cues,
  };

  @override
  Widget build(BuildContext context) {
    final session = context.watch<DjSessionProvider>();
    final aTrack = session.deckA.queueTrack;
    final bTrack = session.deckB.queueTrack;
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            SizedBox(
              key: const ValueKey('dj_waveform_stack'),
              height: 120,
              child: Column(
                children: [
                  Expanded(
                    child: DjWaveformLane(
                      deck: session.deckA,
                      track: aTrack,
                      color: Colors.lightBlue,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: DjWaveformLane(
                      deck: session.deckB,
                      track: bTrack,
                      color: Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: _HeaderOverview(
                      deck: session.deckA,
                      cues: session.hotCuesFor(DjDeckId.a),
                      onSeek: (ms) => session.seek(DjDeckId.a, ms),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _HeaderOverview(
                      deck: session.deckB,
                      cues: session.hotCuesFor(DjDeckId.b),
                      onSeek: (ms) => session.seek(DjDeckId.b, ms),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: Row(
                    children: [
                      Expanded(
                        child: _DeckControl(
                          deck: session.deckA,
                          panel: _panels[DjDeckId.a]!,
                          session: session,
                          onPanel: (panel) =>
                              setState(() => _panels[DjDeckId.a] = panel),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 128,
                        child: DjMixerPanel(
                          deckA: session.deckA,
                          deckB: session.deckB,
                          onGainA: (v) => session.setChannelGain(DjDeckId.a, v),
                          onGainB: (v) => session.setChannelGain(DjDeckId.b, v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DeckControl(
                          deck: session.deckB,
                          panel: _panels[DjDeckId.b]!,
                          session: session,
                          onPanel: (panel) =>
                              setState(() => _panels[DjDeckId.b] = panel),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  Expanded(
                    child: _Transport(
                      deck: DjDeckId.a,
                      state: session.deckA,
                      session: session,
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: DjCrossfader(
                      value: session.crossfader,
                      onChanged: session.setCrossfader,
                    ),
                  ),
                  Expanded(
                    child: _Transport(
                      deck: DjDeckId.b,
                      state: session.deckB,
                      session: session,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderOverview extends StatelessWidget {
  const _HeaderOverview({
    required this.deck,
    required this.cues,
    required this.onSeek,
  });
  final DjDeckState deck;
  final List<DjHotCue> cues;
  final ValueChanged<int> onSeek;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(child: DjDeckHeader(deck: deck)),
          DjOverviewStrip(
            durationMs: deck.durationMs,
            positionMs: deck.positionMs,
            cues: cues,
            onSeek: onSeek,
          ),
        ],
      );
}

class _DeckControl extends StatelessWidget {
  const _DeckControl({
    required this.deck,
    required this.panel,
    required this.session,
    required this.onPanel,
  });
  final DjDeckState deck;
  final DjPanel panel;
  final DjSessionProvider session;
  final ValueChanged<DjPanel> onPanel;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(
            width: 48,
            child: DjPitchFader(
              percent: deck.ratePercent,
              onChanged: (value) => session.setPitchPercent(deck.deckId, value),
              onNudgeStart: (value) =>
                  session.nudgePitchStart(deck.deckId, value),
              onNudgeEnd: () => session.nudgePitchEnd(deck.deckId),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              children: [
                DjPanelSwitcher(selected: panel, onSelected: onPanel),
                const SizedBox(height: 6),
                Expanded(child: _panel()),
              ],
            ),
          ),
        ],
      );
  Widget _panel() => switch (panel) {
        DjPanel.cues => DjHotCuePads(
            cues: {
              for (final cue in session.hotCuesFor(deck.deckId)) cue.slot: cue
            },
            onTrigger: (slot) => session.triggerHotCue(deck.deckId, slot),
            onSet: (slot) => session.setHotCue(deck.deckId, slot),
          ),
        DjPanel.loop => DjLoopPanel(
            onLoop: (beats) => session.setAutoLoop(deck.deckId, beats),
            onIn: () => session.setLoopIn(deck.deckId),
            onOut: () => session.setLoopOut(deck.deckId),
            onExit: () => session.clearLoop(deck.deckId),
          ),
        DjPanel.stems => DjStemPanel(source: session.stems),
      };
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.deck,
    required this.state,
    required this.session,
  });
  final DjDeckId deck;
  final DjDeckState state;
  final DjSessionProvider session;
  @override
  Widget build(BuildContext context) => DjTransport(
        playing: state.playing,
        onCuePress: () => session.cuePress(deck),
        onCueRelease: () => session.cueRelease(deck),
        onPlayPause: () => session.togglePlay(deck),
      );
}
