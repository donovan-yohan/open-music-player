import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import '../../../core/engine/tempo_automation.dart';
import '../dj_deck_copy.dart';
import '../engine/deck_tempo_target.dart';
import '../models/dj_camelot.dart';
import '../models/dj_deck_state.dart';
import '../providers/dj_session_provider.dart';

/// Widest the tempo sheet is allowed to get: about one deck column at the
/// reference viewport (899dp of safe box, two 12dp gutters and a ~171dp centre
/// column leave ~352dp a side). A full-width sheet over a landscape deck reads
/// as a new screen rather than as one deck's controls.
const double kDjDeckTempoSheetMaxWidth = 360;

/// Opens the per-deck tempo and key sheet (#413, DJ-3).
///
/// A modal bottom sheet rather than a fourth `DjPanelSwitcher` segment: at
/// `landscapeNarrowServiceable` the deck panel body is 121dp wide, where four
/// segmented labels clip to two characters each, and the switcher is a shared
/// control the viewport matrix pins.
Future<void> showDjDeckTempoSheet(
  BuildContext context, {
  required DjSessionProvider session,
  required DjDeckId deck,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: kDjDeckTempoSheetMaxWidth),
      builder: (_) => DjDeckTempoSheet(session: session, deck: deck),
    );

/// Per-deck BPM, keylock and key shift.
///
/// Everything here writes through `DjSessionProvider`, which is the screen's one
/// state authority; the sheet holds no deck state of its own beyond the text the
/// user is part-way through typing.
class DjDeckTempoSheet extends StatefulWidget {
  const DjDeckTempoSheet({
    super.key,
    required this.session,
    required this.deck,
  });

  final DjSessionProvider session;
  final DjDeckId deck;

  @override
  State<DjDeckTempoSheet> createState() => _DjDeckTempoSheetState();
}

class _DjDeckTempoSheetState extends State<DjDeckTempoSheet> {
  late final TextEditingController _bpmField;

  /// The last refusal, held until the next successful edit. Deliberately not
  /// cleared on every rebuild: the 33Hz snapshot pass rebuilds this sheet, and
  /// a message that vanished 33ms after it appeared would never be read.
  String? _refusal;

  String get _suffix => widget.deck.name;
  DjDeckState get _deck => widget.session.stateFor(widget.deck);

  @override
  void initState() {
    super.initState();
    final effective = djDeckEffectiveBpm(_deck);
    _bpmField = TextEditingController(
      text: effective == null ? '' : effective.toStringAsFixed(1),
    );
  }

  @override
  void dispose() {
    _bpmField.dispose();
    super.dispose();
  }

  Future<void> _applyTyped() async {
    final typed = double.tryParse(_bpmField.text.trim());
    if (typed == null) {
      setState(() => _refusal = djDeckTempoOutOfReach);
      return;
    }
    final result = await widget.session.setTargetBpm(widget.deck, typed);
    if (!mounted) return;
    setState(() => _refusal = result.isResolved ? null : _reasonFor(result));
    if (result.isResolved) _syncFieldToDeck();
  }

  Future<void> _step(double delta) async {
    final result = await widget.session.stepTempo(widget.deck, delta);
    if (!mounted) return;
    setState(() => _refusal = result.isResolved ? null : _reasonFor(result));
    if (result.isResolved) _syncFieldToDeck();
  }

  Future<void> _reset() async {
    await widget.session.resetTempoAndKey(widget.deck);
    if (!mounted) return;
    setState(() => _refusal = null);
    _syncFieldToDeck();
  }

  void _syncFieldToDeck() {
    final effective = djDeckEffectiveBpm(_deck);
    _bpmField.text = effective == null ? '' : effective.toStringAsFixed(1);
  }

  String _reasonFor(DjTempoTarget target) =>
      target.refusal == DjTempoTargetRefusal.noTempo
          ? djDeckTempoUnknown
          : djDeckTempoOutOfReach;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => _body(context),
      );

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final deck = _deck;
    final band = djReachableBpmBand(deck);
    final effective = djDeckEffectiveBpm(deck);
    final syncOwnsTempo = widget.session.tempoControlledBySync(widget.deck);
    final tempoEditable = deck.isLoaded && band != null && !syncOwnsTempo;

    return Padding(
      // The field is the only keyboard target here; without this the sheet
      // renders behind the IME on a landscape phone.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: ConstrainedBox(
          // The same overflow-proof shape `_DjDeckNotice` uses: the sheet has
          // to survive a 290dp-tall landscape window at textScale 1.6.
          constraints: const BoxConstraints(minHeight: 0),
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.space3),
            child: Column(
              key: ValueKey('dj_deck_tempo_sheet_$_suffix'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$djDeckTempoSheetTitle · ${_suffix.toUpperCase()}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: AppTheme.space2),
                _readout(theme, deck, effective),
                const SizedBox(height: AppTheme.space2),
                if (!deck.isLoaded)
                  Text(
                    djDeckTransportDisabledReason,
                    style: theme.textTheme.bodySmall,
                  )
                else if (band == null)
                  Text(djDeckTempoUnknown, style: theme.textTheme.bodySmall)
                else ...[
                  _tempoControls(theme, deck, enabled: tempoEditable),
                  const SizedBox(height: AppTheme.space1),
                  Text(
                    '$djDeckTempoReachablePrefix: '
                    '${band.minBpm.toStringAsFixed(1)} to '
                    '${band.maxBpm.toStringAsFixed(1)} BPM',
                    key: ValueKey('dj_bpm_band_$_suffix'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                if (syncOwnsTempo)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTheme.space1),
                    child: Text(
                      djDeckTempoSyncControlled,
                      key: ValueKey('dj_tempo_sync_reason_$_suffix'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (_refusal != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTheme.space1),
                    child: Text(
                      _refusal!,
                      key: ValueKey('dj_tempo_refusal_$_suffix'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                const SizedBox(height: AppTheme.space2),
                _keylock(theme, deck),
                const SizedBox(height: AppTheme.space2),
                _keyShift(theme, deck),
                const SizedBox(height: AppTheme.space2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: ValueKey('dj_tempo_reset_$_suffix'),
                    onPressed: deck.isLoaded ? _reset : null,
                    child: const Text(djDeckTempoResetAction),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The same number the deck header shows: native BPM times the applied rate.
  Widget _readout(ThemeData theme, DjDeckState deck, double? effective) => Row(
        children: [
          // Both segments flex: at textScale 1.6 a headline-sized BPM plus the
          // pitch percentage is wider than the sheet's 360dp cap, and a fixed
          // first child overflowed the row by 18px.
          Flexible(
            child: Text(
              '${effective == null ? '--' : effective.toStringAsFixed(1)} BPM',
              key: ValueKey('dj_bpm_readout_$_suffix'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall,
            ),
          ),
          const SizedBox(width: AppTheme.space2),
          Flexible(
            child: Text(
              '${deck.ratePercent >= 0 ? '+' : ''}'
              '${deck.ratePercent.toStringAsFixed(1)}%',
              key: ValueKey('dj_tempo_percent_$_suffix'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      );

  Widget _tempoControls(
    ThemeData theme,
    DjDeckState deck, {
    required bool enabled,
  }) {
    // A step that would leave the reachable band disables its own chip rather
    // than clamping: the deck never moves a tempo the user did not ask for.
    bool stepReachable(double delta) {
      if (!enabled) return false;
      final next = djSteppedTargetBpm(deck, delta);
      return next != null &&
          djResolveTargetBpm(deck: deck, targetBpm: next).isResolved;
    }

    final field = TextField(
      key: ValueKey('dj_bpm_field_$_suffix'),
      controller: _bpmField,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _applyTyped(),
      decoration: const InputDecoration(
        labelText: djDeckTempoFieldLabel,
        isDense: true,
        border: OutlineInputBorder(),
      ),
    );

    final row = Row(
      children: [
        _stepButton(
          keyName: 'dj_bpm_step_down_$_suffix',
          icon: Icons.remove,
          tooltip: '$djDeckTempoFieldLabel -$kDjTempoFineStepBpm BPM',
          onPressed: stepReachable(-kDjTempoFineStepBpm)
              ? () => _step(-kDjTempoFineStepBpm)
              : null,
        ),
        const SizedBox(width: AppTheme.space1),
        Expanded(child: field),
        const SizedBox(width: AppTheme.space1),
        _stepButton(
          keyName: 'dj_bpm_step_up_$_suffix',
          icon: Icons.add,
          tooltip: '$djDeckTempoFieldLabel +$kDjTempoFineStepBpm BPM',
          onPressed: stepReachable(kDjTempoFineStepBpm)
              ? () => _step(kDjTempoFineStepBpm)
              : null,
        ),
      ],
    );

    return enabled
        ? row
        : Tooltip(message: djDeckTempoSyncControlled, child: row);
  }

  Widget _stepButton({
    required String keyName,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) =>
      IconButton.outlined(
        key: ValueKey(keyName),
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        icon: Icon(icon),
      );

  Widget _keylock(ThemeData theme, DjDeckState deck) {
    final on = !pitchModeFollowsTempo(deck.pitchMode);
    return SwitchListTile(
      key: ValueKey('dj_keylock_$_suffix'),
      contentPadding: EdgeInsets.zero,
      value: on,
      title: const Text(djDeckKeylockLabel),
      subtitle: on
          ? null
          : Text(djDeckKeylockOffDetail, style: theme.textTheme.bodySmall),
      onChanged: deck.isLoaded
          ? (value) => widget.session.setKeylock(widget.deck, value)
          : null,
    );
  }

  Widget _keyShift(ThemeData theme, DjDeckState deck) {
    final shiftable = deck.isLoaded && deck.pitchSupported;
    final semitones = deck.keySemitones;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(djDeckKeyShiftLabel, style: theme.textTheme.labelLarge),
        const SizedBox(height: AppTheme.space1),
        Row(
          children: [
            _stepButton(
              keyName: 'dj_key_shift_down_$_suffix',
              icon: Icons.remove,
              tooltip: '$djDeckKeyShiftLabel -1',
              onPressed: shiftable && semitones > -kDjMaxKeySemitones
                  ? () => widget.session.nudgeKeySemitones(widget.deck, -1)
                  : null,
            ),
            const SizedBox(width: AppTheme.space2),
            Expanded(
              child: Text(
                _keyReadout(deck),
                key: ValueKey('dj_key_readout_$_suffix'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: AppTheme.space2),
            _stepButton(
              keyName: 'dj_key_shift_up_$_suffix',
              icon: Icons.add,
              tooltip: '$djDeckKeyShiftLabel +1',
              onPressed: shiftable && semitones < kDjMaxKeySemitones
                  ? () => widget.session.nudgeKeySemitones(widget.deck, 1)
                  : null,
            ),
          ],
        ),
        if (deck.isLoaded && !deck.pitchSupported)
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.space1),
            child: Text(
              djDeckKeyShiftUnavailable,
              key: ValueKey('dj_key_shift_unavailable_$_suffix'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// `8A` unshifted, `8A → 10A` shifted, and the semitone label for a track
  /// with no Camelot value. One Camelot parser, in `dj_camelot.dart`.
  String _keyReadout(DjDeckState deck) {
    final camelot = deck.camelot;
    final semitones = deck.keySemitones;
    if (camelot == null) return djKeySemitoneLabel(semitones);
    if (semitones == 0) return camelot;
    final shifted = djCamelotShifted(camelot, semitones);
    return shifted == null
        ? '$camelot ${djKeySemitoneLabel(semitones)}'
        : '$camelot → $shifted';
  }
}
