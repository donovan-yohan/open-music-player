import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../dj_deck_copy.dart';
import '../engine/deck_sync.dart';
import '../models/dj_deck_state.dart';

/// Slot width below which the transport swaps its labelled CUE button for an
/// icon-only one. Three labelled controls do not fit narrower than this.
const double kDjTransportCompactWidth = 168;

/// The sentence-case reason a refused sync shows on the disabled glyph.
///
/// Six engine refusals collapse to three user-facing statements: the user can
/// only act on "this track has no tempo", "the other deck is empty" and "the
/// gap is too wide", and which side of the pair failed is not their problem.
String djDeckSyncReasonFor(DjSyncRefusal refusal) => switch (refusal) {
      DjSyncRefusal.leaderTempoUnreliable ||
      DjSyncRefusal.followerTempoUnreliable =>
        djDeckSyncNoTempo,
      DjSyncRefusal.noLeader ||
      DjSyncRefusal.leaderNotLoaded ||
      DjSyncRefusal.followerNotLoaded =>
        djDeckSyncOtherDeckUnavailable,
      DjSyncRefusal.tempoOutOfRange => djDeckSyncTempoOutOfRange,
    };

class DjTransport extends StatelessWidget {
  const DjTransport({
    super.key,
    required this.playing,
    required this.onCuePress,
    required this.onCueRelease,
    required this.onPlayPause,
    this.enabled = true,
    this.disabledReason,
    this.deck,
    this.onSync,
    this.syncEngaged = false,
    this.syncIsMaster = false,
    this.syncDisabledReason,
  });
  final bool playing;
  final VoidCallback onCuePress;
  final VoidCallback onCueRelease;
  final VoidCallback onPlayPause;

  /// Whether this deck holds audio. A deck with nothing loaded used to present
  /// a fully coloured, fully armed CUE and PLAY that latched `playing` over
  /// silence (#414).
  final bool enabled;

  /// Tooltip shown on the gated controls; the lane's own reason where there is
  /// one, so the transport and the waveform lane cannot tell different stories.
  final String? disabledReason;

  /// Which deck this transport drives. Only used to key the sync state marker,
  /// so a transport built outside the deck layout still renders correctly.
  final DjDeckId? deck;

  /// Null disables the SYNC control. The session supplies a callback whenever
  /// the press would do something: match, swap master, or disengage.
  final VoidCallback? onSync;

  /// This deck is an engaged follower.
  final bool syncEngaged;

  /// This deck sets the tempo. A master's SYNC stays enabled: its tap swaps.
  final bool syncIsMaster;

  /// Why SYNC is unavailable, when it is. Falls back to the honest default for
  /// a transport that was never wired to a session.
  final String? syncDisabledReason;

  String get _reason => disabledReason ?? djDeckTransportDisabledReason;

  /// The accessible name a gated control keeps, with the reason appended.
  ///
  /// A disabled control still has to say which control it is. `Tooltip` maps to
  /// `SemanticsProperties.tooltip`, not `label`, so dropping the control's own
  /// tooltip while gated left the compact CUE and PLAY nodes byte-identical to
  /// a screen reader (#414 review).
  String _name(String name) => enabled ? name : '$name. $_reason';

  /// The wrapper keeps carrying the reason in semantics as well as on screen:
  /// the labelled CUE variant has no tooltip of its own, so this node is where
  /// its reason lives.
  Widget _gated(Widget child) => enabled
      ? child
      : Tooltip(message: _reason, child: child);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          // Every child is loose-flexible, so the row divides its slot instead
          // of painting the sync glyph over the neighbouring deck (#411).
          final compact = constraints.maxWidth < kDjTransportCompactWidth;
          // One set of compact metrics for all three controls, so the variants
          // cannot drift apart.
          final iconPadding =
              EdgeInsets.all(compact ? AppTheme.space1 : AppTheme.space2);
          final iconConstraints = compact
              ? const BoxConstraints(minWidth: 28, minHeight: 28)
              : null;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: _gated(
                  Listener(
                    // The press/release pair is the cue contract; both variants
                    // keep it and keep the dj_cue key. A gated deck wires
                    // neither, so a press cannot reach the voice by the pointer
                    // route while the button itself is disabled.
                    onPointerDown: enabled ? (_) => onCuePress() : null,
                    onPointerUp: enabled ? (_) => onCueRelease() : null,
                    onPointerCancel: enabled ? (_) => onCueRelease() : null,
                    child: compact
                        ? IconButton.filled(
                            key: const ValueKey('dj_cue'),
                            tooltip: _name('Cue'),
                            iconSize: 20,
                            padding: iconPadding,
                            constraints: iconConstraints,
                            onPressed: enabled ? () {} : null,
                            icon: const Icon(Icons.flag),
                          )
                        : FilledButton(
                            key: const ValueKey('dj_cue'),
                            // The labelled variant already carries its name in
                            // its Text child; only the reason is missing.
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(56, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppTheme.space2,
                              ),
                            ),
                            onPressed: enabled ? () {} : null,
                            child: const Text(
                              'CUE',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                  ),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: _gated(
                  IconButton.filled(
                    key: const ValueKey('dj_play_pause'),
                    tooltip: _name(playing ? 'Pause' : 'Play'),
                    iconSize: compact ? 20 : 28,
                    padding: iconPadding,
                    constraints: iconConstraints,
                    onPressed: enabled ? onPlayPause : null,
                    icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: _sync(
                  compact: compact,
                  iconPadding: iconPadding,
                  iconConstraints: iconConstraints,
                ),
              ),
            ],
          );
        },
      );

  /// The SYNC control, in exactly one of four states.
  ///
  /// It stays the third and last child of the transport row: the 64dp row and
  /// the three-way non-overlap contract at the 123.3dp slot both depend on
  /// there being three controls, so state is expressed through the button
  /// variant and a keyed icon rather than through extra widgets. Exactly one of
  /// `dj_sync_master_<deck>`, `dj_sync_on_<deck>` and `dj_sync_off_<deck>` is
  /// present at any time, which is a layout-free widget-test contract.
  Widget _sync({
    required bool compact,
    required EdgeInsets iconPadding,
    required BoxConstraints? iconConstraints,
  }) {
    final suffix = deck?.name ?? 'deck';
    final iconSize = compact ? 20.0 : 24.0;

    if (onSync == null) {
      final reason = syncDisabledReason ?? djDeckSyncOtherDeckUnavailable;
      return Tooltip(
        message: reason,
        child: IconButton(
          key: const ValueKey('dj_sync'),
          // The wrapper carries the reason on screen; the button's own tooltip
          // is what a screen reader reads as the control's name, so a gated
          // glyph still says which control it is (#414 review).
          tooltip: 'Sync. $reason',
          iconSize: iconSize,
          padding: iconPadding,
          constraints: iconConstraints,
          onPressed: null,
          icon: Icon(Icons.sync, key: ValueKey('dj_sync_off_$suffix')),
        ),
      );
    }

    if (syncIsMaster) {
      return IconButton.filledTonal(
        key: const ValueKey('dj_sync'),
        tooltip: djDeckSyncMaster,
        iconSize: iconSize,
        padding: iconPadding,
        constraints: iconConstraints,
        onPressed: onSync,
        icon: Icon(Icons.sync, key: ValueKey('dj_sync_master_$suffix')),
      );
    }

    if (syncEngaged) {
      return IconButton.filled(
        key: const ValueKey('dj_sync'),
        tooltip: djDeckSyncEngaged,
        iconSize: iconSize,
        padding: iconPadding,
        constraints: iconConstraints,
        onPressed: onSync,
        icon: Icon(Icons.sync, key: ValueKey('dj_sync_on_$suffix')),
      );
    }

    return IconButton(
      key: const ValueKey('dj_sync'),
      tooltip: djDeckSyncFollowAction,
      iconSize: iconSize,
      padding: iconPadding,
      constraints: iconConstraints,
      onPressed: onSync,
      icon: Icon(Icons.sync, key: ValueKey('dj_sync_off_$suffix')),
    );
  }
}
