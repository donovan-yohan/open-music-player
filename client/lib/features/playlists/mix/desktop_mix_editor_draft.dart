import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/engine/timeline_model.dart';
import '../../../models/mix_plan.dart';
import '../../../models/stem_edits.dart';

/// Route-scoped document buffer. It owns no transport, clock or audio objects.
class DesktopMixEditorDraft extends ChangeNotifier {
  DesktopMixEditorDraft(this.api);

  final ApiClient api;
  MixPlan? _base;
  List<MixPlanClip> _clips = const [];
  final List<List<MixPlanClip>> _undo = [];
  final List<List<MixPlanClip>> _redo = [];
  List<MixPlanClip>? _gestureBefore;
  List<MixPlanClip>? _preview;
  List<MixPlanClip>? _performanceBefore;
  int _generation = 0;
  bool _disposed = false;
  bool _unverifiedSave = false;
  bool loading = false;
  bool saving = false;
  bool conflict = false;
  String? error;

  MixPlan? get base => _base;
  List<MixPlanClip> get clips => _clips;
  List<MixPlanClip> get displayClips => _preview ?? _clips;
  MixPlan? get plan => _base == null ? null : _withClips(_base!, _clips);
  bool get gesturing => _gestureBefore != null || _performanceBefore != null;
  bool get canUndo => _undo.isNotEmpty && !gesturing;
  bool get canRedo => _redo.isNotEmpty && !gesturing;
  bool get dirty =>
      _base != null &&
      (_unverifiedSave || _fingerprint(_clips) != _fingerprint(_base!.clips));

  bool _current(int generation) => !_disposed && generation == _generation;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> open(String id) async {
    final generation = ++_generation;
    endPerformanceGesture();
    if (_base?.id != id) {
      _base = null;
      _clips = const [];
      _undo.clear();
      _redo.clear();
      _gestureBefore = null;
      _preview = null;
      _unverifiedSave = false;
      conflict = false;
    }
    loading = true;
    saving = false;
    error = null;
    _emit();
    try {
      final plan = await api.getMixPlan(id);
      if (!_current(generation)) return;
      if (plan.id != id) {
        throw StateError('Saved document identity does not match the request');
      }
      validate(plan, plan.clips);
      _base = plan;
      _clips = _freeze(plan.clips);
      _undo.clear();
      _redo.clear();
      _gestureBefore = null;
      _preview = null;
      _unverifiedSave = false;
      conflict = false;
    } catch (e) {
      if (!_current(generation)) return;
      error = 'Could not open saved mix. $e';
    } finally {
      if (_current(generation)) {
        loading = false;
        _emit();
      }
    }
  }

  bool replaceClip(MixPlanClip next) {
    if (_base == null || loading) return false;
    final index = _clips.indexWhere((clip) => clip.clipId == next.clipId);
    if (index < 0) return false;
    final candidate = [..._clips]..[index] = next;
    try {
      validate(_base!, candidate);
      if (_fingerprint(candidate) == _fingerprint(_clips)) return true;
      _undo.add(_clips);
      _redo.clear();
      _clips = _freeze(candidate);
      if (!conflict) error = null;
      _emit();
      return true;
    } catch (e) {
      error = _validationMessage(e);
      _emit();
      return false;
    }
  }

  void beginPerformanceGesture() {
    if (!gesturing && !loading) _performanceBefore = _clips;
  }

  /// Preflight the whole persisted payload before any audio-side command.
  List<MixPlanClip> stagePerformance(MixPlanClip next) {
    if (_base == null || loading || _disposed) {
      throw StateError('Mix is closed.');
    }
    final candidate = [
      for (final clip in _clips)
        if (clip.clipId == next.clipId) next else clip
    ];
    validate(_base!, candidate);
    return candidate;
  }

  void acceptPerformance(
      List<MixPlanClip> expected, List<MixPlanClip> candidate) {
    if (_disposed || !identical(expected, _clips) || loading) {
      throw StateError('Mix changed while the control was pending.');
    }
    _clips = _freeze(candidate);
    _emit();
  }

  void endPerformanceGesture() {
    final before = _performanceBefore;
    if (before == null) return;
    _performanceBefore = null;
    if (_fingerprint(before) != _fingerprint(_clips)) {
      _undo.add(before);
      _redo.clear();
    }
    _emit();
  }

  /// Pointer samples are visual only; exactly one admitted command ends a drag.
  void beginGesture() {
    if (loading || gesturing) return;
    _gestureBefore = _clips;
    _preview = _clips;
  }

  void previewClip(MixPlanClip next) {
    if (!gesturing) return;
    _preview = [
      for (final clip in _gestureBefore!)
        if (clip.clipId == next.clipId) next else clip
    ];
    try {
      validate(_base!, _preview!);
      if (!conflict) error = null;
    } catch (e) {
      error = _validationMessage(e);
    }
    _emit();
  }

  bool endGesture({bool cancel = false}) {
    if (_gestureBefore == null) return false;
    final candidate = _preview!;
    _gestureBefore = null;
    _preview = null;
    if (cancel) {
      if (!conflict) error = null;
      _emit();
      return false;
    }
    try {
      validate(_base!, candidate);
      if (_fingerprint(candidate) != _fingerprint(_clips)) {
        _undo.add(_clips);
        _redo.clear();
        _clips = _freeze(candidate);
      }
      if (!conflict) error = null;
      _emit();
      return true;
    } catch (e) {
      error = _validationMessage(e);
      _emit();
      return false;
    }
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(_clips);
    _clips = _undo.removeLast();
    if (!conflict) error = null;
    _emit();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(_clips);
    _clips = _redo.removeLast();
    if (!conflict) error = null;
    _emit();
  }

  bool canAuthorStems(MixPlanClip clip) =>
      clip.stemEdits != null &&
      RegExp(r'^sha256:[0-9a-f]{64}$')
          .hasMatch(clip.stemEdits!.sourceFileHash) &&
      clip.stemEdits!.hasCanonicalStemModelVersion;

  bool setStemPoint(String clipId, String channel, int sourceMs, double gain) {
    final clip = _clips.where((c) => c.clipId == clipId).firstOrNull;
    if (clip == null ||
        !canAuthorStems(clip) ||
        sourceMs < clip.sourceStartMs ||
        sourceMs >= clip.sourceEndMs ||
        !gain.isFinite ||
        gain < 0 ||
        gain > 1 ||
        !clip.stemEdits!.channelSet.contains(channel)) {
      error = 'Choose an identified stem and a cursor inside the source range.';
      _emit();
      return false;
    }
    final prior = clip.stemEdits!.events
        .where((event) => event.channel == channel && event.atMs == sourceMs)
        .firstOrNull;
    final point = prior?.copyWith(gain: gain) ??
        StemGainEvent(channel: channel, atMs: sourceMs, gain: gain);
    return replaceClip(clip.withStemEdits(clip.stemEdits!.withEvent(point)));
  }

  Future<void> save() async {
    final base = _base;
    if (base == null || saving || loading || conflict || gesturing || !dirty) {
      return;
    }
    final submitted = _freeze(_clips);
    try {
      validate(base, submitted);
    } catch (e) {
      error = _validationMessage(e);
      _emit();
      return;
    }
    final generation = _generation;
    saving = true;
    error = null;
    _emit();
    try {
      final result = await api.updateMixPlan(
          id: base.id,
          version: base.version,
          name: base.name,
          clips: submitted);
      if (!_current(generation)) return;
      if (result.id != base.id ||
          result.version != base.version + 1 ||
          result.schemaVersion != base.schemaVersion ||
          result.name != base.name ||
          _fingerprint(result.clips) != _fingerprint(submitted)) {
        conflict = true;
        throw StateError('Saved response differs from the submitted mix');
      }
      validate(result, result.clips);
      // The PUT response is authoritative even if verification GET fails.
      _base = result;
      _unverifiedSave = true;
      final verified = await api.getMixPlan(base.id);
      if (!_current(generation)) return;
      if (verified.id != base.id ||
          verified.version != result.version ||
          verified.name != result.name ||
          verified.schemaVersion != result.schemaVersion ||
          _fingerprint(verified.clips) != _fingerprint(result.clips)) {
        conflict = true;
        throw StateError('Saved mix changed again. Reload to review it.');
      }
      validate(verified, verified.clips);
      _base = verified;
      _unverifiedSave = false;
      // Verification changes the saved baseline, not the accepted edit revision.
      // Keep its identity so in-flight controls still fence against real edits;
      // edits made while saving remain dirty and retain their history.
    } on ApiException catch (e) {
      if (!_current(generation)) return;
      conflict = e.statusCode == 409;
      error = conflict
          ? 'Saved mix changed elsewhere. Your edits are kept. Reload to review.'
          : 'Could not save mix. Your edits are kept. $e';
    } catch (e) {
      if (!_current(generation)) return;
      error = 'Could not verify saved mix. Your edits are kept. $e';
    } finally {
      if (_current(generation)) {
        saving = false;
        _emit();
      }
    }
  }

  /// Validate the entire draft, using the engine's strict four-instance model.
  /// No inferred beat phase, tempo transition, source hash or source duration.
  static void validate(MixPlan base, List<MixPlanClip> clips) {
    if (base.schemaVersion != 1 || clips.length > 1000) {
      throw const FormatException('Unsupported mix or more than 1000 clips.');
    }
    final queues = <String>{};
    var eventCount = 0;
    for (final clip in clips) {
      if (clip.clipId.trim().isEmpty ||
          clip.queueItemId.trim().isEmpty ||
          !queues.add(clip.queueItemId) ||
          int.tryParse(clip.trackId) == null ||
          int.parse(clip.trackId) <= 0 ||
          clip.timelineStartMs < 0 ||
          clip.sourceStartMs < 0 ||
          clip.sourceEndMs <= clip.sourceStartMs ||
          !clip.gainDb.isFinite) {
        throw const FormatException('Invalid clip identity, range or gain.');
      }
      final fadeIn = clip.fadeInMs ?? 0;
      final fadeOut = clip.fadeOutMs ?? 0;
      if (fadeIn < 0 ||
          fadeOut < 0 ||
          fadeIn + fadeOut > clip.selectedDurationMs) {
        throw const FormatException(
            'Fades must fit inside the selected source range.');
      }
      final edits = clip.stemEdits;
      if (edits != null) {
        if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(edits.sourceFileHash) ||
            !edits.hasCanonicalStemModelVersion ||
            edits.events.length > 2048) {
          throw const FormatException(
              'Stem source identity or event limit is invalid.');
        }
        eventCount += edits.events.length;
        for (final point in edits.events) {
          if (!edits.channelSet.contains(point.channel) ||
              !point.gain.isFinite ||
              point.gain < 0 ||
              point.gain > 1 ||
              point.atMs < 0 ||
              point.rampMs < 1 ||
              point.rampMs > 250) {
            throw const FormatException('Invalid stem change point.');
          }
        }
      }
    }
    if (eventCount > 4096) {
      throw const FormatException('At most 4096 stem points per mix.');
    }
    final payload = {
      'schemaVersion': 1,
      'name': base.name,
      'version': base.version,
      'clips': clips.map((clip) => clip.toJson()).toList()
    };
    if (utf8.encode(jsonEncode(payload)).length > 256 * 1024) {
      throw const FormatException('Mix exceeds the 256 KiB save limit.');
    }
    TimelineModel.fromMixPlan(_withClips(base, clips));
  }

  static MixPlan _withClips(MixPlan plan, List<MixPlanClip> clips) => MixPlan(
      id: plan.id,
      schemaVersion: plan.schemaVersion,
      name: plan.name,
      clips: clips,
      summary: plan.summary,
      version: plan.version,
      createdAt: plan.createdAt,
      updatedAt: plan.updatedAt);
  static List<MixPlanClip> _freeze(List<MixPlanClip> clips) =>
      List.unmodifiable(clips.map((clip) => MixPlanClip.fromJson(
          jsonDecode(jsonEncode(clip.toJson())) as Map<String, dynamic>)));
  static String _fingerprint(List<MixPlanClip> clips) =>
      jsonEncode(clips.map((clip) => clip.toJson()).toList());
  static String _validationMessage(Object e) =>
      e is StateError && e.message.toString().contains('concurrent voices')
          ? 'At most four clips can overlap. Move kept unchanged.'
          : e.toString().replaceFirst('FormatException: ', '');

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
