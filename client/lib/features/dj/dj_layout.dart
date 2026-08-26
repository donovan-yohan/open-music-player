import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
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

/// Height reserved for the per-deck panel switcher inside the control field.
const double kDjPanelSwitcherHeight = 40;

/// The one column grid every row below the waveform stack is laid out on.
///
/// Deck A occupies a single `Expanded` slot whose right edge is identical in
/// the header, control and transport rows; deck B mirrors it. The centre
/// column carries the mixer and the crossfader, and is the band the fixed
/// centre playhead runs down — so the playhead can no longer be mistaken for a
/// deck A/B divider (#415).
@visibleForTesting
class DjDeckGrid {
  const DjDeckGrid({required this.centerWidth, required this.gutter});

  /// Gutter between a deck column and the centre column.
  static const double defaultGutter = AppTheme.space3;
  static const double minCenterWidth = 120;

  /// docs/dj-deck-spec.md's mixer/crossfader width.
  static const double maxCenterWidth = 180;

  factory DjDeckGrid.of(BoxConstraints constraints) => DjDeckGrid(
        centerWidth: (constraints.maxWidth * 0.19)
            .clamp(minCenterWidth, maxCenterWidth)
            .toDouble(),
        gutter: defaultGutter,
      );

  final double centerWidth;
  final double gutter;
}

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
        builder: (context, constraints) {
          final grid = DjDeckGrid.of(constraints);
          return Column(
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
                    const SizedBox(height: AppTheme.space2),
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
                child: _GridRow(
                  grid: grid,
                  deckAKey: const ValueKey('dj_header_deck_a'),
                  deckBKey: const ValueKey('dj_header_deck_b'),
                  centerKey: const ValueKey('dj_center_column'),
                  deckA: _HeaderOverview(
                    deck: session.deckA,
                    cues: session.hotCuesFor(DjDeckId.a),
                    onSeek: (ms) => session.seek(DjDeckId.a, ms),
                  ),
                  deckB: _HeaderOverview(
                    deck: session.deckB,
                    cues: session.hotCuesFor(DjDeckId.b),
                    onSeek: (ms) => session.seek(DjDeckId.b, ms),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: _GridRow(
                      grid: grid,
                      deckAKey: const ValueKey('dj_control_deck_a'),
                      deckBKey: const ValueKey('dj_control_deck_b'),
                      center: DjMixerPanel(
                        deckA: session.deckA,
                        deckB: session.deckB,
                        onGainA: (v) => session.setChannelGain(DjDeckId.a, v),
                        onGainB: (v) => session.setChannelGain(DjDeckId.b, v),
                      ),
                      deckA: _DeckControl(
                        deck: session.deckA,
                        panel: _panels[DjDeckId.a]!,
                        session: session,
                        onPanel: (panel) =>
                            setState(() => _panels[DjDeckId.a] = panel),
                      ),
                      deckB: _DeckControl(
                        deck: session.deckB,
                        panel: _panels[DjDeckId.b]!,
                        session: session,
                        onPanel: (panel) =>
                            setState(() => _panels[DjDeckId.b] = panel),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 64,
                child: _GridRow(
                  grid: grid,
                  deckAKey: const ValueKey('dj_transport_deck_a'),
                  deckBKey: const ValueKey('dj_transport_deck_b'),
                  center: DjCrossfader(
                    value: session.crossfader,
                    onChanged: session.setCrossfader,
                  ),
                  deckA: _Transport(
                    deck: DjDeckId.a,
                    state: session.deckA,
                    session: session,
                  ),
                  deckB: _Transport(
                    deck: DjDeckId.b,
                    state: session.deckB,
                    session: session,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// `Expanded(deck A) | gutter | centre column | gutter | Expanded(deck B)`.
///
/// Every row below the waveform stack uses this identical slot pattern, so a
/// deck column has one right edge for the whole deck and the waveform lanes
/// above line up with the split underneath them.
class _GridRow extends StatelessWidget {
  const _GridRow({
    required this.grid,
    required this.deckA,
    required this.deckB,
    required this.deckAKey,
    required this.deckBKey,
    this.center,
    this.centerKey,
  });

  final DjDeckGrid grid;
  final Widget deckA;
  final Widget deckB;
  final Key deckAKey;
  final Key deckBKey;
  final Widget? center;
  final Key? centerKey;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(key: deckAKey, child: deckA),
          SizedBox(width: grid.gutter),
          SizedBox(key: centerKey, width: grid.centerWidth, child: center),
          SizedBox(width: grid.gutter),
          Expanded(key: deckBKey, child: deckB),
        ],
      );
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
          const SizedBox(width: AppTheme.space1),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: kDjPanelSwitcherHeight,
                  child: DjPanelSwitcher(selected: panel, onSelected: onPanel),
                ),
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
