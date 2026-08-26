import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import 'dj_deck_copy.dart';
import 'models/dj_deck_state.dart';
import 'models/dj_hot_cue.dart';
import 'providers/dj_session_provider.dart';
import 'widgets/dj_beat_counter.dart';
import 'widgets/dj_crossfader.dart';
import 'widgets/dj_deck_header.dart';
import 'widgets/dj_deck_notice.dart';
import 'widgets/dj_hot_cue_pads.dart';
import 'widgets/dj_loop_panel.dart';
import 'widgets/dj_mixer_panel.dart';
import 'widgets/dj_overview_strip.dart';
import 'widgets/dj_panel_switcher.dart';
import 'widgets/dj_pitch_fader.dart';
import 'widgets/dj_stem_panel.dart';
import 'widgets/dj_transport.dart';
import 'widgets/dj_waveform_lane.dart';

/// Preferred height of the two stacked waveform lanes.
const double kDjWaveformStackHeight = 120;

/// Floor the waveform stack degrades to before the header band gives way.
const double kDjWaveformStackMinHeight = 64;

/// Preferred height of the deck header + overview strip band.
const double kDjHeaderBandHeight = 44;

/// Floor of the header band. The 8dp overview strip is dropped below 40dp.
const double kDjHeaderBandMinHeight = 36;

/// Band height at or above which the header still carries its overview strip.
const double kDjHeaderOverviewStripMinBandHeight = 40;

/// Cap on the flexible control field (pitch fader + panel + mixer).
const double kDjControlFieldMaxHeight = 180;

/// Floor of the flexible control field. Below this the deck is not serviceable.
const double kDjControlFieldMinHeight = 120;

/// The transport row never shrinks: it is the primary thumb surface and is
/// pinned by docs/dj-deck-spec.md.
const double kDjTransportHeight = 64;

/// Minimum post-SafeArea height the deck can be laid out in:
/// 64 waveform + 36 header + 120 control + 64 transport.
const double kDjMinDeckHeight = 284;

/// Minimum post-SafeArea width the deck can be laid out in:
/// 2 * (48 pitch fader + 4 + 120 panel) + 2 * 12 gutter + 120 centre column.
///
/// This is a *serviceability* floor, not a comfort one: between here and the
/// reference viewport the deck panel is at its 120dp minimum and the hot-cue
/// pads degrade below the 48dp touch target, the same way the pitch fader's
/// nudge ladder does. Raising the gate to the width that would keep the pads
/// at 48dp (~840dp post-SafeArea) would blank the deck on the reference device
/// itself, so the pad aspect ratio is the thing to revisit, not this constant.
const double kDjMinDeckWidth = 488;

/// Height reserved for the per-deck panel switcher inside the control field
/// while the deck is at or above the reference budget. docs/dj-deck-spec.md
/// requires a 48dp touch target there, so the switcher gets a real one.
const double kDjPanelSwitcherHeight = 48;

/// Compact switcher band. Used only below the reference control-field budget,
/// on the same rung as the pitch fader's 40dp nudge step, and documented in
/// docs/dj-deck-spec.md as a deliberate degraded state.
const double kDjPanelSwitcherCompactHeight = 40;

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

/// The deck's vertical budget, derived from the post-SafeArea height.
///
/// Give-order when the viewport is short, highest priority first:
/// 1. control field (the spec's designated flexible region) 180 -> 120,
/// 2. waveform stack 120 -> 64,
/// 3. header band 44 -> 36 (overview strip dropped below 40),
/// 4. transport — never; pinned at [kDjTransportHeight].
@visibleForTesting
class DjRowBudget {
  const DjRowBudget({
    required this.waveformStack,
    required this.headerBand,
    required this.controlField,
    required this.transport,
  });

  factory DjRowBudget.of(double available) {
    final control = (available -
            kDjWaveformStackHeight -
            kDjHeaderBandHeight -
            kDjTransportHeight)
        .clamp(kDjControlFieldMinHeight, kDjControlFieldMaxHeight)
        .toDouble();
    final waveform =
        (available - control - kDjHeaderBandHeight - kDjTransportHeight)
            .clamp(kDjWaveformStackMinHeight, kDjWaveformStackHeight)
            .toDouble();
    final header = (available - control - waveform - kDjTransportHeight)
        .clamp(kDjHeaderBandMinHeight, kDjHeaderBandHeight)
        .toDouble();
    return DjRowBudget(
      waveformStack: waveform,
      headerBand: header,
      controlField: control,
      transport: kDjTransportHeight,
    );
  }

  final double waveformStack;
  final double headerBand;
  final double controlField;
  final double transport;

  double get total => waveformStack + headerBand + controlField + transport;

  bool get showsOverviewStrip =>
      headerBand >= kDjHeaderOverviewStripMinBandHeight;

  /// The switcher keeps its full 48dp target while the control field is at or
  /// above the reference budget, and steps to the compact band on the same
  /// rung as [DjPitchFader.nudgeExtentFor], so the two touch-target ladders
  /// cannot drift apart.
  double get panelSwitcherHeight =>
      controlField >= kDjPitchFaderFullNudgeHeight
          ? kDjPanelSwitcherHeight
          : kDjPanelSwitcherCompactHeight;
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
    final deckTokens = SoundQPlayerTheme.of(context);
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Landscape is only *requested* by DjScreen; Android ignores the
          // request in split-screen/freeform/connected-display windows and
          // takes some frames to honour it after a route push. Paint an
          // explicit state instead of a portrait deck full of overflow.
          if (constraints.maxHeight > constraints.maxWidth) {
            return const _DjDeckNotice(
              key: ValueKey('dj_rotate_prompt'),
              icon: Icons.screen_rotation,
              message: djDeckRotatePrompt,
              detail: djDeckRotateDetail,
            );
          }
          if (constraints.maxHeight < kDjMinDeckHeight ||
              constraints.maxWidth < kDjMinDeckWidth) {
            return const _DjDeckNotice(
              key: ValueKey('dj_deck_too_small'),
              icon: Icons.aspect_ratio,
              message: djDeckTooSmall,
              detail: djDeckTooSmallDetail,
            );
          }
          final grid = DjDeckGrid.of(constraints);
          final budget = DjRowBudget.of(constraints.maxHeight);
          return Column(
            children: [
              SizedBox(
                key: const ValueKey('dj_waveform_stack'),
                height: budget.waveformStack,
                child: Column(
                  children: [
                    Expanded(
                      child: DjWaveformLane(
                        deck: session.deckA,
                        track: aTrack,
                        color: deckTokens.waveformDeckA,
                      ),
                    ),
                    const SizedBox(height: AppTheme.space2),
                    Expanded(
                      child: DjWaveformLane(
                        deck: session.deckB,
                        track: bTrack,
                        color: deckTokens.waveformDeckB,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                key: const ValueKey('dj_header_row'),
                height: budget.headerBand,
                child: _GridRow(
                  grid: grid,
                  deckAKey: const ValueKey('dj_header_deck_a'),
                  deckBKey: const ValueKey('dj_header_deck_b'),
                  centerKey: const ValueKey('dj_center_column'),
                  deckA: _HeaderOverview(
                    deck: session.deckA,
                    cues: session.hotCuesFor(DjDeckId.a),
                    onSeek: (ms) => session.seek(DjDeckId.a, ms),
                    showOverviewStrip: budget.showsOverviewStrip,
                  ),
                  deckB: _HeaderOverview(
                    deck: session.deckB,
                    cues: session.hotCuesFor(DjDeckId.b),
                    onSeek: (ms) => session.seek(DjDeckId.b, ms),
                    showOverviewStrip: budget.showsOverviewStrip,
                  ),
                ),
              ),
              // The only Expanded child of this Column, so the Column itself
              // can never overflow; the centred SizedBox holds the row budget.
              Expanded(
                child: Center(
                  child: SizedBox(
                    key: const ValueKey('dj_control_field'),
                    height: budget.controlField,
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
                        switcherHeight: budget.panelSwitcherHeight,
                        onPanel: (panel) =>
                            setState(() => _panels[DjDeckId.a] = panel),
                      ),
                      deckB: _DeckControl(
                        deck: session.deckB,
                        panel: _panels[DjDeckId.b]!,
                        session: session,
                        switcherHeight: budget.panelSwitcherHeight,
                        onPanel: (panel) =>
                            setState(() => _panels[DjDeckId.b] = panel),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                key: const ValueKey('dj_transport_row'),
                height: budget.transport,
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

class _DjDeckNotice extends StatelessWidget {
  const _DjDeckNotice({
    super.key,
    required this.icon,
    required this.message,
    this.detail,
  });

  final IconData icon;
  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // The notice exists to replace overflow banners, so it must not paint one
    // itself: its intrinsic height (icon + two lines) exceeds a near-minimum
    // freeform window at an elevated font scale. Scroll rather than overflow,
    // and stay centred whenever it does fit (#411).
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: muted),
                  const SizedBox(height: AppTheme.space2),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(color: muted),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: AppTheme.space1),
                    Text(
                      detail!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
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
    required this.showOverviewStrip,
  });
  final DjDeckState deck;
  final List<DjHotCue> cues;
  final ValueChanged<int> onSeek;
  final bool showOverviewStrip;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(child: DjDeckHeader(deck: deck)),
          if (showOverviewStrip)
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
    required this.switcherHeight,
    required this.onPanel,
  });
  final DjDeckState deck;
  final DjPanel panel;
  final DjSessionProvider session;
  final double switcherHeight;
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
                  height: switcherHeight,
                  child: DjPanelSwitcher(
                    selected: panel,
                    onSelected: onPanel,
                    compact: switcherHeight < kDjPanelSwitcherHeight,
                  ),
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
            enabled: deck.isLoaded,
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
  // The transport slot carries the beat counter beside the transport itself;
  // the counter keeps its intrinsic width and the gated transport flexes into
  // whatever is left.
  @override
  Widget build(BuildContext context) {
    final syncMatch = session.syncMatchFor(deck);
    final syncIsMaster = session.isSyncMaster(deck);
    // The master's own SYNC stays live: its tap hands the master role over.
    final syncEnabled = state.isLoaded && (syncIsMaster || syncMatch.isMatched);
    final refusal = syncMatch.refusal;
    return Row(
      children: [
        DjBeatCounter(deck: state),
        const SizedBox(width: AppTheme.space1),
        Expanded(
          child: DjTransport(
            deck: deck,
            playing: state.playing,
            enabled: state.isLoaded,
            disabledReason: state.loadFailure == null
                ? null
                : DjDeckNotice.messageFor(state.loadFailure!.kind),
            onCuePress: () => session.cuePress(deck),
            onCueRelease: () => session.cueRelease(deck),
            onPlayPause: () => session.togglePlay(deck),
            onSync: syncEnabled ? () => session.pressSync(deck) : null,
            syncEngaged: session.syncEngagedOn(deck),
            syncIsMaster: syncIsMaster,
            syncDisabledReason:
                refusal == null ? null : djDeckSyncReasonFor(refusal),
          ),
        ),
      ],
    );
  }
}
