import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../core/api/api_client.dart';
import '../../../core/audio/playback_state.dart';
import '../../../core/services/stems_service.dart';
import '../../../core/services/mix_exchange_service.dart';
import '../../../core/stems/stem_channel_source.dart' show StemsStatus;
import '../../../models/mix_plan.dart';
import '../../../models/stem_edits.dart';
import '../../../shared/widgets/adaptive_desktop_app_bar.dart';
import 'desktop_mix_editor_draft.dart';
import 'stem_performance_recording.dart';
import 'mix_exchange_actions.dart';

bool desktopMixEditorEligible(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 960 &&
    const {TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux}
        .contains(defaultTargetPlatform);

/// Existing authenticated saved-plan browser; opening it never generates a mix.
class DesktopMixEditorPicker extends StatefulWidget {
  const DesktopMixEditorPicker({super.key});
  @override
  State<DesktopMixEditorPicker> createState() => _DesktopMixEditorPickerState();
}

class _DesktopMixEditorPickerState extends State<DesktopMixEditorPicker> {
  final List<MixPlan> _plans = [];
  bool _loading = false;
  bool _started = false;
  bool _more = true;
  String? _error;

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final batch =
          await context.read<ApiClient>().listMixPlans(offset: _plans.length);
      if (!mounted) return;
      setState(() {
        _plans
            .addAll(batch.where((plan) => !_plans.any((p) => p.id == plan.id)));
        _more = batch.length == 50;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load saved mixes.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!desktopMixEditorEligible(context)) return const _DesktopFallback();
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    return Scaffold(
        appBar: adaptiveDesktopAppBar(context,
            leading: BackButton(onPressed: () => context.go('/playlists')),
            title: 'Saved mixes',
            actions: [
              MixExchangeMenu(
                  service: MixExchangeService(context.read<ApiClient>()),
                  onImported: (plan) =>
                      context.push('/mixes/${Uri.encodeComponent(plan.id)}'))
            ]),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Column(children: [
                  if (_error != null)
                    ListTile(
                        title: Text(_error!),
                        trailing: TextButton(
                            onPressed: _load, child: const Text('Retry'))),
                  if (!_loading && _plans.isEmpty && _error == null)
                    const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('No saved mixes yet')),
                  Expanded(
                      child: ListView.builder(
                          itemCount: _plans.length,
                          itemBuilder: (context, index) {
                            final plan = _plans[index];
                            return ListTile(
                                leading:
                                    const Icon(Icons.view_timeline_outlined),
                                title: Text(plan.name),
                                subtitle: Text(
                                    '${plan.clips.length} clips · Version ${plan.version}'),
                                trailing: const Icon(Icons.arrow_forward),
                                onTap: () => context.push(
                                    '/mixes/${Uri.encodeComponent(plan.id)}'));
                          })),
                  if (_loading) const LinearProgressIndicator(),
                  if (_more && !_loading && _plans.isNotEmpty)
                    TextButton(
                        onPressed: _load, child: const Text('Load more')),
                ]))));
  }
}

class DesktopMixEditorScreen extends StatefulWidget {
  const DesktopMixEditorScreen({super.key, required this.planId});
  final String planId;
  @override
  State<DesktopMixEditorScreen> createState() => DesktopMixEditorScreenState();
}

class DesktopMixEditorScreenState extends State<DesktopMixEditorScreen> {
  DesktopMixEditorDraft? _draft;
  bool _started = false;
  bool _allowPop = false;
  Future<bool>? _exitPrompt;
  String? _selected;
  int _sourceCursor = 0;
  double _scale = .035;
  final _workspaceFocus = FocusNode(debugLabel: 'Mix workspace');
  final _captureKey = GlobalKey();
  final _scroll = ScrollController();
  final _fields = <String, TextEditingController>{};
  final _fieldFocus = <String, FocusNode>{};
  final _sourceBounds = <String, int>{};
  MixPlanClip? _dragOrigin;
  double _dragDx = 0;
  final Map<String, double> _stemPreview = {};
  PlaybackState? _playback;
  String? _sessionId;
  List<MixPlanClip> _applied = const [];
  bool _preparingAudio = false;
  int _audioGeneration = 0;
  int? _preparationTransportGeneration;
  bool _recording = false;
  bool _gestureEnded = false;
  bool _gestureWasLive = false;
  String? _stemGesture;
  int _gestureOrdinal = 0;
  int _controlGeneration = 0;
  int? _performanceTransportGeneration;
  int _pendingControls = 0;
  int _lastRevision = 0;
  Future<void> _controlTail = Future.value();
  final Map<String, StemPerformanceRecording> _performances = {};
  final Set<String> _overridden = {};
  final Set<String> _preparingStems = {};
  final Set<String> _waitingStems = {};

  void _cancelPreparation() {
    final owner = _playback;
    if (_preparingAudio &&
        owner != null &&
        owner.transportCommandGeneration == _preparationTransportGeneration) {
      unawaited(owner.pause().catchError((Object _) {}));
    }
    _preparationTransportGeneration = null;
    _audioGeneration++;
    _preparingAudio = false;
  }

  double _stemValue(MixPlanClip clip, String channel) {
    if (_bound && _playback!.usesNativePreparedPlayback) {
      final override = _playback!.liveStemOverrides[clip.queueItemId]?[channel];
      if (override != null) return override;
      final source =
          _playback!.sourcePositionMsForQueueItemId(clip.queueItemId);
      if (source != null) {
        return StemPerformanceRecording(
                clipId: clip.clipId,
                sourceFileHash: clip.stemEdits!.sourceFileHash,
                stemModelVersion: clip.stemEdits!.stemModelVersion,
                edits: clip.stemEdits!)
            .replayGainAt(channel: channel, sourceMs: source);
      }
    }
    return _stemPreview[channel] ??
        clip.stemEdits!.gainAt(channel, _sourceCursor);
  }

  void _resetBinding() {
    _cancelPreparation();
    _closePerformance(invalidate: true);
    _sessionId = null;
    _applied = const [];
    _lastRevision = 0;
    _stemPreview.clear();
    _overridden.clear();
    _preparingAudio = false;
  }

  Future<void> _prepareStems(MixPlanClip clip) async {
    if (_preparingStems.contains(clip.clipId)) return;
    final document = _draft!.base;
    final generation = _audioGeneration;
    final service = context.read<StemsService?>() ??
        StemsService(context.read<ApiClient>());
    setState(() => _preparingStems.add(clip.clipId));
    try {
      final status = await service.getTrackStems(int.parse(clip.trackId));
      if (!mounted ||
          generation != _audioGeneration ||
          !identical(document, _draft!.base)) {
        return;
      }
      if (status.trackId.toString() != clip.trackId ||
          status.channelSet != defaultStemChannelSet) {
        throw StateError('Stem preparation returned another source.');
      }
      if (status.status != StemsStatus.ready) {
        if (status.status == StemsStatus.unavailable ||
            status.status == StemsStatus.failed) {
          await service.requestSeparation(int.parse(clip.trackId));
          // Read the exact target back; request acceptance is not readiness.
          await service.getTrackStems(int.parse(clip.trackId));
        }
        if (mounted && generation == _audioGeneration) {
          _waitingStems.add(clip.clipId);
        }
        return;
      }
      if (status.trackId.toString() != clip.trackId ||
          status.sourceFileHash == null ||
          status.generation == null) {
        throw StateError('Prepared stems have no matching source identity.');
      }
      final manifest = await service.getPreparedManifest(
          int.parse(clip.trackId),
          expectedSourceFileHash: status.sourceFileHash!,
          expectedGeneration: status.generation,
          channelSet: status.channelSet);
      if (!mounted ||
          generation != _audioGeneration ||
          !identical(document, _draft!.base)) {
        return;
      }
      final current =
          _draft!.clips.where((c) => c.clipId == clip.clipId).firstOrNull;
      if (current == null ||
          current.trackId != clip.trackId ||
          current.stemEdits != null) {
        return;
      }
      final set = manifest.channelSet == StemChannelSet.stems5Hybrid.id
          ? StemChannelSet.stems5Hybrid
          : StemChannelSet.stems4Demucs;
      if (manifest.stemModelVersion != set.stemModelVersion ||
          status.stemModelVersion != manifest.stemModelVersion ||
          current.sourceEndMs > manifest.durationMs) {
        throw StateError('Prepared stem model or source range does not match.');
      }
      _draft!.replaceClip(current.withStemEdits(StemEdits(
          channelSet: set,
          sourceFileHash: manifest.sourceFileHash,
          stemModelVersion: manifest.stemModelVersion)));
      _waitingStems.remove(clip.clipId);
    } catch (error) {
      if (mounted && generation == _audioGeneration) {
        _draft!.error = 'Could not prepare stems. $error';
      }
    } finally {
      if (mounted) setState(() => _preparingStems.remove(clip.clipId));
    }
  }

  bool get _arrangementApplied {
    final clips = _draft?.clips;
    if (!_bound || clips == null || clips.length != _applied.length) {
      return false;
    }
    for (var i = 0; i < clips.length; i++) {
      final a = clips[i].toJson()..remove('stemEdits');
      final b = _applied[i].toJson()..remove('stemEdits');
      if (jsonEncode(a) != jsonEncode(b)) return false;
    }
    return true;
  }

  bool get _documentApplied {
    if (!_arrangementApplied) return false;
    final byId = {
      for (final cue in _playback!.snapshot.cues) cue.queueItemId: cue
    };
    for (final clip in _draft!.clips) {
      final cue = byId[clip.queueItemId]!;
      if (jsonEncode(cue.stemEdits?.toJson()) !=
          jsonEncode(clip.stemEdits?.toJson())) {
        return false;
      }
    }
    return true;
  }

  bool get _stemIdentityMatches {
    final clip = _clip;
    final owner = _playback;
    if (!_arrangementApplied ||
        clip == null ||
        owner == null ||
        !owner.usesNativePreparedPlayback ||
        !_draft!.canAuthorStems(clip)) {
      return false;
    }
    final cue = owner.snapshot.cues
        .where((c) => c.queueItemId == clip.queueItemId)
        .single;
    return cue.stemEdits?.sourceFileHash == clip.stemEdits!.sourceFileHash &&
        cue.stemEdits?.stemModelVersion == clip.stemEdits!.stemModelVersion;
  }

  bool get _canRestoreRecorded {
    if (!_onAir || !_stemIdentityMatches) return false;
    final clip = _clip!;
    final source = _playback!.sourcePositionMsForQueueItemId(clip.queueItemId);
    return source != null &&
        source >= clip.sourceStartMs &&
        source < clip.sourceEndMs;
  }

  // ACK acceptance checks ownership and authored identity, not whether the
  // selected clip is still active at the later block-end cursor.
  bool get _stemDocumentMatches {
    if (!_stemIdentityMatches) return false;
    final clip = _clip!;
    final cue = _playback!.snapshot.cues
        .singleWhere((c) => c.queueItemId == clip.queueItemId);
    return jsonEncode(cue.stemEdits?.toJson()) ==
        jsonEncode(clip.stemEdits!.toJson());
  }

  bool get _canLiveControl => _canRestoreRecorded && _stemDocumentMatches;

  void _closePerformance({bool invalidate = false}) {
    if (invalidate) {
      _controlGeneration++;
      _recording = false;
      _performances.clear();
    }
    _gestureEnded = true;
    if (_pendingControls == 0 || invalidate) {
      _stemGesture = null;
      _performanceTransportGeneration = null;
      _draft?.endPerformanceGesture();
    }
  }

  void _beginStemGesture(String channel, double value) {
    if (_pendingControls != 0 || _stemGesture != null) return;
    _stemGesture = '${++_gestureOrdinal}:$channel';
    _gestureEnded = false;
    _gestureWasLive = _canLiveControl;
    _performanceTransportGeneration =
        _gestureWasLive ? _playback!.transportCommandGeneration : null;
    if (_recording && _canLiveControl) _draft!.beginPerformanceGesture();
    setState(() => _stemPreview[channel] = value);
  }

  void _stemChanged(MixPlanClip clip, String channel, double gain) {
    if (_stemGesture == null) return;
    if (_playback == null || !_onAir) {
      setState(() => _stemPreview[channel] = gain);
      return;
    }
    if (!_canLiveControl) return;
    if (_pendingControls >= 8) {
      _closePerformance(invalidate: true);
      setState(() => _draft!.error =
          'Stem controls are busy. Finish this gesture and try again.');
      return;
    }
    // Capture from the canonical active source clock, never a UI timer.
    final sourceMs =
        _playback!.sourcePositionMsForQueueItemId(clip.queueItemId)!;
    final generation = _controlGeneration;
    final transportGeneration = _playback!.transportCommandGeneration;
    final gesture = _stemGesture!;
    final armed = _recording;
    _pendingControls++;
    _controlTail = _controlTail.then((_) async {
      if (!mounted ||
          generation != _controlGeneration ||
          !_canLiveControl ||
          _clip?.clipId != clip.clipId ||
          transportGeneration != _playback!.transportCommandGeneration) {
        return;
      }
      final current = _clip!;
      final expected = _draft!.clips;
      var liveAccepted = false;
      try {
        var performance = _performances[current.clipId];
        if (performance == null ||
            jsonEncode(performance.edits.toJson()) !=
                jsonEncode(current.stemEdits!.toJson())) {
          performance = StemPerformanceRecording(
                  clipId: current.clipId,
                  sourceFileHash: current.stemEdits!.sourceFileHash,
                  stemModelVersion: current.stemEdits!.stemModelVersion,
                  edits: current.stemEdits!)
              .withRecordingArmed(armed);
        }
        // Without an atomic seek token, separate punches conservatively: a
        // forward seek must never erase skipped authored source-time points.
        performance = performance.withSourceDiscontinuity();
        final sample = performance.stage(
            clipId: current.clipId,
            sourceFileHash: current.stemEdits!.sourceFileHash,
            stemModelVersion: current.stemEdits!.stemModelVersion,
            channel: channel,
            capturedSourceMs: sourceMs,
            gain: gain,
            gestureId: gesture);
        var candidate = _draft!
            .stagePerformance(current.withStemEdits(sample.prospectiveEdits));
        final ack =
            await _playback!.setStemGain(current.queueItemId, channel, gain);
        liveAccepted = true;
        if (!mounted ||
            generation != _controlGeneration ||
            !_stemDocumentMatches ||
            !identical(expected, _draft!.clips) ||
            _clip?.clipId != current.clipId ||
            transportGeneration != _playback!.transportCommandGeneration) {
          return;
        }
        if (ack.queueItemId != current.queueItemId ||
            ack.sourceFileHash != current.stemEdits!.sourceFileHash ||
            ack.stemModelVersion != current.stemEdits!.stemModelVersion ||
            ack.channel != channel ||
            ack.gain != gain ||
            ack.revision <= _lastRevision) {
          throw StateError('Stem acknowledgement does not match this control.');
        }
        if (ack.captureSourcePositionMs < current.sourceStartMs ||
            ack.captureSourcePositionMs >= current.sourceEndMs) {
          throw StateError('Stem control left the selected source range.');
        }
        _lastRevision = ack.revision;
        _overridden.add(current.queueItemId);
        _stemPreview[channel] = gain;
        // The owning command may wait in its serial queue. Its capture is
        // authoritative; the post-ACK position is a separate block-end read.
        final acknowledgedSample = performance.stage(
            clipId: current.clipId,
            sourceFileHash: current.stemEdits!.sourceFileHash,
            stemModelVersion: current.stemEdits!.stemModelVersion,
            channel: channel,
            capturedSourceMs: ack.captureSourcePositionMs,
            gain: gain,
            gestureId: gesture);
        candidate = _draft!.stagePerformance(
            current.withStemEdits(acknowledgedSample.prospectiveEdits));
        final accepted = performance.recordAccepted(acknowledgedSample);
        if (armed) {
          await _playback!.setQueueStemEditsByQueueItemId(
              current.queueItemId, accepted.edits,
              expectedSourceFileHash: current.stemEdits!.sourceFileHash);
          if (!mounted ||
              generation != _controlGeneration ||
              !_bound ||
              !identical(expected, _draft!.clips) ||
              _clip?.clipId != current.clipId ||
              transportGeneration != _playback!.transportCommandGeneration) {
            return;
          }
          _draft!.acceptPerformance(expected, candidate);
          _applied = [
            for (final c in _applied)
              if (c.clipId == current.clipId)
                c.withStemEdits(accepted.edits)
              else
                c
          ];
        }
        _performances[current.clipId] = accepted;
        _stemPreview[channel] = gain;
      } catch (error) {
        if (!mounted || generation != _controlGeneration) return;
        _closePerformance(invalidate: true);
        _draft!.error = liveAccepted
            ? 'Live change not recorded. Restore the recorded mix and try again. $error'
            : 'Stem control failed. $error';
      }
    }).whenComplete(() {
      _pendingControls--;
      if (!mounted) return;
      if (_gestureEnded && _pendingControls == 0) _closePerformance();
      setState(() {});
    });
    setState(() {});
  }

  void _endStemGesture(MixPlanClip clip, String channel, double gain) {
    if (_stemGesture == null) return;
    if (!_gestureWasLive &&
        (_playback == null || !_playback!.snapshot.playing)) {
      _draft!.setStemPoint(clip.clipId, channel, _sourceCursor, gain);
      _stemPreview.remove(channel);
    }
    _closePerformance();
    setState(() {});
  }

  Future<void> _restoreRecorded() async {
    if (!_canRestoreRecorded || _pendingControls != 0) return;
    final clip = _clip!;
    final generation = _controlGeneration;
    try {
      await _playback!.clearStemOverrides(clip.queueItemId);
      if (!mounted || generation != _controlGeneration || !_bound) return;
      _overridden.remove(clip.queueItemId);
      _performances.remove(clip.clipId);
      setState(() => _stemPreview.clear());
    } catch (error) {
      if (mounted) {
        setState(
            () => _draft!.error = 'Could not restore recorded mix. $error');
      }
    }
  }

  bool get _bound {
    final owner = _playback;
    if (owner == null ||
        _sessionId == null ||
        owner.snapshot.sessionId != _sessionId ||
        owner.snapshot.cues.length != _applied.length) {
      return false;
    }
    final byId = {for (final cue in owner.snapshot.cues) cue.queueItemId: cue};
    if (byId.length != _applied.length) return false;
    for (final clip in _applied) {
      final cue = byId[clip.queueItemId];
      if (cue == null ||
          cue.cueId != clip.clipId ||
          cue.trackId != clip.trackId ||
          cue.sourceStart.inMilliseconds != clip.sourceStartMs ||
          cue.sourceEnd.inMilliseconds != clip.sourceEndMs ||
          cue.timelineStart.inMilliseconds != clip.timelineStartMs ||
          cue.gainDb != clip.gainDb ||
          cue.fadeInMs != clip.fadeInMs ||
          cue.fadeOutMs != clip.fadeOutMs ||
          cue.pitchMode != clip.pitchMode ||
          cue.tempoPolicy != clip.tempoPolicy) {
        return false;
      }
    }
    return true;
  }

  bool get _onAir => _bound && _playback!.snapshot.playing;

  void _playbackChanged() {
    if (!mounted) return;
    if (!_onAir && (_recording || _stemGesture != null)) {
      // Natural completion does not change the owner's transport intent epoch.
      // Retire the gesture, but let its already-submitted ACK finish. Explicit
      // pause/stop/seek/replacement still invalidates through that epoch.
      final finishingOwnedControl = _pendingControls > 0 &&
          _bound &&
          _performanceTransportGeneration != null &&
          _performanceTransportGeneration ==
              _playback!.transportCommandGeneration;
      if (finishingOwnedControl) {
        _recording = false;
        _closePerformance();
      } else {
        _closePerformance(invalidate: true);
      }
    }
    setState(() {});
  }

  Future<void> _play() async {
    final owner = _playback;
    final plan = _draft?.plan;
    if (owner == null || plan == null || _preparingAudio) return;
    final generation = ++_audioGeneration;
    setState(() => _preparingAudio = true);
    try {
      DesktopMixEditorDraft.validate(plan, plan.clips);
      if (_bound && _documentApplied && owner.usesNativePreparedPlayback) {
        await owner.play();
      } else {
        if (plan.clips.any((clip) => clip.stemEdits != null) &&
            plan.clips.any((clip) => clip.stemEdits == null)) {
          throw StateError('Prepare stems for every clip before playback.');
        }
        final starting = owner.playMixPlan([
          for (final clip in plan.clips)
            {
              'id': int.parse(clip.trackId),
              'title': 'Track ${clip.trackId}',
              'duration': (clip.sourceEndMs / 1000).ceil(),
              if (clip.stemEdits != null)
                'sourceFileHash': clip.stemEdits!.sourceFileHash
            }
        ], plan);
        _preparationTransportGeneration = owner.transportCommandGeneration;
        await starting;
        if (!mounted || generation != _audioGeneration) return;
        if (owner.snapshot.sessionId !=
            'mix_plan_${plan.id}_v${plan.version}') {
          throw StateError('Audio preparation was cancelled.');
        }
        _sessionId = owner.snapshot.sessionId;
        _applied = plan.clips;
        _lastRevision = 0;
        _stemPreview.clear();
        _overridden.clear();
      }
    } catch (error) {
      if (mounted && generation == _audioGeneration) {
        _draft!.error = 'Could not play mix. $error';
      }
    } finally {
      if (mounted && generation == _audioGeneration) {
        _preparationTransportGeneration = null;
        setState(() => _preparingAudio = false);
      }
    }
  }

  Future<void> _transport({required bool stop}) async {
    if (!_bound) return;
    _closePerformance(invalidate: true);
    try {
      await (stop ? _playback!.stop() : _playback!.pause());
      if (stop && mounted) {
        setState(() {
          _stemPreview.clear();
          _overridden.clear();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _draft!.error = 'Could not update playback. $error');
      }
    }
  }

  @override
  void didUpdateWidget(covariant DesktopMixEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.planId != widget.planId) unawaited(_changeDocument());
  }

  Future<void> _changeDocument() async {
    if (GoRouter.maybeOf(context) == null && !await confirmExit()) return;
    if (!mounted) return;
    _resetBinding();
    _selected = null;
    _sourceBounds.clear();
    await _draft?.open(widget.planId);
  }

  void _start() {
    _started = true;
    _playback = context.read<PlaybackState?>();
    _playback?.addListener(_playbackChanged);
    _draft = DesktopMixEditorDraft(context.read<ApiClient>())
      ..addListener(_changed);
    unawaited(_draft!.open(widget.planId));
  }

  void _changed() {
    if (!mounted) return;
    for (final clip in _draft!.clips) {
      _sourceBounds.putIfAbsent(clip.trackId, () => clip.sourceEndMs);
      _sourceBounds[clip.trackId] =
          math.max(_sourceBounds[clip.trackId]!, clip.sourceEndMs);
    }
    _syncFields();
    setState(() {});
  }

  MixPlanClip? get _clip =>
      _draft?.clips.where((clip) => clip.clipId == _selected).firstOrNull;

  Future<void> _save() async {
    _commitFocusedField();
    _closePerformance();
    await _controlTail;
    if (!mounted) return;
    await _draft!.save();
  }

  void _commitFocusedField() {
    for (final entry in _fieldFocus.entries) {
      if (entry.value.hasFocus && _fields[entry.key]?.text != null) {
        _apply(entry.key, _fields[entry.key]!.text);
      }
    }
  }

  void _select(MixPlanClip clip) {
    _closePerformance(invalidate: true);
    _commitFocusedField();
    FocusManager.instance.primaryFocus?.unfocus();
    _workspaceFocus.requestFocus();
    setState(() {
      _selected = clip.clipId;
      _sourceCursor = clip.sourceStartMs;
      _stemPreview.clear();
      _syncFields(force: true);
    });
  }

  Map<String, String> _values(MixPlanClip clip) => {
        'placement': '${clip.timelineStartMs}',
        'in': '${clip.sourceStartMs}',
        'out': '${clip.sourceEndMs}',
        'fade-in': '${clip.fadeInMs ?? 0}',
        'fade-out': '${clip.fadeOutMs ?? 0}',
        'gain': '${clip.gainDb}',
        'cursor': '$_sourceCursor',
      };

  void _syncFields({bool force = false}) {
    final clip = _clip;
    if (clip == null) return;
    _sourceCursor =
        _sourceCursor.clamp(clip.sourceStartMs, clip.sourceEndMs - 1);
    for (final entry in _values(clip).entries) {
      final controller =
          _fields.putIfAbsent(entry.key, TextEditingController.new);
      if (force || !(_fieldFocus[entry.key]?.hasFocus ?? false)) {
        if (controller.text != entry.value) controller.text = entry.value;
      }
    }
  }

  bool get _typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _typing) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final primary = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (primary && key == LogicalKeyboardKey.keyS) {
      unawaited(_save());
      return KeyEventResult.handled;
    }
    if (primary && key == LogicalKeyboardKey.keyZ) {
      _closePerformance(invalidate: true);
      HardwareKeyboard.instance.isShiftPressed
          ? _draft!.redo()
          : _draft!.undo();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _leave();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Called by the root route's onExit, including global command navigation.
  Future<bool> confirmExit() =>
      _exitPrompt ??= _confirmExit().whenComplete(() => _exitPrompt = null);

  Future<bool> _confirmExit() async {
    final draft = _draft;
    if (draft == null) return true;
    _cancelPreparation();
    _closePerformance(invalidate: true);
    _commitFocusedField();
    FocusManager.instance.primaryFocus?.unfocus();
    draft.endGesture(cancel: true);
    if (!draft.dirty && !draft.saving) return true;
    final action = await showDialog<String>(
        context: context,
        builder: (context) =>
            AlertDialog(title: const Text('Save mix changes?'), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, 'cancel'),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: draft.saving
                      ? null
                      : () => Navigator.pop(context, 'discard'),
                  child: const Text('Discard')),
              FilledButton(
                  onPressed: draft.saving || draft.conflict
                      ? null
                      : () => Navigator.pop(context, 'save'),
                  child: const Text('Save')),
            ]));
    if (!mounted || action == null || action == 'cancel') return false;
    if (action == 'save') {
      await draft.save();
      return !draft.dirty && !draft.saving;
    }
    return true;
  }

  Future<void> _leave() async {
    // Router onExit owns its navigation guard. A standalone screen uses PopScope.
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/mixes');
      return;
    }
    if (!await confirmExit() || !mounted) return;
    setState(() => _allowPop = true);
    Navigator.maybePop(context);
  }

  Future<void> _reload() async {
    if (!await confirmExit() || !mounted) return;
    _resetBinding();
    _selected = null;
    await _draft!.open(widget.planId);
  }

  void _apply(String field, String input) {
    _closePerformance(invalidate: true);
    final clip = _clip;
    if (clip == null) return;
    final integer = int.tryParse(input);
    final gain = double.tryParse(input);
    try {
      if (field == 'cursor') {
        if (integer == null ||
            integer < clip.sourceStartMs ||
            integer >= clip.sourceEndMs) {
          throw const FormatException();
        }
        setState(() {
          _sourceCursor = integer;
          _stemPreview.clear();
        });
        return;
      }
      if (field == 'gain') {
        if (gain == null || !gain.isFinite) throw const FormatException();
      } else if (integer == null || integer < 0) {
        throw const FormatException();
      }
      final start = field == 'in' ? integer! : clip.sourceStartMs;
      final end = field == 'out' ? integer! : clip.sourceEndMs;
      if (end <= start ||
          end > (_sourceBounds[clip.trackId] ?? clip.sourceEndMs)) {
        throw const FormatException();
      }
      _draft!.replaceClip(clip.copyWith(
        timelineStartMs: field == 'placement' ? integer : null,
        sourceStartMs: start,
        sourceEndMs: end,
        gainDb: field == 'gain' ? gain : null,
        fadeInMs: field == 'fade-in' ? integer : null,
        fadeOutMs: field == 'fade-out' ? integer : null,
      ));
    } catch (_) {
      _draft!.error = 'Enter a valid value within the loaded source range.';
      setState(() {});
    }
    _syncFields(force: true);
  }

  FocusNode _focusFor(String id) => _fieldFocus.putIfAbsent(id, () {
        final node = FocusNode();
        String? editingClip;
        node.addListener(() {
          if (node.hasFocus) editingClip = _selected;
          final clip = _clip;
          if (!node.hasFocus &&
              clip != null &&
              editingClip == clip.clipId &&
              _fields[id]?.text != _values(clip)[id]) {
            _apply(id, _fields[id]!.text);
          }
        });
        return node;
      });

  Widget _field(String id, String label) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: ValueKey('mix-field-$id'),
        controller: _fields.putIfAbsent(id, TextEditingController.new),
        focusNode: _focusFor(id),
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder()),
        onSubmitted: (value) {
          _apply(id, value);
          _workspaceFocus.requestFocus();
        },
      ));

  @override
  Widget build(BuildContext context) {
    if (!_started && !desktopMixEditorEligible(context)) {
      return const _DesktopFallback();
    }
    if (!_started) _start();
    final draft = _draft!;
    final narrow = MediaQuery.sizeOf(context).width < 960;
    final hasRouter = GoRouter.maybeOf(context) != null;
    return PopScope(
        canPop: hasRouter || _allowPop || (!draft.dirty && !draft.saving),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _leave();
        },
        child: Focus(
            onKeyEvent: _key,
            focusNode: _workspaceFocus,
            autofocus: true,
            child: RepaintBoundary(
                key: _captureKey,
                child: Scaffold(
                  appBar: adaptiveDesktopAppBar(context,
                      leading: BackButton(onPressed: _leave),
                      title: draft.base?.name ?? 'Saved mix',
                      actions: [
                        MixExchangeMenu(
                            service:
                                MixExchangeService(context.read<ApiClient>()),
                            planId: draft.base?.id,
                            enabled: draft.base != null &&
                                !draft.loading &&
                                !draft.dirty &&
                                !draft.saving &&
                                !draft.gesturing &&
                                !_preparingAudio &&
                                _pendingControls == 0 &&
                                _stemGesture == null,
                            onImported: (plan) => context.push(
                                '/mixes/${Uri.encodeComponent(plan.id)}')),
                        IconButton(
                            tooltip: 'Undo',
                            onPressed: draft.canUndo
                                ? () {
                                    _closePerformance(invalidate: true);
                                    draft.undo();
                                  }
                                : null,
                            icon: const Icon(Icons.undo)),
                        IconButton(
                            tooltip: 'Redo',
                            onPressed: draft.canRedo
                                ? () {
                                    _closePerformance(invalidate: true);
                                    draft.redo();
                                  }
                                : null,
                            icon: const Icon(Icons.redo)),
                        IconButton(
                            tooltip: 'Reload saved mix',
                            onPressed: draft.saving ? null : _reload,
                            icon: const Icon(Icons.refresh)),
                        Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: FilledButton.icon(
                                key: const ValueKey('mix-save'),
                                onPressed: draft.dirty &&
                                        !draft.saving &&
                                        !draft.conflict &&
                                        !draft.gesturing
                                    ? _save
                                    : null,
                                icon: const Icon(Icons.save_outlined),
                                label:
                                    Text(draft.saving ? 'Saving…' : 'Save'))),
                      ]),
                  body: draft.loading
                      ? const Center(child: CircularProgressIndicator())
                      : draft.base == null
                          ? Center(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                  Text(draft.error ?? 'Mix unavailable'),
                                  TextButton(
                                      onPressed: () =>
                                          draft.open(widget.planId),
                                      child: const Text('Retry')),
                                ]))
                          : Column(children: [
                              Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  child: Wrap(
                                      spacing: 24,
                                      runSpacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text('Version ${draft.base!.version}'),
                                        Text(draft.dirty
                                            ? 'Unsaved changes'
                                            : 'Saved'),
                                        Text(_preparingAudio
                                            ? 'Preparing audio'
                                            : _onAir && _documentApplied
                                                ? 'On air'
                                                : 'Edits not applied'),
                                        if (_playback != null) ...[
                                          IconButton(
                                              key: const ValueKey('mix-play'),
                                              tooltip: 'Play mix',
                                              onPressed:
                                                  _preparingAudio || _onAir
                                                      ? null
                                                      : _play,
                                              icon:
                                                  const Icon(Icons.play_arrow)),
                                          IconButton(
                                              key: const ValueKey('mix-pause'),
                                              tooltip: 'Pause mix',
                                              onPressed: _onAir
                                                  ? () =>
                                                      _transport(stop: false)
                                                  : null,
                                              icon: const Icon(Icons.pause)),
                                          IconButton(
                                              key: const ValueKey('mix-stop'),
                                              tooltip: 'Stop mix',
                                              onPressed: _bound
                                                  ? () => _transport(stop: true)
                                                  : null,
                                              icon: const Icon(Icons.stop)),
                                        ],
                                        IconButton(
                                            key: const ValueKey('mix-record'),
                                            tooltip: 'Record automation',
                                            isSelected: _recording,
                                            onPressed: _canLiveControl &&
                                                    _pendingControls == 0 &&
                                                    _stemGesture == null &&
                                                    !draft.conflict
                                                ? () => setState(() {
                                                      _recording = !_recording;
                                                      _performances.clear();
                                                    })
                                                : null,
                                            icon: const Icon(
                                                Icons.fiber_manual_record)),
                                        Text('${draft.clips.length} clips'),
                                      ])),
                              if (draft.error != null)
                                Material(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .errorContainer,
                                    child: ListTile(
                                        dense: true,
                                        leading:
                                            const Icon(Icons.error_outline),
                                        title: Text(draft.error!),
                                        trailing: draft.conflict
                                            ? TextButton(
                                                onPressed: _reload,
                                                child: const Text('Reload'))
                                            : null)),
                              Expanded(
                                  child: narrow
                                      ? _narrowWorkspace()
                                      : Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                              SizedBox(
                                                  width: 220,
                                                  child: _clipList()),
                                              const VerticalDivider(width: 1),
                                              Expanded(child: _arrangement()),
                                              const VerticalDivider(width: 1),
                                              SizedBox(
                                                  width:
                                                      MediaQuery.sizeOf(context)
                                                                  .width <
                                                              1200
                                                          ? 260
                                                          : 300,
                                                  child: _inspector()),
                                            ])),
                            ]),
                ))));
  }

  Widget _narrowWorkspace() => DefaultTabController(
      length: 3,
      child: Column(children: [
        const TabBar(tabs: [
          Tab(text: 'Arrangement'),
          Tab(text: 'Clips'),
          Tab(text: 'Inspector')
        ]),
        Expanded(
            child: TabBarView(
                children: [_arrangement(), _clipList(), _inspector()])),
      ]));

  Widget _clipList() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(padding: EdgeInsets.all(16), child: Text('CLIPS')),
        Expanded(
            child: ListView.builder(
                itemCount: _draft!.clips.length,
                itemBuilder: (context, index) {
                  final clip = _draft!.clips[index];
                  return ListTile(
                      selected: clip.clipId == _selected,
                      dense: true,
                      title: Text('Track ${clip.trackId}', maxLines: 1),
                      subtitle: Text(
                          '${clip.clipId} · ${clip.timelineStartMs} ms',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onTap: () => _select(clip));
                })),
      ]);

  static const _laneColors = [
    Color(0xff67d5cf),
    Color(0xffb89cf7),
    Color(0xffffc078),
    Color(0xff91bfef)
  ];

  Map<String, int> _lanes() {
    final sorted = [..._draft!.clips]..sort((a, b) {
        final start = a.timelineStartMs.compareTo(b.timelineStartMs);
        return start != 0 ? start : a.clipId.compareTo(b.clipId);
      });
    final ends = [0, 0, 0, 0];
    final lanes = <String, int>{};
    for (final clip in sorted) {
      final lane = ends.indexWhere((end) => end <= clip.timelineStartMs);
      if (lane < 0) continue;
      lanes[clip.clipId] = lane;
      ends[lane] = clip.timelineEndMs;
    }
    return lanes;
  }

  Widget _arrangement() {
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    double textHeight(TextStyle style) {
      final painter = TextPainter(
          text: TextSpan(text: 'Mg', style: style),
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context))
        ..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final textStyle = Theme.of(context).textTheme.bodyMedium!;
    final rangeStyle = textStyle.copyWith(fontSize: 11);
    final clipHeight = desktop
        ? (math.max(72, textHeight(textStyle) + textHeight(rangeStyle) + 16) /
                    4)
                .ceil() *
            4.0
        : 72.0;
    final laneHeight = clipHeight + 16;
    final rulerHeight =
        desktop ? math.max(32.0, textHeight(rangeStyle) + 12) : 32.0;
    final workspaceHeight = rulerHeight + 4 * laneHeight + 24;
    Widget labels(MixPlanClip clip) {
      final lines = [
        Text('Track ${clip.trackId}',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: desktop ? textStyle : null),
        Text('${clip.sourceStartMs}–${clip.sourceEndMs} ms',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: desktop ? rangeStyle : const TextStyle(fontSize: 11)),
      ];
      return desktop
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: lines)
          : ListView(padding: EdgeInsets.zero, children: lines);
    }

    final lanes = _lanes();
    final clips = _draft!.displayClips;
    final duration =
        clips.fold<int>(1, (end, clip) => math.max(end, clip.timelineEndMs));
    return LayoutBuilder(builder: (context, constraints) {
      final width =
          math.max(constraints.maxWidth - 48, duration * _scale + 150);
      return Column(children: [
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              const Expanded(child: Text('Arrangement')),
              const Tooltip(
                  message: 'No trusted beat grid loaded', child: Text('Free')),
              IconButton(
                  tooltip: 'Zoom out',
                  onPressed: () =>
                      setState(() => _scale = math.max(.0001, _scale / 1.5)),
                  icon: const Icon(Icons.zoom_out)),
              IconButton(
                  tooltip: 'Zoom in',
                  onPressed: () =>
                      setState(() => _scale = math.min(.5, _scale * 1.5)),
                  icon: const Icon(Icons.zoom_in)),
            ])),
        Expanded(
            child: SingleChildScrollView(
                child: SizedBox(
                    height: workspaceHeight,
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                              width: 40,
                              child: Column(children: [
                                SizedBox(height: rulerHeight),
                                for (var lane = 0; lane < 4; lane++)
                                  SizedBox(
                                      height: laneHeight,
                                      child: Center(
                                          child: Text('L${lane + 1}',
                                              style: TextStyle(
                                                  color: _laneColors[lane])))),
                              ])),
                          Expanded(
                              child: Scrollbar(
                                  controller: _scroll,
                                  thumbVisibility: true,
                                  child: SingleChildScrollView(
                                      controller: _scroll,
                                      scrollDirection: Axis.horizontal,
                                      child: SizedBox(
                                          width: width,
                                          height: workspaceHeight,
                                          child: Stack(children: [
                                            for (var lane = 0; lane < 4; lane++)
                                              Positioned(
                                                  left: 0,
                                                  right: 0,
                                                  top: rulerHeight +
                                                      lane * laneHeight,
                                                  height: laneHeight,
                                                  child: DecoratedBox(
                                                      decoration: BoxDecoration(
                                                          color:
                                                              _laneColors[lane]
                                                                  .withValues(
                                                                      alpha:
                                                                          .035),
                                                          border: Border(
                                                              bottom: BorderSide(
                                                                  color: Theme.of(
                                                                          context)
                                                                      .dividerColor))))),
                                            // Time ruler only: these are seconds, never fabricated beats.
                                            for (var tick = 0;
                                                tick <= 10;
                                                tick++)
                                              Positioned(
                                                  left:
                                                      tick * (width - 80) / 10,
                                                  top: 6,
                                                  child: Text(
                                                      '${((tick * (width - 80) / 10) / _scale / 1000).toStringAsFixed(1)}s',
                                                      style: const TextStyle(
                                                          fontSize: 11))),
                                            for (final clip in clips)
                                              Positioned(
                                                  left: clip.timelineStartMs *
                                                      _scale,
                                                  top: rulerHeight +
                                                      6 +
                                                      (lanes[clip.clipId] ?? 0) *
                                                          laneHeight,
                                                  width: math.max(
                                                      6,
                                                      clip.selectedDurationMs *
                                                          _scale),
                                                  height: clipHeight,
                                                  child: Semantics(
                                                      label:
                                                          'Clip ${clip.clipId}, track ${clip.trackId}, ${clip.timelineStartMs} milliseconds',
                                                      button: true,
                                                      selected: clip.clipId ==
                                                          _selected,
                                                      child: GestureDetector(
                                                          onHorizontalDragStart:
                                                              (_) {
                                                            _closePerformance(
                                                                invalidate:
                                                                    true);
                                                            _select(_draft!
                                                                .clips
                                                                .firstWhere((c) =>
                                                                    c.clipId ==
                                                                    clip.clipId));
                                                            _dragOrigin = clip;
                                                            _dragDx = 0;
                                                            _draft!
                                                                .beginGesture();
                                                          },
                                                          onHorizontalDragUpdate:
                                                              (event) {
                                                            _dragDx +=
                                                                event.delta.dx;
                                                            _draft!.previewClip(_dragOrigin!
                                                                .withTimelineStartMs(math.max(
                                                                    0,
                                                                    _dragOrigin!
                                                                            .timelineStartMs +
                                                                        (_dragDx /
                                                                                _scale)
                                                                            .round())));
                                                          },
                                                          onHorizontalDragEnd:
                                                              (_) {
                                                            _draft!
                                                                .endGesture();
                                                            _dragOrigin = null;
                                                          },
                                                          onHorizontalDragCancel:
                                                              () {
                                                            _draft!.endGesture(
                                                                cancel: true);
                                                            _dragOrigin = null;
                                                          },
                                                          child: Material(
                                                              color: _laneColors[lanes[clip.clipId] ?? 0]
                                                                  .withValues(
                                                                      alpha: clip.clipId == _selected
                                                                          ? .35
                                                                          : .16),
                                                              shape: RoundedRectangleBorder(
                                                                  side: BorderSide(
                                                                      color: clip.clipId == _selected
                                                                          ? Colors.white
                                                                          : _laneColors[lanes[clip.clipId] ?? 0]),
                                                                  borderRadius: desktop ? BorderRadius.zero : BorderRadius.circular(6)),
                                                              clipBehavior: Clip.antiAlias,
                                                              child: InkWell(key: ValueKey('mix-clip-${clip.clipId}'), onTap: () => _select(clip), child: Padding(padding: const EdgeInsets.all(8), child: labels(clip))))))),
                                          ]))))),
                        ])))),
      ]);
    });
  }

  Widget _inspector() {
    final clip = _clip;
    if (clip == null) return const Center(child: Text('Select a clip'));
    final edits = clip.stemEdits;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Track ${clip.trackId}',
          style: Theme.of(context).textTheme.titleMedium),
      Text(clip.clipId, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 20),
      _field('placement', 'Placement (ms)'),
      _field('in', 'Source in (ms)'),
      _field('out', 'Source out (ms)'),
      _field('fade-in', 'Fade in (ms)'),
      _field('fade-out', 'Fade out (ms)'),
      _field('gain', 'Clip gain (dB)'),
      const Divider(),
      const Text('Stem edits'),
      const SizedBox(height: 12),
      if (!_draft!.canAuthorStems(clip))
        Column(children: [
          if (_waitingStems.contains(clip.clipId) ||
              _preparingStems.contains(clip.clipId))
            const Text('Preparing stems'),
          OutlinedButton(
              onPressed: _preparingStems.contains(clip.clipId)
                  ? null
                  : () => _prepareStems(clip),
              child: Text(_waitingStems.contains(clip.clipId)
                  ? 'Refresh stems'
                  : 'Prepare stems')),
        ])
      else ...[
        _field('cursor', 'Source cursor (ms)'),
        if (_overridden.contains(clip.queueItemId) ||
            (_bound &&
                (_playback!.liveStemOverrides[clip.queueItemId]?.isNotEmpty ??
                    false)))
          TextButton(
              key: const ValueKey('mix-restore-recorded'),
              onPressed: _canRestoreRecorded && _pendingControls == 0
                  ? _restoreRecorded
                  : null,
              child: const Text('Restore recorded mix')),
        for (final channel in edits!.channelSet.channels) ...[
          Row(children: [
            Expanded(child: Text(channel.label)),
            Text(_stemValue(clip, channel.id).toStringAsFixed(2))
          ]),
          Slider(
              key: ValueKey('mix-stem-${channel.id}'),
              value: _stemValue(clip, channel.id),
              min: 0,
              max: 1,
              semanticFormatterCallback: (value) =>
                  '${channel.label} gain ${value.toStringAsFixed(2)}',
              onChangeStart: (value) => _beginStemGesture(channel.id, value),
              onChanged:
                  (_playback?.snapshot.playing ?? false) && !_canLiveControl
                      ? null
                      : (value) => _stemChanged(clip, channel.id, value),
              onChangeEnd: (value) => _endStemGesture(clip, channel.id, value)),
        ],
        for (final event in edits.events)
          ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                  '${edits.channelSet.descriptorFor(event.channel).label} · ${event.atMs} ms'),
              subtitle: Text('Gain ${event.gain.toStringAsFixed(2)}'),
              trailing: IconButton(
                  tooltip: 'Delete change point',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _draft!.replaceClip(clip.withStemEdits(
                      edits.withoutEvent(
                          channel: event.channel, atMs: event.atMs))))),
      ],
    ]);
  }

  @override
  void dispose() {
    _playback?.removeListener(_playbackChanged);
    _cancelPreparation();
    _draft?.removeListener(_changed);
    _draft?.dispose();
    _workspaceFocus.dispose();
    _scroll.dispose();
    for (final controller in _fields.values) {
      controller.dispose();
    }
    for (final focus in _fieldFocus.values) {
      focus.dispose();
    }
    super.dispose();
  }
}

class _DesktopFallback extends StatelessWidget {
  const _DesktopFallback();
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Saved mixes')),
      body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Open the mix editor on desktop.'),
        const SizedBox(height: 16),
        FilledButton(
            onPressed: () => context.go('/playlists'),
            child: const Text('Go to playlists')),
      ])));
}
