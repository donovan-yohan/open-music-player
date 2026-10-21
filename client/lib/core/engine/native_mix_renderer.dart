import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

// ABI v1: normal C alignment, field order/types from soundq_mix.h. No packing.
final class _Config extends ffi.Struct {
  @ffi.Uint32()
  external int abiVersion;
  @ffi.Uint32()
  external int sampleRate;
  @ffi.Uint32()
  external int maxBlockFrames;
  @ffi.Uint64()
  external int maxAssetFrames;
}

final class _Pcm extends ffi.Struct {
  @ffi.Uint32()
  external int sampleRate;
  @ffi.Uint32()
  external int busCount;
  @ffi.Uint64()
  external int frameCount;
  @ffi.Array(5)
  external ffi.Array<ffi.Pointer<ffi.Float>> buses;
}

final class _Bus extends ffi.Struct {
  @ffi.Float()
  external double gain;
  @ffi.Uint32()
  external int muted;
  @ffi.Uint32()
  external int rampFrames;
}

final class _Deck extends ffi.Struct {
  @ffi.Uint32()
  external int slot;
  @ffi.Uint64()
  external int instanceId;
  external _Pcm pcm;
  @ffi.Uint64()
  external int startFrame;
  @ffi.Uint64()
  external int endFrame;
  @ffi.Uint64()
  external int sourceStartFrame;
  @ffi.Uint32()
  external int hasSeek;
  @ffi.Uint64()
  external int seekFrame;
  @ffi.Uint64()
  external int seekSourceFrame;
  @ffi.Array(5)
  external ffi.Array<_Bus> buses;
}

final class _Plan extends ffi.Struct {
  @ffi.Uint64()
  external int revision;
  @ffi.Uint32()
  external int deckCount;
  @ffi.Float()
  external double masterGain;
  @ffi.Array(4)
  external ffi.Array<_Deck> decks;
}

final class _Schedule extends ffi.Opaque {}

final class _ScheduleClip extends ffi.Struct {
  @ffi.Uint64()
  external int instanceId;
  @ffi.Uint64()
  external int assetId;
  @ffi.Uint64()
  external int startFrame;
  @ffi.Uint64()
  external int endFrame;
  @ffi.Uint64()
  external int sourceStartFrame;
  @ffi.Uint64()
  external int sourceFrameCount;
  @ffi.Uint32()
  external int busCount;
  @ffi.Array(5)
  external ffi.Array<_Bus> buses;
}

final class _PcmWindow extends ffi.Struct {
  @ffi.Uint64()
  external int assetId;
  @ffi.Uint64()
  external int sourceStartFrame;
  external _Pcm pcm;
}

final class _ScheduleDesc extends ffi.Struct {
  @ffi.Uint64()
  external int revision;
  @ffi.Float()
  external double masterGain;
  @ffi.Uint32()
  external int clipCount;
  external ffi.Pointer<_ScheduleClip> clips;
  @ffi.Uint32()
  external int windowCount;
  external ffi.Pointer<_PcmWindow> windows;
}

// Additive symbols are lazy so legacy/offline mixer-only libraries still work.
class _ArrangementApi {
  _ArrangementApi(ffi.DynamicLibrary library) {
    create = library.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_Engine>, ffi.Pointer<_ScheduleDesc>,
            ffi.Pointer<ffi.Pointer<_Schedule>>),
        int Function(ffi.Pointer<_Engine>, ffi.Pointer<_ScheduleDesc>,
            ffi.Pointer<ffi.Pointer<_Schedule>>)>('sq_schedule_create');
    submit = library.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_Engine>, ffi.Pointer<_Schedule>),
        int Function(ffi.Pointer<_Engine>,
            ffi.Pointer<_Schedule>)>('sq_schedule_submit');
    state = library.lookupFunction<ffi.Int32 Function(ffi.Pointer<_Schedule>),
        int Function(ffi.Pointer<_Schedule>)>('sq_schedule_get_state');
    retire = library.lookupFunction<ffi.Int32 Function(ffi.Pointer<_Schedule>),
        int Function(ffi.Pointer<_Schedule>)>('sq_schedule_retire');
    missing = library.lookupFunction<ffi.Uint64 Function(ffi.Pointer<_Engine>),
        int Function(ffi.Pointer<_Engine>)>('sq_missing_pcm_frames');
    lastMissing = library.lookupFunction<
        ffi.Uint64 Function(ffi.Pointer<_Engine>),
        int Function(ffi.Pointer<_Engine>)>('sq_last_missing_instance');
  }
  late final int Function(ffi.Pointer<_Engine>, ffi.Pointer<_ScheduleDesc>,
      ffi.Pointer<ffi.Pointer<_Schedule>>) create;
  late final int Function(ffi.Pointer<_Engine>, ffi.Pointer<_Schedule>) submit;
  late final int Function(ffi.Pointer<_Schedule>) state, retire;
  late final int Function(ffi.Pointer<_Engine>) missing, lastMissing;
}

final class _StemEvent extends ffi.Struct {
  @ffi.Uint64()
  external int sourceFrame;
  @ffi.Uint32()
  external int bus;
  @ffi.Uint32()
  external int rampFrames;
  @ffi.Float()
  external double gain;
}

final class _ClipAutomation extends ffi.Struct {
  @ffi.Uint64()
  external int instanceId;
  @ffi.Float()
  external double baseGain;
  @ffi.Uint64()
  external int envelopeSourceStartFrame;
  @ffi.Uint64()
  external int envelopeFrameCount;
  @ffi.Uint64()
  external int fadeInFrames;
  @ffi.Uint64()
  external int fadeOutFrames;
  @ffi.Uint32()
  external int fadeCurve;
  @ffi.Uint32()
  external int stemOverrideMask;
  @ffi.Uint32()
  external int eventCount;
  external ffi.Pointer<_StemEvent> events;
}

class _AutomationApi {
  _AutomationApi(ffi.DynamicLibrary library) {
    create = library.lookupFunction<
            ffi.Int32 Function(
                ffi.Pointer<_Engine>,
                ffi.Pointer<_ScheduleDesc>,
                ffi.Uint32,
                ffi.Pointer<_ClipAutomation>,
                ffi.Pointer<ffi.Pointer<_Schedule>>),
            int Function(
                ffi.Pointer<_Engine>,
                ffi.Pointer<_ScheduleDesc>,
                int,
                ffi.Pointer<_ClipAutomation>,
                ffi.Pointer<ffi.Pointer<_Schedule>>)>(
        'sq_schedule_create_automated');
  }
  late final int Function(ffi.Pointer<_Engine>, ffi.Pointer<_ScheduleDesc>, int,
      ffi.Pointer<_ClipAutomation>, ffi.Pointer<ffi.Pointer<_Schedule>>) create;
}

class _ArrangementLease {
  _ArrangementLease(this.handle, this.assets);
  final ffi.Pointer<_Schedule> handle;
  final Set<NativePreparedPcm> assets;
}

final class _Engine extends ffi.Opaque {}

final class _Device extends ffi.Opaque {}

/// Numeric ABI result and native OS code are independent diagnostic snapshots.
/// Values are documented in soundq_device.h (0 means success).
class NativeMixDeviceException implements Exception {
  const NativeMixDeviceException(this.operation, this.result, this.nativeCode);
  final String operation;
  final int result;
  final int nativeCode;

  @override
  String toString() =>
      'NativeMixDeviceException($operation: result=$result, nativeCode=$nativeCode)';
}

// Resolved lazily, exclusively from the SAME library that created the engine.
// A mixer-only library remains usable offline, without device ABI symbols.
class _DeviceApi {
  _DeviceApi(ffi.DynamicLibrary library) {
    open = library.lookupFunction<
        ffi.Pointer<_Device> Function(
            ffi.Pointer<_Engine>, ffi.Uint32, ffi.Uint32),
        ffi.Pointer<_Device> Function(
            ffi.Pointer<_Engine>, int, int)>('sq_device_open');
    start = library.lookupFunction<ffi.Int32 Function(ffi.Pointer<_Device>),
        int Function(ffi.Pointer<_Device>)>('sq_device_start');
    pause = library.lookupFunction<ffi.Int32 Function(ffi.Pointer<_Device>),
        int Function(ffi.Pointer<_Device>)>('sq_device_pause');
    close = library.lookupFunction<ffi.Int32 Function(ffi.Pointer<_Device>),
        int Function(ffi.Pointer<_Device>)>('sq_device_close');
    error = library.lookupFunction<ffi.Int32 Function(ffi.Pointer<_Device>),
        int Function(ffi.Pointer<_Device>)>('sq_device_error');
    nativeError = library.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_Device>),
        int Function(ffi.Pointer<_Device>)>('sq_device_native_error');
  }
  late final ffi.Pointer<_Device> Function(ffi.Pointer<_Engine>, int, int) open;
  late final int Function(ffi.Pointer<_Device>) start,
      pause,
      close,
      error,
      nativeError;
}

class _Memory {
  _Memory() {
    final libc = ffi.DynamicLibrary.open(Platform.isMacOS || Platform.isIOS
        ? '/usr/lib/libSystem.B.dylib'
        : Platform.isWindows
            ? 'msvcrt.dll'
            : Platform.isAndroid
                ? 'libc.so'
                : 'libc.so.6');
    _calloc = libc.lookupFunction<
        ffi.Pointer<ffi.Void> Function(ffi.Size, ffi.Size),
        ffi.Pointer<ffi.Void> Function(int, int)>('calloc');
    _free = libc.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)>('free');
  }
  late final ffi.Pointer<ffi.Void> Function(int, int) _calloc;
  late final void Function(ffi.Pointer<ffi.Void>) _free;

  ffi.Pointer<T> allocate<T extends ffi.NativeType>(int bytes) {
    final p = _calloc(1, bytes);
    if (p == ffi.nullptr) throw StateError('Native allocation failed');
    return p.cast<T>();
  }

  void free(ffi.Pointer<ffi.NativeType> p) => _free(p.cast());
}

class NativeMixBus {
  const NativeMixBus({this.gain = 1, this.muted = false, this.rampFrames = 0});
  final double gain;
  final bool muted;
  final int rampFrames;
}

/// Immutable frame mapping; source frame zero is the prepared window's origin.
class NativeMixDeck {
  NativeMixDeck({
    required this.slot,
    required this.instanceId,
    required this.pcm,
    required this.startFrame,
    required this.endFrame,
    this.sourceStartFrame = 0,
    required Iterable<NativeMixBus> buses,
    this.seekFrame,
    this.seekSourceFrame,
    this.playbackRate = 1,
  }) : buses = List.unmodifiable(buses);
  final int slot;
  final int instanceId;
  final NativePreparedPcm pcm;
  final int startFrame;
  final int endFrame;
  final int sourceStartFrame;
  final List<NativeMixBus> buses;
  final int? seekFrame;
  final int? seekSourceFrame;
  final double playbackRate;
}

class NativeMixPlan {
  NativeMixPlan({
    required this.revision,
    required Iterable<NativeMixDeck> decks,
    this.masterGain = 1,
  }) : decks = List.unmodifiable(decks);
  final int revision;
  final List<NativeMixDeck> decks;
  final double masterGain;
}

/// Absolute source-clock event. Initial gain is one; at sourceFrame a ramp
/// starts from the actually reached prior value, reaching gain +rampFrames later.
class NativeStemGainEvent {
  const NativeStemGainEvent(
      {required this.sourceFrame,
      required this.bus,
      required this.gain,
      required this.rampFrames});
  final int sourceFrame, bus, rampFrames;
  final double gain;
}

/// Full immutable metadata independent of residency. IDs come from verified
/// source/channel identity. Live bus controls multiply authored gains unless
/// the corresponding stemOverrideMask bit bypasses authored replay. Clip base
/// gain/fades apply once, independently of those controls and source windows.
class NativeArrangementClip {
  NativeArrangementClip({
    required this.instanceId,
    required this.assetId,
    required this.startFrame,
    required this.endFrame,
    required this.sourceFrameCount,
    this.sourceStartFrame = 0,
    required Iterable<NativeMixBus> buses,
    this.baseGain = 1,
    int? envelopeSourceStartFrame,
    int? envelopeFrameCount,
    this.fadeInFrames = 0,
    this.fadeOutFrames = 0,
    this.equalPowerFade = true,
    this.stemOverrideMask = 0,
    Iterable<NativeStemGainEvent> stemEvents = const [],
  })  : buses = List.unmodifiable(buses),
        envelopeSourceStartFrame = envelopeSourceStartFrame ?? sourceStartFrame,
        envelopeFrameCount = envelopeFrameCount ?? endFrame - startFrame,
        stemEvents = List.unmodifiable(stemEvents);
  final int instanceId;
  final int assetId;
  final int startFrame;
  final int endFrame;
  final int sourceStartFrame;
  final int sourceFrameCount;
  final List<NativeMixBus> buses;
  final double baseGain;
  final int envelopeSourceStartFrame,
      envelopeFrameCount,
      fadeInFrames,
      fadeOutFrames;
  final bool equalPowerFade;

  /// Selected bus bits bypass authored curves; live controls remain separate.
  final int stemOverrideMask;
  final List<NativeStemGainEvent> stemEvents;
  bool get _hasAutomation =>
      baseGain != 1 ||
      fadeInFrames != 0 ||
      fadeOutFrames != 0 ||
      stemOverrideMask != 0 ||
      stemEvents.isNotEmpty;
}

/// A borrowed decoded window, whose PCM frame zero represents this source origin.
/// Missing windows intentionally produce silence plus native diagnostics.
class NativeArrangementWindow {
  const NativeArrangementWindow({
    required this.assetId,
    required this.pcm,
    this.sourceStartFrame = 0,
  });
  final int assetId;
  final NativePreparedPcm pcm;
  final int sourceStartFrame;
}

class NativeArrangementPlan {
  NativeArrangementPlan({
    required this.revision,
    required Iterable<NativeArrangementClip> clips,
    required Iterable<NativeArrangementWindow> windows,
    this.masterGain = 1,
  })  : clips = List.unmodifiable(clips),
        windows = List.unmodifiable(windows);
  final int revision;
  final List<NativeArrangementClip> clips;
  final List<NativeArrangementWindow> windows;
  final double masterGain;

  static const maxClips = 16384;
  static const maxWindows = 128;
  static const maxResidentFrames = 1048576;
  static const maxSpans = 65536;
  static const maxBoundariesPerBlock = 64;
  static const maxEventsPerClip = 2048;
  static const maxEvents = 4096;
  static const maxEventsPerBlock = 64;
}

enum NativeMixSubmitResult { accepted, invalid, queueFull, staleRevision, busy }

/// Owned, copied float32 stereo PCM. No pointer or mutable view escapes.
@pragma('vm:isolate-unsendable')
class NativePreparedPcm {
  NativePreparedPcm._(this._owner, this._buses, this.frameCount);
  final NativeMixRenderer _owner;
  final List<ffi.Pointer<ffi.Float>> _buses;
  final int frameCount;
  int get busCount => _buses.length;
  int get sampleRate => _owner.sampleRate;
  bool _retiring = false;
  bool _released = false;
  bool get isReleased => _released;
}

class _LeaseSnapshot {
  _LeaseSnapshot(this.revision, this.assets);
  final int revision;
  final Set<NativePreparedPcm> assets;
}

/// Single-isolate producer owning one SPSC engine. The sole render consumer is
/// either synchronous offline rendering OR an attached native device, never both.
/// No raw pointer escapes. Device close must succeed before destruction/free;
/// a failed close retains the gated handle and renderer for an explicit retry.
///
/// Dart allocation/copy/polling is outside sq_render, NOT realtime safe. Call
/// close explicitly; no GC finalizer can establish a renderer-thread barrier.
@pragma('vm:isolate-unsendable')
class NativeMixRenderer {
  NativeMixRenderer._({
    required this.sampleRate,
    required this.maxBlockFrames,
    required this.maxAssetFrames,
    required this.maxPreparedBytes,
    required ffi.DynamicLibrary library,
  }) : _library = library {
    _create = library.lookupFunction<
        ffi.Pointer<_Engine> Function(ffi.Pointer<_Config>),
        ffi.Pointer<_Engine> Function(ffi.Pointer<_Config>)>('sq_create');
    _destroy = library.lookupFunction<ffi.Void Function(ffi.Pointer<_Engine>),
        void Function(ffi.Pointer<_Engine>)>('sq_destroy');
    _submit = library.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_Engine>, ffi.Pointer<_Plan>),
        int Function(ffi.Pointer<_Engine>, ffi.Pointer<_Plan>)>('sq_submit');
    _render = library.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<_Engine>, ffi.Pointer<ffi.Float>, ffi.Uint32),
        int Function(
            ffi.Pointer<_Engine>, ffi.Pointer<ffi.Float>, int)>('sq_render');
    _applied = library.lookupFunction<ffi.Uint64 Function(ffi.Pointer<_Engine>),
        int Function(ffi.Pointer<_Engine>)>('sq_applied_revision');
    _frames = library.lookupFunction<ffi.Uint64 Function(ffi.Pointer<_Engine>),
        int Function(ffi.Pointer<_Engine>)>('sq_rendered_frames');
    final config = _memory.allocate<_Config>(ffi.sizeOf<_Config>());
    try {
      config.ref
        ..abiVersion = 1
        ..sampleRate = sampleRate
        ..maxBlockFrames = maxBlockFrames
        ..maxAssetFrames = maxAssetFrames;
      _engine = _create(config);
      if (_engine == ffi.nullptr) throw StateError('sq_create rejected config');
      _plan = _memory.allocate<_Plan>(ffi.sizeOf<_Plan>());
      _output = _memory.allocate<ffi.Float>(maxBlockFrames * 2 * 4);
    } catch (_) {
      if (_engine != ffi.nullptr) _destroy(_engine);
      if (_plan != ffi.nullptr) _memory.free(_plan);
      rethrow;
    } finally {
      _memory.free(config);
    }
  }

  factory NativeMixRenderer.open({
    required String libraryPath,
    required int sampleRate,
    required int maxBlockFrames,
    required int maxAssetFrames,
    required int maxPreparedBytes,
  }) {
    _uint(sampleRate, 0xffffffff, 'sampleRate', positive: true);
    _uint(maxBlockFrames, 65536, 'maxBlockFrames', positive: true);
    _uint(maxAssetFrames, _maxInt ~/ 8, 'maxAssetFrames', positive: true);
    _uint(maxPreparedBytes, _maxInt, 'maxPreparedBytes', positive: true);
    return NativeMixRenderer._(
      sampleRate: sampleRate,
      maxBlockFrames: maxBlockFrames,
      maxAssetFrames: maxAssetFrames,
      maxPreparedBytes: maxPreparedBytes,
      library: ffi.DynamicLibrary.open(libraryPath),
    );
  }

  final int sampleRate;
  final int maxBlockFrames;
  final int maxAssetFrames;
  final int maxPreparedBytes;
  final ffi.DynamicLibrary _library;
  _ArrangementApi? _arrangementApi;
  _AutomationApi? _automationApi;
  final _arrangements = <_ArrangementLease>[];
  _DeviceApi? _deviceApi;
  ffi.Pointer<_Device> _device = ffi.nullptr;
  final _memory = _Memory();
  final _assets = <NativePreparedPcm>{};
  final _pending = <_LeaseSnapshot>[];
  Set<NativePreparedPcm> _current = {};
  int _preparedBytes = 0;
  bool _closed = false;
  ffi.Pointer<_Engine> _engine = ffi.nullptr;
  ffi.Pointer<_Plan> _plan = ffi.nullptr;
  ffi.Pointer<ffi.Float> _output = ffi.nullptr;
  late final ffi.Pointer<_Engine> Function(ffi.Pointer<_Config>) _create;
  late final void Function(ffi.Pointer<_Engine>) _destroy;
  late final int Function(ffi.Pointer<_Engine>, ffi.Pointer<_Plan>) _submit;
  late final int Function(ffi.Pointer<_Engine>, ffi.Pointer<ffi.Float>, int)
      _render;
  late final int Function(ffi.Pointer<_Engine>) _applied;
  late final int Function(ffi.Pointer<_Engine>) _frames;

  /// Attach one paused native consumer with this engine's retained config.
  /// No configuration overrides and no second library/engine are accepted.
  void openDevice() {
    _checkOpen();
    if (_device != ffi.nullptr) throw StateError('Device already attached');
    final api = _deviceApi ??= _DeviceApi(_library);
    final device = api.open(_engine, sampleRate, maxBlockFrames);
    if (device == ffi.nullptr) {
      throw NativeMixDeviceException(
          'open', api.error(ffi.nullptr), api.nativeError(ffi.nullptr));
    }
    _device = device;
  }

  void startDevice() {
    final api = _requireDevice();
    _checkDeviceResult('start', api.start(_device));
  }

  /// Native pause gates/drains renders even on a reported OS pause failure.
  /// The device remains attached, so manual rendering stays prohibited.
  void pauseDevice() {
    final api = _requireDevice();
    _checkDeviceResult('pause', api.pause(_device));
  }

  /// First sticky failure, or null without an attached/failed device. Result and
  /// native code are separate reads, not an atomic pair. Open errors are thrown.
  NativeMixDeviceException? get deviceError {
    _checkOpen();
    if (_device == ffi.nullptr) return null;
    final result = _deviceApi!.error(_device);
    return result == 0
        ? null
        : NativeMixDeviceException(
            'device', result, _deviceApi!.nativeError(_device));
  }

  /// Only successful native close releases consumer ownership. Failure leaves
  /// the handle attached and gated for retry; no engine/PCM is freed here.
  void closeDevice() {
    if (_closed || _device == ffi.nullptr) return;
    _checkDeviceResult('close', _deviceApi!.close(_device));
    _device = ffi.nullptr;
  }

  _DeviceApi _requireDevice() {
    _checkOpen();
    if (_device == ffi.nullptr) throw StateError('No device attached');
    return _deviceApi!;
  }

  void _checkDeviceResult(String operation, int result) {
    if (result != 0) {
      throw NativeMixDeviceException(
          operation, result, _deviceApi!.nativeError(_device));
    }
  }

  NativePreparedPcm preparePcm({required List<Float32List> buses}) {
    _checkOpen();
    if (buses.isEmpty || buses.length > 5) {
      throw ArgumentError('PCM must have 1..5 stereo buses');
    }
    final samples = buses.first.length;
    if (samples == 0 ||
        samples.isOdd ||
        samples ~/ 2 > maxAssetFrames ||
        buses.any((b) => b.length != samples)) {
      throw ArgumentError(
          'PCM must be aligned equal-length bounded stereo buses');
    }
    final bytes = samples * 4 * buses.length;
    if (bytes > maxPreparedBytes - _preparedBytes) {
      throw StateError('Prepared PCM byte budget exceeded');
    }
    final pointers = <ffi.Pointer<ffi.Float>>[];
    try {
      for (final bus in buses) {
        final p = _memory.allocate<ffi.Float>(samples * 4);
        pointers.add(p);
        p.asTypedList(samples).setAll(0, bus);
      }
    } catch (_) {
      for (final p in pointers) {
        _memory.free(p);
      }
      rethrow;
    }
    final asset =
        NativePreparedPcm._(this, List.unmodifiable(pointers), samples ~/ 2);
    _assets.add(asset);
    _preparedBytes += bytes;
    return asset;
  }

  int get appliedRevision {
    _checkOpen();
    return _applied(_engine);
  }

  int get renderedFrames {
    _checkOpen();
    return _frames(_engine);
  }

  int get preparedBytes => _preparedBytes;

  /// Independent native snapshots, not an atomic pair with cursor or revision.
  int get missingPcmFrames {
    _checkOpen();
    return (_arrangementApi ??= _ArrangementApi(_library)).missing(_engine);
  }

  int get lastMissingInstance {
    _checkOpen();
    return (_arrangementApi ??= _ArrangementApi(_library)).lastMissing(_engine);
  }

  /// Explicit polling bounds host/native metadata; no finalizers or callback frees.
  int get retainedArrangementCount => _arrangements.length;
  static const maxRetainedArrangements = 9; // Eight pending plus current.

  /// Completion acknowledgement, not queue consumption, is the reclamation
  /// barrier. A later queued snapshot may restore an otherwise removed handle.
  int pollAppliedRevision() {
    final revision = appliedRevision;
    while (_pending.isNotEmpty && _pending.first.revision <= revision) {
      _current = _pending.removeAt(0).assets;
    }
    // Native publishes applied revision BEFORE COMPLETE. Never infer handle
    // completion from that independent acknowledgement (or from clip EOF).
    final complete = _arrangements
        .where((lease) => _arrangementApi!.state(lease.handle) == 2)
        .toList();
    for (final lease in complete) {
      _retireArrangement(lease.handle);
      _arrangements.remove(lease);
    }
    _collectRetired();
    return revision;
  }

  /// Irreversible retirement request. Existing current/queued loans remain live;
  /// all subsequent submissions referencing this handle are rejected.
  void releasePcm(NativePreparedPcm pcm) {
    _checkOpen();
    if (!identical(pcm._owner, this)) throw StateError('Foreign PCM owner');
    pcm._retiring = true;
    pollAppliedRevision();
  }

  void _collectRetired() {
    final reclaim = _assets
        .where((asset) =>
            asset._retiring &&
            !_current.contains(asset) &&
            !_pending.any((p) => p.assets.contains(asset)) &&
            !_arrangements.any((p) => p.assets.contains(asset)))
        .toList();
    for (final asset in reclaim) {
      for (final p in asset._buses) {
        _memory.free(p);
      }
      asset._released = true;
      _preparedBytes -= asset.frameCount * 2 * 4 * asset.busCount;
      _assets.remove(asset);
    }
  }

  /// Compile immutable metadata off callback and enqueue on this engine's SAME
  /// producer/revision queue. Native handles are private and automatically retired
  /// by polling after COMPLETE. Failed enqueue retires its READY handle immediately;
  /// retry by resubmitting metadata. No decoding or source identity inference.
  ///
  /// Up to 16384 clips, 128 windows, 1048576 resident frames per candidate;
  /// aggregate PCM bytes across ALL retained revisions obey maxPreparedBytes.
  /// Native validation atomically rejects fifth overlap, inconsistent identities,
  /// overlapping residency, span overflow and >64 boundaries/maxBlockFrames.
  NativeMixSubmitResult submitArrangement(NativeArrangementPlan plan) {
    _checkOpen();
    pollAppliedRevision();
    _uint(plan.revision, _maxInt, 'revision', positive: true);
    _gain(plan.masterGain);
    if (plan.clips.length > NativeArrangementPlan.maxClips ||
        plan.windows.length > NativeArrangementPlan.maxWindows) {
      throw ArgumentError('Arrangement metadata limit exceeded');
    }
    var eventCount = 0;
    for (final clip in plan.clips) {
      _uint(clip.instanceId, _maxInt, 'instanceId', positive: true);
      _uint(clip.assetId, _maxInt, 'assetId', positive: true);
      _uint(clip.startFrame, _maxInt, 'startFrame');
      _uint(clip.endFrame, _maxInt, 'endFrame', positive: true);
      _uint(clip.sourceStartFrame, _maxInt, 'sourceStartFrame');
      _uint(clip.sourceFrameCount, _maxInt, 'sourceFrameCount', positive: true);
      if (clip.buses.isEmpty || clip.buses.length > 5) {
        throw ArgumentError('Clip must have 1..5 buses');
      }
      _gain(clip.baseGain);
      _uint(clip.envelopeSourceStartFrame, _maxInt, 'envelopeSourceStartFrame');
      _uint(clip.envelopeFrameCount, _maxInt, 'envelopeFrameCount',
          positive: true);
      _uint(clip.fadeInFrames, clip.envelopeFrameCount, 'fadeInFrames');
      _uint(clip.fadeOutFrames, clip.envelopeFrameCount - clip.fadeInFrames,
          'fadeOutFrames');
      _uint(clip.stemOverrideMask, (1 << clip.buses.length) - 1,
          'stemOverrideMask');
      if (clip.stemEvents.length > NativeArrangementPlan.maxEventsPerClip) {
        throw ArgumentError('Clip event limit exceeded');
      }
      eventCount += clip.stemEvents.length;
      NativeStemGainEvent? previous;
      for (final event in clip.stemEvents) {
        _uint(
            event.sourceFrame, clip.sourceFrameCount - 1, 'event.sourceFrame');
        _uint(event.bus, clip.buses.length - 1, 'event.bus');
        _uint(event.rampFrames, 0xffffffff, 'event.rampFrames');
        _gain(event.gain);
        if (previous != null &&
            (event.sourceFrame < previous.sourceFrame ||
                (event.sourceFrame == previous.sourceFrame &&
                    event.bus <= previous.bus))) {
          throw ArgumentError(
              'Events must be unique ordered (sourceFrame,bus)');
        }
        previous = event;
      }
      for (final bus in clip.buses) {
        _gain(bus.gain);
        _uint(bus.rampFrames, 0xffffffff, 'rampFrames');
      }
    }
    if (eventCount > NativeArrangementPlan.maxEvents) {
      throw ArgumentError('Plan event limit exceeded');
    }
    var residentFrames = 0;
    for (final window in plan.windows) {
      _uint(window.assetId, _maxInt, 'assetId', positive: true);
      _uint(window.sourceStartFrame, _maxInt, 'sourceStartFrame');
      _requirePcm(window.pcm);
      residentFrames += window.pcm.frameCount;
      if (residentFrames > NativeArrangementPlan.maxResidentFrames) {
        throw ArgumentError('Arrangement resident frame limit exceeded');
      }
    }
    // In-flight completion and queue capacity are independent. Conservatively
    // backpressure rather than allowing an unbounded handle registry under churn.
    if (_arrangements.length >= maxRetainedArrangements) {
      return NativeMixSubmitResult.queueFull;
    }
    final api = _arrangementApi ??= _ArrangementApi(_library);
    ffi.Pointer<_ScheduleDesc> desc = ffi.nullptr;
    ffi.Pointer<_ScheduleClip> clips = ffi.nullptr;
    ffi.Pointer<_PcmWindow> windows = ffi.nullptr;
    ffi.Pointer<ffi.Pointer<_Schedule>> out = ffi.nullptr;
    ffi.Pointer<_Schedule> handle = ffi.nullptr;
    ffi.Pointer<_ClipAutomation> automation = ffi.nullptr;
    ffi.Pointer<_StemEvent> events = ffi.nullptr;
    try {
      desc = _memory.allocate<_ScheduleDesc>(ffi.sizeOf<_ScheduleDesc>());
      out = _memory.allocate<ffi.Pointer<_Schedule>>(
          ffi.sizeOf<ffi.Pointer<_Schedule>>());
      if (plan.clips.isNotEmpty) {
        clips = _memory.allocate<_ScheduleClip>(
            ffi.sizeOf<_ScheduleClip>() * plan.clips.length);
      }
      if (plan.windows.isNotEmpty) {
        windows = _memory.allocate<_PcmWindow>(
            ffi.sizeOf<_PcmWindow>() * plan.windows.length);
      }
      desc.ref
        ..revision = plan.revision
        ..masterGain = plan.masterGain
        ..clipCount = plan.clips.length
        ..clips = clips
        ..windowCount = plan.windows.length
        ..windows = windows;
      for (var i = 0; i < plan.clips.length; i++) {
        final clip = plan.clips[i];
        final native = (clips + i).ref;
        native
          ..instanceId = clip.instanceId
          ..assetId = clip.assetId
          ..startFrame = clip.startFrame
          ..endFrame = clip.endFrame
          ..sourceStartFrame = clip.sourceStartFrame
          ..sourceFrameCount = clip.sourceFrameCount
          ..busCount = clip.buses.length;
        for (var b = 0; b < clip.buses.length; b++) {
          native.buses[b]
            ..gain = clip.buses[b].gain
            ..muted = clip.buses[b].muted ? 1 : 0
            ..rampFrames = clip.buses[b].rampFrames;
        }
      }
      for (var i = 0; i < plan.windows.length; i++) {
        final window = plan.windows[i];
        final native = (windows + i).ref;
        native
          ..assetId = window.assetId
          ..sourceStartFrame = window.sourceStartFrame;
        native.pcm
          ..sampleRate = sampleRate
          ..frameCount = window.pcm.frameCount
          ..busCount = window.pcm.busCount;
        for (var b = 0; b < window.pcm.busCount; b++) {
          native.pcm.buses[b] = window.pcm._buses[b];
        }
      }
      int createdCode;
      if (plan.clips.any((c) => c._hasAutomation)) {
        final automatedApi = _automationApi ??= _AutomationApi(_library);
        automation = _memory.allocate<_ClipAutomation>(
            ffi.sizeOf<_ClipAutomation>() * plan.clips.length);
        if (eventCount > 0) {
          events = _memory
              .allocate<_StemEvent>(ffi.sizeOf<_StemEvent>() * eventCount);
        }
        var offset = 0;
        for (var i = 0; i < plan.clips.length; i++) {
          final c = plan.clips[i];
          (automation + i).ref
            ..instanceId = c.instanceId
            ..baseGain = c.baseGain
            ..envelopeSourceStartFrame = c.envelopeSourceStartFrame
            ..envelopeFrameCount = c.envelopeFrameCount
            ..fadeInFrames = c.fadeInFrames
            ..fadeOutFrames = c.fadeOutFrames
            ..fadeCurve = c.equalPowerFade ? 1 : 0
            ..stemOverrideMask = c.stemOverrideMask
            ..eventCount = c.stemEvents.length
            ..events = c.stemEvents.isEmpty ? ffi.nullptr : events + offset;
          for (final event in c.stemEvents) {
            (events + offset++).ref
              ..sourceFrame = event.sourceFrame
              ..bus = event.bus
              ..rampFrames = event.rampFrames
              ..gain = event.gain;
          }
        }
        createdCode = automatedApi.create(
            _engine, desc, plan.clips.length, automation, out);
      } else {
        createdCode = api.create(_engine, desc, out);
      }
      final created = _submitResult(createdCode);
      handle = out.value;
      if (created != NativeMixSubmitResult.accepted) return created;
      if (handle == ffi.nullptr) {
        throw StateError('Native schedule returned no handle');
      }
      final lease =
          _ArrangementLease(handle, plan.windows.map((w) => w.pcm).toSet());
      final result = _submitResult(api.submit(_engine, handle));
      if (result == NativeMixSubmitResult.accepted) {
        _arrangements.add(lease);
        // Empty snapshot displaces legacy loans, while the native handle owns
        // arrangement loans independently until its COMPLETE acknowledgement.
        _pending.add(_LeaseSnapshot(plan.revision, {}));
        handle = ffi.nullptr;
      }
      return result;
    } finally {
      if (handle != ffi.nullptr) _retireArrangement(handle);
      if (events != ffi.nullptr) _memory.free(events);
      if (automation != ffi.nullptr) _memory.free(automation);
      if (out != ffi.nullptr) _memory.free(out);
      if (windows != ffi.nullptr) _memory.free(windows);
      if (clips != ffi.nullptr) _memory.free(clips);
      if (desc != ffi.nullptr) _memory.free(desc);
    }
  }

  void _retireArrangement(ffi.Pointer<_Schedule> handle) {
    final result = _arrangementApi!.retire(handle);
    if (result != 0) {
      throw StateError('Native schedule retirement failed: $result');
    }
  }

  void _requirePcm(NativePreparedPcm pcm) {
    if (!identical(pcm._owner, this) ||
        !_assets.contains(pcm) ||
        pcm._retiring) {
      throw StateError('PCM must be live and owned by this engine');
    }
  }

  NativeMixSubmitResult submit(NativeMixPlan plan) {
    _checkOpen();
    // Keep host queue metadata bounded even if the caller only polls on submit.
    pollAppliedRevision();
    _uint(plan.revision, _maxInt, 'revision', positive: true);
    _gain(plan.masterGain);
    if (plan.decks.length > 4) {
      throw ArgumentError('A fifth deck is unsupported');
    }
    final slots = <int>{};
    for (final d in plan.decks) {
      _uint(d.slot, 3, 'slot');
      if (!slots.add(d.slot)) throw ArgumentError('Duplicate slot');
      _uint(d.instanceId, _maxInt, 'instanceId', positive: true);
      _requirePcm(d.pcm);
      _uint(d.startFrame, _maxInt, 'startFrame');
      _uint(d.endFrame, _maxInt, 'endFrame', positive: true);
      _uint(d.sourceStartFrame, d.pcm.frameCount - 1, 'sourceStartFrame');
      if (d.endFrame <= d.startFrame) {
        throw ArgumentError('Empty deck interval');
      }
      if (d.playbackRate != 1) {
        throw UnsupportedError('Native renderer is rate 1 only');
      }
      if ((d.seekFrame == null) != (d.seekSourceFrame == null)) {
        throw ArgumentError('Both seek anchors are required');
      }
      if (d.seekFrame != null) {
        _uint(d.seekFrame!, d.endFrame - 1, 'seekFrame');
        _uint(d.seekSourceFrame!, d.pcm.frameCount - 1, 'seekSourceFrame');
        if (d.seekFrame! < d.startFrame) {
          throw ArgumentError('Seek before start');
        }
      }
      if (d.buses.length != d.pcm.busCount) {
        throw ArgumentError('Bus count mismatch');
      }
      for (final bus in d.buses) {
        _gain(bus.gain);
        _uint(bus.rampFrames, 0xffffffff, 'rampFrames');
      }
    }
    // calloc initially zeros all unused fields. Every used field is overwritten.
    _plan.ref
      ..revision = plan.revision
      ..deckCount = plan.decks.length
      ..masterGain = plan.masterGain;
    for (var i = 0; i < plan.decks.length; i++) {
      final d = plan.decks[i];
      final native = _plan.ref.decks[i];
      native
        ..slot = d.slot
        ..instanceId = d.instanceId
        ..startFrame = d.startFrame
        ..endFrame = d.endFrame
        ..sourceStartFrame = d.sourceStartFrame
        ..hasSeek = d.seekFrame == null ? 0 : 1
        ..seekFrame = d.seekFrame ?? 0
        ..seekSourceFrame = d.seekSourceFrame ?? 0;
      native.pcm
        ..sampleRate = sampleRate
        ..busCount = d.pcm.busCount
        ..frameCount = d.pcm.frameCount;
      for (var b = 0; b < 5; b++) {
        native.pcm.buses[b] =
            b < d.pcm.busCount ? d.pcm._buses[b] : ffi.nullptr;
        native.buses[b]
          ..gain = b < d.buses.length ? d.buses[b].gain : 0
          ..muted = b < d.buses.length && d.buses[b].muted ? 1 : 0
          ..rampFrames = b < d.buses.length ? d.buses[b].rampFrames : 0;
      }
    }
    final result = _submitResult(_submit(_engine, _plan));
    if (result == NativeMixSubmitResult.accepted) {
      _pending.add(
          _LeaseSnapshot(plan.revision, plan.decks.map((d) => d.pcm).toSet()));
    }
    return result;
  }

  /// Manual offline block; copies output after the native call completes.
  /// Does not poll/retire leases implicitly. Not an audio-device callback.
  Float32List renderOffline(int frames) {
    _checkOpen();
    if (_device != ffi.nullptr) {
      throw StateError('Manual render prohibited while device is attached');
    }
    _uint(frames, maxBlockFrames, 'frames', positive: true);
    if (_render(_engine, _output, frames) != 0) {
      throw StateError('sq_render rejected block');
    }
    return Float32List.fromList(_output.asTypedList(frames * 2));
  }

  void close() {
    if (_closed) return;
    closeDevice(); // Must succeed BEFORE marking closed, destroy or any frees.
    _closed = true;
    _destroy(
        _engine); // Device close has removed/quiesced all native consumers.
    // Destroy marks queued/current schedules COMPLETE. Delete EVERY handle
    // outside the callback BEFORE releasing any shared borrowed PCM bytes.
    for (final lease in _arrangements) {
      _retireArrangement(lease.handle);
    }
    _arrangements.clear();
    _memory.free(_plan);
    _memory.free(_output);
    for (final asset in _assets) {
      for (final p in asset._buses) {
        _memory.free(p);
      }
      asset._released = true;
    }
    _assets.clear();
    _pending.clear();
    _current = {};
    _preparedBytes = 0;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Native renderer is closed');
  }
}

NativeMixSubmitResult _submitResult(int result) => switch (result) {
      0 => NativeMixSubmitResult.accepted,
      1 => NativeMixSubmitResult.invalid,
      2 => NativeMixSubmitResult.queueFull,
      3 => NativeMixSubmitResult.staleRevision,
      4 => NativeMixSubmitResult.busy,
      _ => throw StateError('Unknown native mix result: $result'),
    };

// Dart native ints are signed. Reject overflow rather than wrapping uint64 FFI.
const _maxInt = 0x7fffffffffffffff;
void _uint(int value, int max, String name, {bool positive = false}) {
  if (value < (positive ? 1 : 0) || value > max) {
    throw ArgumentError.value(value, name, 'Out of bounds');
  }
}

void _gain(double gain) {
  if (!gain.isFinite || gain < 0 || gain > 1) {
    throw ArgumentError.value(gain, 'gain', 'Must be finite in [0,1]');
  }
}
