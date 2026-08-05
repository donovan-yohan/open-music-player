import 'package:flutter/material.dart';

import '../../../core/stems/stem_channel_source.dart';
import '../../../widgets/timeline_waveform_painter.dart';
import '../../stems/track_stem_channel_source.dart';

/// Deck stem mixer.
///
/// Renders the full opt-in loop rather than hiding itself when stems are
/// missing: an unseparated track shows a "Separate stems" action, an in-flight
/// one shows "Separating…", and a ready one shows the per-channel faders. The
/// faders are honest about Rung B — they edit source state and are not audible.
class DjStemPanel extends StatelessWidget {
  const DjStemPanel({super.key, required this.source});

  final StemChannelSource source;

  @override
  Widget build(BuildContext context) {
    final source = this.source;
    // The live API-backed source repaints on its own; the authoring stub and
    // the empty source are immutable and need no listener.
    if (source is Listenable) {
      return ListenableBuilder(
        listenable: source as Listenable,
        builder: (context, _) => _body(context),
      );
    }
    return _body(context);
  }

  Widget _body(BuildContext context) {
    if (source.isAvailable) return _mixer(context);
    return _placeholder(context);
  }

  Widget _mixer(BuildContext context) => Column(
        key: const ValueKey('dj_stem_mixer'),
        children: [
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final stem in source.channels)
                  SizedBox(
                    width: 54,
                    child: _StemStrip(stem: stem, source: source),
                  ),
              ],
            ),
          ),
          const _NotAudibleHint(),
        ],
      );

  /// Everything that is not a live mixer: the opt-in trigger, the in-flight
  /// state, a failed separation, and the honest "no track" case.
  Widget _placeholder(BuildContext context) {
    final theme = Theme.of(context);
    final live =
        source is TrackStemChannelSource ? source as TrackStemChannelSource : null;

    if (source.isPending) {
      return _Centered(
        key: const ValueKey('dj_stem_separating'),
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 8),
          Text(
            live != null && live.queuePosition > 0
                ? 'Separating… #${live.queuePosition} in queue'
                : 'Separating…',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Takes a few minutes. This deck keeps playing the original.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (live != null) ...[
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('dj_stem_refresh'),
              onPressed: live.isLoading ? null : live.refresh,
              child: const Text('Check again'),
            ),
          ],
        ],
      );
    }

    if (live == null) {
      return _Centered(
        key: const ValueKey('dj_stem_unsupported'),
        children: [
          Text('No stems for this deck', style: theme.textTheme.labelLarge),
        ],
      );
    }

    if (live.trackId == null) {
      return _Centered(
        key: const ValueKey('dj_stem_no_track'),
        children: [
          Text('Load a library track', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'Stems are separated per library track; a local file has none.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final failed = live.status == StemsStatus.failed;
    return _Centered(
      key: const ValueKey('dj_stem_unavailable'),
      children: [
        Text(
          failed ? 'Separation failed' : 'Stems not separated',
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Text(
          failed && live.separationError.isNotEmpty
              ? live.separationError
              : 'Separation runs once per track and takes a few minutes.',
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: failed
                ? theme.colorScheme.error
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (live.errorMessage != null) ...[
          const SizedBox(height: 4),
          Text(
            live.errorMessage!,
            key: const ValueKey('dj_stem_error'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 8),
        FilledButton.tonal(
          key: const ValueKey('dj_stem_separate'),
          onPressed: live.isLoading ? null : live.requestSeparation,
          child: Text(failed ? 'Retry separation' : 'Separate stems'),
        ),
      ],
    );
  }
}

/// One vertical channel strip. The fader hue matches this stem's timeline
/// change-point ticks — one stem, one color, everywhere.
class _StemStrip extends StatelessWidget {
  const _StemStrip({required this.stem, required this.source});

  final StemChannel stem;
  final StemChannelSource source;

  @override
  Widget build(BuildContext context) {
    final color = stemChannelColor(stem.id);
    return Column(
      key: ValueKey('dj_stem_strip_${stem.id}'),
      children: [
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: color,
                thumbColor: color,
              ),
              child: Slider(
                key: ValueKey('dj_stem_gain_${stem.id}'),
                value: stem.gain.clamp(0, 1),
                onChanged: stem.muted
                    ? null
                    : (value) => source.setGain(stem.id, value),
              ),
            ),
          ),
        ),
        Tooltip(
          message: stem.honestyCopy.isEmpty ? stem.label : stem.honestyCopy,
          child: Text(
            stem.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        IconButton(
          key: ValueKey('dj_stem_mute_${stem.id}'),
          tooltip: stem.muted ? 'Unmute ${stem.label}' : 'Mute ${stem.label}',
          onPressed: () => source.setMute(stem.id, !stem.muted),
          icon: Icon(stem.muted ? Icons.volume_off : Icons.volume_up),
        ),
      ],
    );
  }
}

/// ADR 0006 Rung B gap, stated on the surface that implies otherwise.
class _NotAudibleHint extends StatelessWidget {
  const _NotAudibleHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline,
              size: 12, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              stemPreviewNotAudibleCopy,
              key: const ValueKey('dj_stem_not_audible_hint'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      );
}
