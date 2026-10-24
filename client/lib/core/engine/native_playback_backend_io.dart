import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../services/stems_service.dart';
import '../stems/native_stem_decoder.dart';
import '../stems/prepared_stem_assets.dart';
import '../stems/prepared_stem_manifest.dart';
import 'native_mix_renderer.dart';
import 'native_mix_schedule.dart';

import 'native_playback_backend.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';

NativePlaybackBackend createNativePlaybackBackend(
        {required String libraryPath,
        required PreparedStemManifestLoader loadManifest,
        required VerifiedPreparedAssetLoader loadPreparedAsset}) =>
    _PreparedNativeBackend(libraryPath, loadManifest, loadPreparedAsset);

/// Android is packaged by externalNativeBuild; macOS embeds the same host in
/// Contents/Frameworks. Resolve only here: loading/opening remains deferred until
/// prepared playback is requested. An explicit developer override still wins.
/// Web never imports this file or dart:ffi.
NativePlaybackBackendFactory? applicationNativePlaybackFactory(ApiClient api,
    {required Future<String?> Function() accountIdProvider}) {
  final path = Platform.isAndroid
      ? 'libsoundq_device.so'
      : Platform.isMacOS
          ? Platform.environment['SOUNDQ_NATIVE_DEVICE_LIBRARY'] ??
              '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libsoundq_device.dylib'
          : null;
  if (path == null || path.isEmpty) return null;
  final service = StemsService(api);
  PreparedStemAssets? assets;
  String? assetsAccount;
  return () => createNativePlaybackBackend(
      libraryPath: path,
      loadManifest: (clip, hash, token) async {
        if (token.isCancelled) throw token.cancelError!;
        final account = await accountIdProvider();
        if (account == null) {
          throw StateError('Prepared playback requires an account.');
        }
        final manifest = await service.getPreparedManifest(
            int.parse(clip.trackId),
            expectedSourceFileHash: hash,
            channelSet: clip.stemEdits?.channelSet.id ?? defaultStemChannelSet);
        if (account != await accountIdProvider() || token.isCancelled) {
          throw StateError('Prepared playback account changed.');
        }
        return manifest;
      },
      loadPreparedAsset: (manifest, token) async {
        final account = await accountIdProvider();
        if (account == null) {
          throw StateError('Prepared playback requires an account.');
        }
        final directory = await getApplicationCacheDirectory();
        // Account segment is encoded; cannot escape the application profile root.
        if (assetsAccount != account) {
          assetsAccount = account;
          assets = PreparedStemAssets(
              rootDirectory: Directory(
                  '${directory.path}/prepared-stems/${base64Url.encode(utf8.encode(account))}'));
        }
        final manager = assets!;
        final lease = await manager.acquire(manifest, cancelToken: token);
        if (account != await accountIdProvider() || token.isCancelled) {
          await lease.release();
          throw StateError('Prepared playback account changed.');
        }
        return lease;
      });
}

class _ResidentWindow {
  _ResidentWindow(this.assetId, this.start, this.pcm);
  final int assetId, start;
  final NativePreparedPcm pcm;
  int get end => start + pcm.frameCount;
  NativeArrangementWindow get native => NativeArrangementWindow(
      assetId: assetId, sourceStartFrame: start, pcm: pcm);
}

/// One preparation owner under PlaybackEngine. Native owns all scheduled starts;
/// this owner only replenishes borrowed PCM. Four active + two imminent workers,
/// one read at a time globally, 2-3 seconds/active +1 second/imminent, 48k pieces.
class _PreparedNativeBackend implements NativePlaybackBackend {
  _PreparedNativeBackend(this._library, this._loadManifest, this._loadAsset) {
    _renderer = NativeMixRenderer.open(
        libraryPath: _library,
        sampleRate: 48000,
        maxBlockFrames: 512,
        maxAssetFrames: 48000,
        maxPreparedBytes: 64 * 1024 * 1024);
    try {
      _renderer.openDevice();
    } catch (_) {
      _renderer.close();
      rethrow;
    }
    clock = NativeTimelineClock(
        readFrames: () => _renderer.renderedFrames,
        startDevice: () {
          if (_needsRecovery) {
            throw StateError(
                'Native revision failed; seek or reload before resuming.');
          }
          _renderer.startDevice();
        },
        pauseDevice: _renderer.pauseDevice,
        seekTransport: seek);
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_closed ||
          _closing ||
          _busy ||
          _preparation != null ||
          !clock.isPlaying ||
          _model.clips.isEmpty) {
        return;
      }
      // Own the request before enqueueing: stop/replacement must also revoke a
      // timer turn that has not entered the serialized lane yet.
      final token = _preparation = CancelToken();
      unawaited(_serial(() async {
        if (token.isCancelled) return;
        final windows =
            await _prepare(_model, _manifests, clock.positionMs, token: token);
        if (token.isCancelled) {
          _discardNewWindows(windows);
          return;
        }
        if (windows.length != _windows.length ||
            windows.any((w) => !_windows.contains(w))) {
          await _install(_model, _manifests, windows, acknowledge: true);
        } else {
          _renderer.pollAppliedRevision();
        }
        final error = _renderer.deviceError;
        if (error != null) _errors.add(error);
        if (_renderer.missingPcmFrames > _lastMissing) {
          _lastMissing = _renderer.missingPcmFrames;
          _errors.add(StateError('Prepared audio arrived late for native clip '
              '${_renderer.lastMissingInstance}; healthy clips continue.'));
        }
      }).catchError((Object e) {
        // Retirement revokes this operation's right to publish. Do not filter
        // exception types: all failures of a still-current request must surface.
        if (!token.isCancelled && !_errors.isClosed) _errors.add(e);
      }).whenComplete(() {
        if (identical(_preparation, token)) _preparation = null;
      }));
    });
  }
  final String _library;
  final PreparedStemManifestLoader _loadManifest;
  final VerifiedPreparedAssetLoader _loadAsset;
  late final NativeMixRenderer _renderer;
  @override
  late final NativeTimelineClock clock;
  late final Timer _timer;
  final _errors = StreamController<Object>.broadcast();
  @override
  Stream<Object> get errors => _errors.stream;
  TimelineModel _model = TimelineModel();
  Map<String, PreparedStemManifest> _manifests = {};
  final _decoders = <String, NativeStemDecoder>{};
  final _instances = <String, int>{}, _assetIds = <String, int>{};
  final _gains = <String, List<NativeMixBus>>{};
  final _overrideMasks = <String, int>{};
  @override
  Map<String, Map<String, double>> get liveStemOverrides => Map.unmodifiable({
        for (final entry in _overrideMasks.entries)
          if (entry.value != 0 && _manifests.containsKey(entry.key))
            entry.key: Map<String, double>.unmodifiable({
              for (var i = 0; i < _manifests[entry.key]!.channels.length; i++)
                if (entry.value & (1 << i) != 0)
                  _manifests[entry.key]!.channels[i]: _gains[entry.key]![i].gain
            })
      });

  List<_ResidentWindow> _windows = [];
  Future<void> _chain = Future.value();
  CancelToken? _preparation;
  bool _busy = false, _closed = false, _closing = false, _needsRecovery = false;
  int _revision = 0, _nextInstance = 0, _nextAsset = 0, _lastMissing = 0;
  @override
  int get preparedBytes => _renderer.preparedBytes;
  @override
  int get decoderCount => _decoders.length;
  @override
  List<MixClip> get activeClips =>
      List.unmodifiable(_model.activeClipsAt(clock.positionMs));
  String _key(MixClip clip) => clip.queueItemId ?? clip.id;
  int _instance(MixClip clip) =>
      _instances.putIfAbsent(_key(clip), () => ++_nextInstance);
  int _asset(PreparedStemManifest manifest) =>
      _assetIds.putIfAbsent(manifest.identity, () => ++_nextAsset);

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      _busy = true;
      try {
        if (_closed || _closing) throw StateError('Native playback closed');
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      } finally {
        _busy = false;
      }
    });
    return completer.future;
  }

  void _validate(TimelineModel model) {
    final keys = <String>{};
    for (final clip in model.clips) {
      if (!keys.add(_key(clip))) {
        throw ArgumentError('Duplicate queue occurrence.');
      }
      // Match the compiler's fail-closed policy, including redundant segments;
      // never silently strip saved timing semantics before admission.
      if (clip.playbackRate != 1 ||
          clip.rateAutomation.baseRate != 1 ||
          clip.rateAutomation.segments.isNotEmpty) {
        throw UnsupportedError(
            'Native prepared playback supports unsegmented rate 1 only.');
      }
      // Full authored semantics and verified identity are validated by the
      // shared arrangement compiler, not an independent adapter translation.
    }
  }

  @override
  Future<void> load(TimelineModel model,
      {bool preserveActivePlayback = false,
      Map<String, String> expectedSourceHashes = const {},
      int? initialPositionMs}) {
    _preparation?.cancel('Superseded prepared candidate');
    final token = _preparation = CancelToken();
    return _serial(() async {
      if (token.isCancelled) throw token.cancelError!;
      _validate(model);
      if (model.clips.length > NativeArrangementPlan.maxClips) {
        throw StateError('Native arrangement metadata capacity.');
      }
      final current = clock.isPlaying
          ? clock.positionMs
          : initialPositionMs ?? clock.positionMs;
      if (clock.isPlaying) {
        final nextById = {for (final c in model.clips) _key(c): c};
        for (final active in activeClips) {
          final next = nextById[_key(active)];
          if (next == null ||
              next.placement != active.placement ||
              next.stemEdits?.sourceFileHash !=
                  active.stemEdits?.sourceFileHash) {
            throw StateError(
                'Moving or replacing an on-air clip requires an explicit pause/seek.');
          }
        }
      }
      final manifests = <String, PreparedStemManifest>{};
      for (final clip in model.clips) {
        final key = _key(clip);
        final hash = clip.stemEdits?.sourceFileHash ??
            expectedSourceHashes[key] ??
            _manifests[key]?.sourceFileHash;
        if (hash == null || !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(hash)) {
          throw StateError(
              'Explicit source hash required for prepared clip $key.');
        }
        final existing = _manifests[key];
        final manifest = existing != null &&
                existing.sourceFileHash == hash &&
                existing.trackId.toString() == clip.trackId
            ? existing
            : await _loadManifest(clip, hash, token);
        if (token.isCancelled) throw token.cancelError!;
        if (manifest.trackId.toString() != clip.trackId ||
            manifest.sourceFileHash != hash ||
            manifest.sampleRateHz != 48000 ||
            manifest.audioChannels != 2 ||
            clip.placement.sourceEndMs * 48 > manifest.sampleFrames ||
            (clip.stemEdits != null &&
                (manifest.channelSet != clip.stemEdits!.channelSet.id ||
                    manifest.stemModelVersion !=
                        clip.stemEdits!.stemModelVersion))) {
          throw StateError('Prepared publication does not match clip $key.');
        }
        manifests[key] = manifest;
      }
      // Compile before mutating transport anchors/duration or decoding windows.
      // Invalid authored metadata leaves accepted state and healthy residency intact.
      _plan(model, manifests, const []);
      final windows = await _prepare(model, manifests, current, token: token);
      if (token.isCancelled) {
        _discardNewWindows(windows);
        throw token.cancelError!;
      }
      clock.durationMs = model.durationMs;
      if (!clock.isPlaying && initialPositionMs != null) {
        clock.reanchor(current);
      }
      await _install(model, manifests, windows, acknowledge: clock.isPlaying);
      _model = model;
      _manifests = manifests;
      _needsRecovery = false;
      clock.durationMs = model.durationMs;
      clock.publish();
    }).whenComplete(() {
      if (identical(_preparation, token)) _preparation = null;
    });
  }

  Future<List<_ResidentWindow>> _prepare(TimelineModel model,
      Map<String, PreparedStemManifest> manifests, int globalMs,
      {CancelToken? token}) async {
    token ??= CancelToken();
    final active = model.activeClipsAt(globalMs);
    final upcoming = model.clips
        .where((c) => c.timelineStartMs > globalMs)
        .toList()
      ..sort((a, b) => a.timelineStartMs.compareTo(b.timelineStartMs));
    final selected = [
      ...active,
      ...upcoming.take(math.max(2, 4 - active.length))
    ];
    final identities = {
      for (final clip in selected) manifests[_key(clip)]!.identity
    };
    // Free obsolete workers before admitting new ones, never active healthy ones.
    for (final id
        in _decoders.keys.where((id) => !identities.contains(id)).toList()) {
      await _decoders.remove(id)!.close();
    }
    final desired = <String, _ResidentWindow>{};
    final created = <_ResidentWindow>[];
    try {
      for (final clip in selected) {
        if (token.isCancelled) throw token.cancelError!;
        var manifest = manifests[_key(clip)]!;
        final assetId = _asset(manifest);
        var decoder = _decoders[manifest.identity];
        if (decoder == null) {
          if (_decoders.length >= 6) {
            throw StateError('Native decoder capacity.');
          }
          if (manifest.members.values.any((member) => !member.expiresAt
              .isAfter(DateTime.now().add(const Duration(seconds: 30))))) {
            final refreshed =
                await _loadManifest(clip, manifest.sourceFileHash, token);
            if (refreshed.identity != manifest.identity) {
              throw StateError(
                  'Prepared publication changed while awaiting residency.');
            }
            manifest = refreshed;
          }
          final lease = await _loadAsset(manifest, token);
          if (lease is! PreparedStemLease ||
              lease.manifest.identity != manifest.identity) {
            if (lease is PreparedStemLease) await lease.release();
            throw StateError(
                'Acquisition must return exact verified prepared lease.');
          }
          try {
            decoder = NativeStemDecoder(
                lease: lease,
                libraryPath: _library,
                maxPcmBytes: 1920000,
                maxQueuedReads: 0);
            _decoders[manifest.identity] = decoder;
          } finally {
            await lease.release();
          }
          try {
            await decoder.ready;
          } catch (_) {
            _decoders.remove(manifest.identity);
            await decoder.close();
            rethrow;
          }
        }
        final source =
            clip.sourcePositionAt(math.max(globalMs, clip.timelineStartMs)) *
                48;
        final end = math.min(clip.placement.sourceEndMs * 48,
            source + (clip.isActiveAt(globalMs) ? 96000 : 48000));
        var start = source ~/ 48000 * 48000;
        while (start < end) {
          final key = '$assetId/$start';
          if (!desired.containsKey(key)) {
            final existing = _windows
                .where((w) => w.assetId == assetId && w.start == start)
                .firstOrNull;
            if (existing != null) {
              desired[key] = existing;
            } else {
              final decoded = await decoder.readWindow(
                  sourceStartFrame: start,
                  frameCount: math.min(48000, manifest.sampleFrames - start),
                  cancelToken: token);
              try {
                if (token.isCancelled) throw token.cancelError!;
                final window = _ResidentWindow(
                    assetId,
                    start,
                    _renderer.preparePcm(buses: [
                      for (final channel in manifest.channels)
                        decoded.channels[channel]!
                    ]));
                desired[key] = window;
                created.add(window);
              } finally {
                decoded.release();
              }
            }
          }
          start += 48000;
        }
      }
      return desired.values.toList();
    } catch (_) {
      for (final w in created) {
        _renderer.releasePcm(w.pcm);
      }
      rethrow;
    }
  }

  NativeArrangementPlan _plan(
      TimelineModel model,
      Map<String, PreparedStemManifest> manifests,
      List<_ResidentWindow> windows,
      {Map<String, List<NativeMixBus>>? gains,
      Map<String, int>? overrideMasks}) {
    final offset = clock.frameOffset;
    return NativeMixSchedule.compileArrangement(
        timeline: model,
        sampleRate: _renderer.sampleRate,
        maxBlockFrames: _renderer.maxBlockFrames,
        revision: ++_revision,
        clock: NativeMixClockAnchor(
            nativeFrame: math.max(0, offset),
            timelineFrame: math.max(0, -offset)),
        inputs: {
          for (final clip in model.clips)
            clip.id: NativeArrangementClipInput(
                instanceId: _instance(clip),
                assetId: _asset(manifests[_key(clip)]!),
                sourceFrameCount: manifests[_key(clip)]!.sampleFrames,
                sourceFileHash: manifests[_key(clip)]!.sourceFileHash,
                stemManifest: manifests[_key(clip)]!,
                stemOverrideMask:
                    (overrideMasks ?? _overrideMasks)[_key(clip)] ?? 0,
                busChannels: manifests[_key(clip)]!.channels,
                buses: (gains ?? _gains)[_key(clip)] ??
                    [
                      for (final _ in manifests[_key(clip)]!.channels)
                        const NativeMixBus()
                    ],
                windows: windows
                    .where((w) => w.assetId == _asset(manifests[_key(clip)]!))
                    .map((w) => w.native))
        });
  }

  Future<int> _install(
      TimelineModel model,
      Map<String, PreparedStemManifest> manifests,
      List<_ResidentWindow> windows,
      {required bool acknowledge,
      Map<String, List<NativeMixBus>>? gains,
      Map<String, int>? overrideMasks}) async {
    late NativeArrangementPlan candidate;
    try {
      candidate = _plan(model, manifests, windows,
          gains: gains, overrideMasks: overrideMasks);
      final result = _renderer.submitArrangement(candidate);
      if (result != NativeMixSubmitResult.accepted) {
        throw StateError('Native arrangement rejected: $result.');
      }
    } catch (_) {
      _discardNewWindows(windows);
      rethrow;
    }
    final old = _windows;
    _windows = windows;
    // Retirement requests cannot release current/queued native loans; renderer
    // polls each opaque handle's COMPLETE fence independently from revision ACK.
    for (final w in old.where((w) => !windows.contains(w))) {
      _renderer.releasePcm(w.pcm);
    }
    if (acknowledge) await _ack(candidate.revision);
    return candidate.revision;
  }

  void _discardNewWindows(List<_ResidentWindow> windows) {
    for (final window in windows.where((w) => !_windows.contains(w))) {
      _renderer.releasePcm(window.pcm);
    }
  }

  Future<void> _ack(int revision) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_renderer.pollAppliedRevision() < revision) {
      final error = _renderer.deviceError;
      if (error != null) throw error;
      if (DateTime.now().isAfter(deadline)) {
        // A queued but unacknowledged revision must never become audible later
        // behind an unchanged canonical document. Gate until explicit retry.
        _needsRecovery = true;
        await clock.pause();
        throw StateError(
            'Native revision $revision was queued but not acknowledged; pause and retry.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  @override
  void cancelPreparation() =>
      _preparation?.cancel('Prepared request cancelled');

  @override
  Future<void> seek(int globalMs) {
    _preparation?.cancel('Native seek superseded preparation');
    return _serial(() async {
      final wasPlaying = clock.isPlaying;
      await clock.pause();
      final windows = await _prepare(_model, _manifests, globalMs);
      clock.reanchor(globalMs);
      try {
        await _install(_model, _manifests, windows, acknowledge: false);
      } catch (_) {
        _needsRecovery = true;
        rethrow;
      }
      _needsRecovery = false;
      clock.publish();
      if (wasPlaying) await clock.play();
    });
  }

  @override
  Future<StemGainAcknowledgement> setStemGain(
          String queueItemId, String channel, double gain,
          {int rampMs = 8}) =>
      _serial(() async {
        if (!gain.isFinite ||
            gain < 0 ||
            gain > 1 ||
            rampMs < 1 ||
            rampMs > 250) {
          throw ArgumentError('Stem gain/ramp outside supported range.');
        }
        if (!clock.isPlaying) {
          throw StateError(
              'Live stem control requires running native playback.');
        }
        final clip =
            activeClips.where((c) => _key(c) == queueItemId).firstOrNull;
        if (clip == null) {
          throw StateError('Stem control requires an active queue occurrence.');
        }
        final manifest = _manifests[queueItemId]!;
        final index = manifest.channels.indexOf(channel);
        if (index < 0) throw ArgumentError('Unknown disjoint stem channel.');
        final controls = List<NativeMixBus>.of(_gains[queueItemId] ??
            [for (final _ in manifest.channels) const NativeMixBus()]);
        controls[index] = NativeMixBus(gain: gain, rampFrames: rampMs * 48);
        final candidate = {..._gains, queueItemId: controls};
        final masks = {
          ..._overrideMasks,
          queueItemId: (_overrideMasks[queueItemId] ?? 0) | (1 << index)
        };
        final captureSourcePositionMs = clip.sourcePositionAt(clock.positionMs);
        final revision = await _install(_model, _manifests, _windows,
            acknowledge: true, gains: candidate, overrideMasks: masks);
        _gains[queueItemId] = List.unmodifiable(controls);
        _overrideMasks[queueItemId] = masks[queueItemId]!;
        return StemGainAcknowledgement(
            queueItemId: queueItemId,
            sourceFileHash: manifest.sourceFileHash,
            stemModelVersion: manifest.stemModelVersion,
            captureSourcePositionMs: captureSourcePositionMs,
            channel: channel,
            gain: gain,
            sourcePositionMs: clip.sourcePositionAt(clock.positionMs),
            revision: revision);
      });

  @override
  Future<void> clearStemOverrides(String queueItemId) => _serial(() async {
        if (!clock.isPlaying) {
          throw StateError(
              'Clearing overrides requires running native playback.');
        }
        final manifest = _manifests[queueItemId];
        if (manifest == null ||
            !activeClips.any((c) => _key(c) == queueItemId)) {
          throw StateError('Stem control requires an active queue occurrence.');
        }
        final controls = [
          for (final _ in manifest.channels) const NativeMixBus()
        ];
        await _install(_model, _manifests, _windows,
            acknowledge: true,
            gains: {..._gains, queueItemId: controls},
            overrideMasks: {..._overrideMasks, queueItemId: 0});
        _gains.remove(queueItemId);
        _overrideMasks.remove(queueItemId);
      });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    _preparation?.cancel('Playback closing');
    _timer.cancel();
    await clock.pause();
    await _chain;
    // A failed native close retains the entire renderer and file owners for retry.
    _renderer.close();
    _closed = true;
    for (final decoder in _decoders.values) {
      await decoder.close();
    }
    _decoders.clear();
    await clock.dispose();
    await _errors.close();
  }
}
