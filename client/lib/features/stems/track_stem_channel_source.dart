import 'package:flutter/foundation.dart';

import '../../core/services/stems_service.dart';
import '../../core/stems/stem_channel_source.dart';
import '../../models/stem_edits.dart';

/// Live [StemChannelSource] backed by the real separation pipeline.
///
/// Resolves a track's stem availability from `GET /tracks/{id}/stems` and can
/// trigger `POST /tracks/{id}/stems` — the idempotent opt-in — when nothing has
/// been separated yet. The channel list comes from the worker manifest, not
/// from the static registry, so the deck shows the stems that actually exist.
///
/// **Per-stem gain and mute are held client-side only.** ADR 0006 Rung B (the
/// opus decode path) is not built, so nothing here reaches the audio engine:
/// moving a fader changes this object's state and repaints the panel, and the
/// audible output stays the original mixdown. Callers must render
/// [stemPreviewNotAudibleCopy] wherever these controls are shown. Faking the
/// audio would be worse than the honest gap.
///
/// Gain/mute state survives a [refresh] for channels that are still in the
/// manifest, so polling a pending separation cannot silently discard a mix the
/// user already dialled in.
class TrackStemChannelSource extends ChangeNotifier
    implements StemChannelSource {
  TrackStemChannelSource({
    required StemsService service,
    this.channelSet = defaultStemChannelSet,
    int? trackId,
  })  : _service = service,
        _trackId = trackId;

  final StemsService _service;

  /// Channel set requested from the backend, e.g. `stems5-hybrid-v1`.
  final String channelSet;

  int? _trackId;
  TrackStems? _stems;
  bool _loading = false;
  String? _errorMessage;

  final Map<String, double> _gains = <String, double>{};
  final Set<String> _muted = <String>{};

  /// The track this source is currently resolving, or null when no deck has
  /// been bound yet.
  int? get trackId => _trackId;

  /// True while a GET or POST is in flight.
  bool get isLoading => _loading;

  /// Last transport/authorization failure, or null. Distinct from a `failed`
  /// separation, which is carried by [status].
  String? get errorMessage => _errorMessage;

  /// Durable separation state. [StemsStatus.unavailable] until the first
  /// successful [refresh].
  StemsStatus get status => _stems?.status ?? StemsStatus.unavailable;

  /// Backend failure text for a `failed` separation.
  String get separationError => _stems?.error ?? '';

  /// Live queue position while pending, or `-1`.
  int get queuePosition => _stems?.queuePosition ?? -1;

  /// True once the backend reports ready *and* the manifest lists channels.
  ///
  /// This gates the mixer surface being meaningful, not audibility — see the
  /// class doc and [stemPreviewNotAudibleCopy].
  @override
  bool get isAvailable => _stems?.isReady ?? false;

  @override
  bool get isPending => _stems?.isPending ?? false;

  @override
  List<StemChannel> get channels {
    final stems = _stems;
    if (stems == null || !stems.isReady) return const <StemChannel>[];
    return List<StemChannel>.unmodifiable(<StemChannel>[
      for (final id in _orderedChannelIds(stems))
        StemChannel(
          id: id,
          label: _descriptorFor(id)?.label ?? id,
          gain: _gains[id] ?? 1.0,
          muted: _muted.contains(id),
          honestyCopy: _descriptorFor(id)?.honestyCopy ?? '',
        ),
    ]);
  }

  /// Points this source at a different track and reloads.
  ///
  /// Per-stem gains are dropped: a mix dialled in on one track means nothing on
  /// another. Passing the id already bound is a no-op so a rebuilding deck does
  /// not throw away the user's faders.
  Future<void> bindTrack(int? trackId) async {
    if (trackId == _trackId) return;
    _trackId = trackId;
    _stems = null;
    _errorMessage = null;
    _gains.clear();
    _muted.clear();
    notifyListeners();
    if (trackId != null) await refresh();
  }

  /// Re-reads the durable row. Safe to call repeatedly while pending.
  Future<void> refresh() async {
    final trackId = _trackId;
    if (trackId == null || _loading) return;
    _loading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      _adopt(await _service.getTrackStems(trackId, channelSet: channelSet));
    } catch (error) {
      _errorMessage = '$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Opts this track in to separation, then re-reads the row.
  ///
  /// Idempotent at the backend, so a repeated tap is harmless. Does nothing
  /// when stems are already ready or already in flight.
  Future<void> requestSeparation() async {
    final trackId = _trackId;
    if (trackId == null || _loading) return;
    if (isAvailable || isPending) return;
    _loading = true;
    _errorMessage = null;
    notifyListeners();
    var triggered = false;
    try {
      final result =
          await _service.requestSeparation(trackId, channelSet: channelSet);
      // The trigger response carries the durable status but no manifest, so the
      // row stays the authority for the channel list.
      _adopt(
        TrackStems(
          trackId: trackId,
          channelSet: result.channelSet,
          status: result.status,
          channels: _stems?.channels ?? const <String>[],
          queuePosition: result.queuePosition,
        ),
      );
      triggered = true;
    } catch (error) {
      _errorMessage = '$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
    // Only re-read after a trigger that landed. Refreshing after a failed POST
    // would clear the error the user needs to see and leave the panel looking
    // like nothing happened.
    if (triggered) await refresh();
  }

  /// Sets a channel's client-side gain. Not audible — see the class doc.
  @override
  Future<void> setGain(String id, double gain) async {
    if (!_hasChannel(id)) return;
    _gains[id] = gain.clamp(0.0, 1.0).toDouble();
    notifyListeners();
  }

  /// Sets a channel's client-side mute. Not audible — see the class doc.
  @override
  Future<void> setMute(String id, bool muted) async {
    if (!_hasChannel(id)) return;
    if (muted) {
      _muted.add(id);
    } else {
      _muted.remove(id);
    }
    notifyListeners();
  }

  void _adopt(TrackStems stems) {
    _stems = stems;
    // Drop fader state for channels the manifest no longer lists, so a channel
    // set change cannot leave an orphaned mute holding down a stem that is not
    // on screen.
    final live = stems.channels.toSet();
    _gains.removeWhere((id, _) => !live.contains(id));
    _muted.removeWhere((id) => !live.contains(id));
  }

  bool _hasChannel(String id) => _stems?.channels.contains(id) ?? false;

  /// Manifest channels ordered by the registry's canonical display order, with
  /// any channel the registry does not know about appended rather than dropped.
  List<String> _orderedChannelIds(TrackStems stems) {
    final set = _channelSetRegistryEntry();
    if (set == null) return stems.channels;
    final known = <String>[
      for (final descriptor in set.channels)
        if (stems.channels.contains(descriptor.id)) descriptor.id,
    ];
    final extra = <String>[
      for (final id in stems.channels)
        if (!set.contains(id)) id,
    ];
    return <String>[...known, ...extra];
  }

  StemChannelSet? _channelSetRegistryEntry() {
    final id = _stems?.channelSet ?? channelSet;
    for (final candidate in StemChannelSet.registry) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }

  StemChannelDescriptor? _descriptorFor(String id) {
    final set = _channelSetRegistryEntry();
    if (set == null || !set.contains(id)) return null;
    return set.descriptorFor(id);
  }
}

/// Required honesty copy for any surface exposing these faders.
///
/// ADR 0006 Rung B (per-stem opus decode + mix) is not built. The controls edit
/// state; the speaker still plays the original mixdown.
const String stemPreviewNotAudibleCopy =
    'Preview mix not yet audible — faders edit stem state only.';
