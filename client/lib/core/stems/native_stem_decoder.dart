import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'prepared_stem_assets.dart';
import 'prepared_stem_manifest.dart';

/// A worker or native decoder failure, never an indication of device readiness.
class NativeStemDecoderException implements Exception {
  const NativeStemDecoderException(this.message);
  final String message;
  @override
  String toString() => 'NativeStemDecoderException: $message';
}

class NativeStemMemberMetadata {
  const NativeStemMemberMetadata(
      {required this.sampleFrames,
      required this.sampleRateHz,
      required this.audioChannels,
      required this.preSkipFrames});
  final int sampleFrames;
  final int sampleRateHz;
  final int audioChannels;
  final int preSkipFrames;
}

class NativeStemMetadata {
  NativeStemMetadata._(
      this.manifestIdentity, Map<String, NativeStemMemberMetadata> members)
      : members = Map.unmodifiable(members);
  final String manifestIdentity;

  /// Includes the retained drums reference, not only the disjoint render buses.
  final Map<String, NativeStemMemberMetadata> members;
}

/// An explicitly budgeted immutable PCM copy. Release after the renderer has
/// copied/retained its own PCM; retaining views after release violates the byte
/// budget contract. No native address, engine, or mutable native view escapes.
class DecodedStemWindow {
  DecodedStemWindow._(
      this.sourceStartFrame,
      this.frameCount,
      PreparedStemManifest manifest,
      Map<String, Float32List> channels,
      this._onRelease)
      : manifestIdentity = manifest.identity,
        stemModelVersion = manifest.stemModelVersion,
        sourceFileHash = manifest.sourceFileHash,
        channelSet = manifest.channelSet,
        _channels = Map.unmodifiable(channels);
  final int sourceStartFrame;
  final int frameCount;
  final String manifestIdentity;
  final String stemModelVersion;
  final String sourceFileHash;
  final String channelSet;
  int get sampleRateHz => 48000;
  int get audioChannels => 2;
  int get byteLength => frameCount * 8 * _channels.length;
  Map<String, Float32List> _channels;
  void Function()? _onRelease;
  Map<String, Float32List> get channels {
    if (_onRelease == null) throw StateError('released decoded stem window');
    return _channels;
  }

  void release() {
    final release = _onRelease;
    if (release == null) return;
    _onRelease = null;
    _channels = const {};
    release();
  }
}

/// Owns one persistent decoder isolate and a separate retained verified lease.
/// Opening scans O(encoded bytes); neither open nor reads are deadline-safe.
/// Call only from preparation/control code, never an audio callback. This is a
/// PCM producer, not a transport, scheduler, device owner or downloader.
///
/// At most one worker request is in flight, plus [maxQueuedReads] pending jobs.
/// [maxPcmBytes] reserves worst-case output across pending AND delivered windows;
/// callers must release windows to admit more work. Per-worker transient overhead
/// is at most one native stereo scratch window plus two five-bus output copies
/// (TransferableTypedData construction), outside the reservation accounting.
@pragma('vm:isolate-unsendable')
class NativeStemDecoder {
  NativeStemDecoder(
      {required PreparedStemLease lease,
      required String libraryPath,
      this.maxWindowFrames = 48000,
      this.maxQueuedReads = 2,
      this.maxPcmBytes = 5760000,
      CancelToken? cancelToken}) {
    // PreparedStemLease's private constructor is the verification boundary.
    // Interface implementations/subclasses cannot assert that provenance.
    if (lease.runtimeType != PreparedStemLease) {
      throw ArgumentError('requires an owned verified PreparedStemLease');
    }
    if (libraryPath.isEmpty ||
        maxWindowFrames < 1 ||
        maxWindowFrames > 48000 ||
        maxQueuedReads < 0 ||
        maxQueuedReads > 8 ||
        maxPcmBytes < 1 ||
        maxPcmBytes > 16 * 1024 * 1024) {
      throw ArgumentError('invalid native stem decoder resource limits');
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    // Synchronous retain: even immediate caller release cannot race native open.
    _lease = lease.retain();
    manifest = _lease.manifest;
    // Consume expected ready failures even if the caller only awaits close().
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _eventsSubscription = _events.listen(_receive);
    if (cancelToken != null) {
      _openCancellation =
          Stream.fromFuture(cancelToken.whenCancel).listen((error) {
        // A request token must not retire an already delivered decoder.
        if (!_ready.isCompleted && !_closing) {
          _failure = error;
          _beginClose();
        }
      });
    }
    unawaited(_spawn(libraryPath));
  }

  final int maxWindowFrames;
  final int maxQueuedReads;
  final int maxPcmBytes;
  late final PreparedStemLease _lease;
  late final PreparedStemManifest manifest;
  final _events = ReceivePort();
  late final StreamSubscription<dynamic> _eventsSubscription;
  StreamSubscription<dynamic>? _openCancellation;
  final _ready = Completer<void>();
  final _closed = Completer<void>();
  final Queue<_ReadJob> _queued = Queue();
  _ReadJob? _inflight;
  SendPort? _commands;
  NativeStemMetadata? _metadata;
  Object? _failure;
  bool _closing = false;
  bool _closeSent = false;
  bool _exited = false;
  bool _nativeClosed = false;
  int _nextId = 0;
  int _reservedBytes = 0;

  Future<void> get ready => _ready.future;
  NativeStemMetadata get metadata =>
      _metadata ?? (throw StateError('native stem decoder is not ready'));
  int get reservedPcmBytes => _reservedBytes;

  Future<void> _spawn(String libraryPath) async {
    try {
      final files = <List<Object>>[];
      final directory = _lease.directory.absolute.path;
      for (final member in manifest.members.values) {
        final uri = _lease.files[member.channel];
        if (uri == null ||
            uri.scheme != 'file' ||
            uri.hasQuery ||
            uri.hasFragment ||
            File.fromUri(uri).absolute.parent.path != directory ||
            File.fromUri(uri).uri.pathSegments.last !=
                '${member.channel}.opus' ||
            member.bytes > 536870912) {
          throw const NativeStemDecoderException(
              'foreign or oversized member path');
        }
        files.add([
          member.channel,
          File.fromUri(uri).absolute.path,
          member.bytes,
          member.sampleFrames,
          member.sampleRateHz,
          member.audioChannels,
          member.encoderDelayFrames
        ]);
      }
      await Isolate.spawn(
          _decodeWorker,
          [
            _events.sendPort,
            libraryPath,
            files,
            manifest.channels,
            maxWindowFrames
          ],
          onError: _events.sendPort,
          onExit: _events.sendPort,
          errorsAreFatal: true,
          debugName: 'verified-stem-decoder');
    } catch (error) {
      _failure = error;
      await _finishExit(); // Spawn never succeeded; there can be no native owner.
    }
  }

  Future<DecodedStemWindow> readWindow(
      {required int sourceStartFrame,
      required int frameCount,
      CancelToken? cancelToken}) {
    if (_closing || _exited) {
      return Future.error(StateError('closed native stem decoder'));
    }
    if (sourceStartFrame < 0 ||
        sourceStartFrame > manifest.sampleFrames ||
        frameCount < 0 ||
        frameCount > maxWindowFrames) {
      return Future.error(ArgumentError('invalid decoded frame range'));
    }
    if (cancelToken?.isCancelled == true) {
      return Future.error(cancelToken!.cancelError!);
    }
    if (_queued.length + (_inflight == null ? 0 : 1) >= maxQueuedReads + 1) {
      return Future.error(StateError('native stem decoder queue capacity'));
    }
    final bytes = frameCount * 8 * manifest.channels.length;
    if (bytes > maxPcmBytes - _reservedBytes) {
      return Future.error(StateError('decoded stem PCM byte budget'));
    }
    final job = _ReadJob(++_nextId, sourceStartFrame, frameCount, bytes);
    _reservedBytes += bytes;
    _queued.add(job);
    if (cancelToken != null) {
      job.cancellation =
          Stream.fromFuture(cancelToken.whenCancel).listen((error) {
        if (job.settled) return; // Delivered ownership is independent of token.
        job.cancelled = error;
        if (_queued.remove(job)) _reject(job, error);
        // In-flight output is discarded only after worker completion, keeping
        // the request and byte reservation until the native read has settled.
      });
    }
    _pump();
    return job.result.future;
  }

  void _pump() {
    if (_commands == null || _metadata == null || _inflight != null) return;
    if (_closing) {
      if (!_closeSent) {
        _closeSent = true;
        _commands!.send(['close']);
      }
    } else if (_queued.isNotEmpty) {
      final job = _inflight = _queued.removeFirst();
      _commands!.send(['read', job.id, job.start, job.count]);
    }
  }

  void _receive(dynamic message) {
    if (message == null) {
      unawaited(_finishExit());
      return;
    }
    if (message is! List || message.isEmpty) return;
    switch (message[0]) {
      case 'port':
        _commands = message[1] as SendPort;
        break;
      case 'ready':
        unawaited(_openCancellation?.cancel());
        _openCancellation = null;
        _metadata = NativeStemMetadata._(manifest.identity, {
          for (final row in message[1] as List)
            row[0] as String: NativeStemMemberMetadata(
                sampleFrames: row[1] as int,
                sampleRateHz: row[2] as int,
                audioChannels: row[3] as int,
                preSkipFrames: row[4] as int),
        });
        if (!_ready.isCompleted) {
          if (_closing) {
            _ready.completeError(
                _failure ?? StateError('decoder open cancelled'));
          } else {
            _ready.complete();
          }
        }
        _pump();
        break;
      case 'window':
      case 'readError':
        final job = _inflight;
        if (job == null || job.id != message[1]) {
          _failure =
              const NativeStemDecoderException('unexpected worker response');
          _beginClose();
          return;
        }
        _inflight = null;
        if (_closing || job.cancelled != null) {
          _reject(
              job, job.cancelled ?? StateError('decoder closed during read'));
        } else if (message[0] == 'readError') {
          _reject(job, NativeStemDecoderException(message[2] as String));
        } else {
          final count = message[2] as int;
          final pcm = (message[3] as TransferableTypedData)
              .materialize()
              .asFloat32List();
          final actualBytes = count * 8 * manifest.channels.length;
          _reservedBytes -= job.bytes - actualBytes;
          job.settled = true;
          unawaited(job.cancellation?.cancel());
          job.cancellation = null;
          job.result.complete(DecodedStemWindow._(
              job.start,
              count,
              manifest,
              {
                for (var i = 0; i < manifest.channels.length; i++)
                  // Installed Flutter SDK supplies read-only typed-data views.
                  manifest.channels[i]: Float32List.sublistView(
                          pcm, i * count * 2, (i + 1) * count * 2)
                      // ignore: sdk_version_since
                      .asUnmodifiableView(),
              },
              () => _reservedBytes -= actualBytes));
        }
        _pump();
        break;
      case 'openError':
        _failure = NativeStemDecoderException(message[1] as String);
        _beginClose();
        break;
      case 'closed':
        _nativeClosed = true;
        break;
      default:
        // Dart's onError port sends [error, stack]. Never kill a worker in a
        // native call: require explicit native cleanup plus exit before unpinning.
        _failure = NativeStemDecoderException('worker failed: ${message[0]}');
        _beginClose();
    }
  }

  void _reject(_ReadJob job, Object error) {
    if (job.settled) return;
    job.settled = true;
    unawaited(job.cancellation?.cancel());
    job.cancellation = null;
    _reservedBytes -= job.bytes;
    job.result.completeError(error);
  }

  void _beginClose() {
    _closing = true;
    while (_queued.isNotEmpty) {
      _reject(_queued.removeFirst(),
          _failure ?? StateError('decoder closed before read'));
    }
    _pump();
  }

  /// Cancels queued reads, drains open/in-flight native calls, destroys every
  /// worker decoder, awaits isolate exit, THEN releases the retained file lease.
  /// Repeated calls return the same completion barrier. Delivered PCM is Dart-
  /// owned and remains valid until its independent window.release().
  Future<void> close() {
    _beginClose();
    return _closed.future;
  }

  Future<void> _finishExit() async {
    if (_exited) return;
    _exited = true;
    _failure ??= StateError('native stem decoder worker exited');
    _beginClose();
    if (!_ready.isCompleted) _ready.completeError(_failure!);
    final job = _inflight;
    _inflight = null;
    if (job != null) _reject(job, job.cancelled ?? _failure!);
    await _eventsSubscription.cancel();
    await _openCancellation?.cancel();
    _openCancellation = null;
    _events.close();
    try {
      if (_commands != null && !_nativeClosed) {
        // Do not mistake an abnormal isolate death for a native destroy fence.
        // No kill handle escapes this service; ordinary failures run finally.
        throw const NativeStemDecoderException(
            'worker exited without native cleanup acknowledgement; lease retained');
      }
      await _lease.release();
      _closed.complete();
    } catch (error, stack) {
      _closed.completeError(error, stack);
    }
  }
}

class _ReadJob {
  _ReadJob(this.id, this.start, this.count, this.bytes);
  final int id, start, count, bytes;
  final result = Completer<DecodedStemWindow>();
  StreamSubscription<dynamic>? cancellation;
  Object? cancelled;
  bool settled = false;
}

final class _Decoder extends ffi.Opaque {}

// All FFI bindings and allocations live ONLY in the worker isolate.
class _DecoderApi {
  _DecoderApi(String libraryPath) {
    final lib = ffi.DynamicLibrary.open(libraryPath);
    open = lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Uint64,
            ffi.Pointer<ffi.Pointer<_Decoder>>),
        int Function(ffi.Pointer<ffi.Char>, int,
            ffi.Pointer<ffi.Pointer<_Decoder>>)>('sq_opus_decoder_open');
    rate = lib.lookupFunction<ffi.Uint32 Function(ffi.Pointer<_Decoder>),
        int Function(ffi.Pointer<_Decoder>)>('sq_opus_decoder_sample_rate');
    channels = lib.lookupFunction<ffi.Uint32 Function(ffi.Pointer<_Decoder>),
        int Function(ffi.Pointer<_Decoder>)>('sq_opus_decoder_channels');
    frames = lib.lookupFunction<ffi.Int64 Function(ffi.Pointer<_Decoder>),
        int Function(ffi.Pointer<_Decoder>)>('sq_opus_decoder_frame_count');
    preSkip = lib.lookupFunction<ffi.Uint32 Function(ffi.Pointer<_Decoder>),
        int Function(ffi.Pointer<_Decoder>)>('sq_opus_decoder_pre_skip');
    read = lib.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_Decoder>, ffi.Int64, ffi.Uint32,
            ffi.Pointer<ffi.Float>, ffi.Size, ffi.Pointer<ffi.Uint32>),
        int Function(ffi.Pointer<_Decoder>, int, int, ffi.Pointer<ffi.Float>,
            int, ffi.Pointer<ffi.Uint32>)>('sq_opus_decoder_read_window');
    destroy = lib.lookupFunction<ffi.Void Function(ffi.Pointer<_Decoder>),
        void Function(ffi.Pointer<_Decoder>)>('sq_opus_decoder_destroy');
    finalizer = ffi.NativeFinalizer(lib.lookup('sq_opus_decoder_destroy'));
    final system = ffi.DynamicLibrary.open(Platform.isAndroid
        ? 'libc.so'
        : Platform.isLinux
            ? 'libc.so.6'
            : '/usr/lib/libSystem.B.dylib');
    malloc = system.lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.Size),
        ffi.Pointer<ffi.Void> Function(int)>('malloc');
    free = system.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
        void Function(ffi.Pointer<ffi.Void>)>('free');
  }
  late final int Function(
      ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Pointer<_Decoder>>) open;
  late final int Function(ffi.Pointer<_Decoder>) rate,
      channels,
      frames,
      preSkip;
  late final int Function(ffi.Pointer<_Decoder>, int, int,
      ffi.Pointer<ffi.Float>, int, ffi.Pointer<ffi.Uint32>) read;
  late final void Function(ffi.Pointer<_Decoder>) destroy;
  late final ffi.NativeFinalizer finalizer;
  late final ffi.Pointer<ffi.Void> Function(int) malloc;
  late final void Function(ffi.Pointer<ffi.Void>) free;

  ffi.Pointer<T> allocate<T extends ffi.NativeType>(int bytes) {
    final pointer = malloc(bytes);
    if (pointer == ffi.nullptr) {
      throw const NativeStemDecoderException('native allocation failed');
    }
    return pointer.cast<T>();
  }
}

// Native finalization is a last-resort isolate-GROUP shutdown safeguard, not an
// isolate-exit fence. Normal close detaches before deterministic destroy.
final class _OwnedDecoder implements ffi.Finalizable {
  _OwnedDecoder(this.api, this.pointer) {
    api.finalizer.attach(this, pointer.cast(), detach: this);
  }
  final _DecoderApi api;
  final ffi.Pointer<_Decoder> pointer;
  void close() {
    api.finalizer.detach(this);
    api.destroy(pointer);
  }
}

Future<void> _decodeWorker(List<Object> arguments) async {
  final reply = arguments[0] as SendPort;
  final commands = ReceivePort();
  reply.send(['port', commands.sendPort]);
  _DecoderApi? api;
  final decoders = <String, _OwnedDecoder>{};
  ffi.Pointer<ffi.Float> scratch = ffi.nullptr;
  ffi.Pointer<ffi.Uint32> readCount = ffi.nullptr;
  try {
    api = _DecoderApi(arguments[1] as String);
    final metadata = <List<Object>>[];
    for (final row in arguments[2] as List) {
      final pathBytes = utf8.encode(row[1] as String);
      final path = api.allocate<ffi.Char>(pathBytes.length + 1);
      ffi.Pointer<ffi.Pointer<_Decoder>> out = ffi.nullptr;
      try {
        out = api.allocate<ffi.Pointer<_Decoder>>(
            ffi.sizeOf<ffi.Pointer<_Decoder>>());
        path.cast<ffi.Uint8>().asTypedList(pathBytes.length + 1)
          ..setRange(0, pathBytes.length, pathBytes)
          ..[pathBytes.length] = 0;
        out.value = ffi.nullptr;
        final status = api.open(path, row[2] as int, out);
        if (status != 0) {
          throw NativeStemDecoderException(
              'open ${row[0]}: native status $status');
        }
        final decoder = _OwnedDecoder(api, out.value);
        decoders[row[0] as String] = decoder;
        final p = decoder.pointer;
        final frames = api.frames(p),
            rate = api.rate(p),
            channels = api.channels(p),
            skip = api.preSkip(p);
        if (frames != row[3] ||
            rate != row[4] ||
            channels != row[5] ||
            skip != row[6]) {
          throw NativeStemDecoderException('PCM metadata mismatch: ${row[0]}');
        }
        metadata.add([row[0] as String, frames, rate, channels, skip]);
      } finally {
        api.free(path.cast());
        if (out != ffi.nullptr) api.free(out.cast());
      }
    }
    final roles = (arguments[3] as List).cast<String>();
    final maxFrames = arguments[4] as int;
    scratch = api.allocate<ffi.Float>(maxFrames * 8);
    readCount = api.allocate<ffi.Uint32>(ffi.sizeOf<ffi.Uint32>());
    reply.send(['ready', metadata]);
    await for (final message in commands) {
      final command = message as List;
      if (command[0] == 'close') break;
      if (command[0] != 'read') {
        throw StateError('invalid decoder worker command');
      }
      try {
        final start = command[2] as int, requested = command[3] as int;
        final total = metadata.first[1] as int;
        final count = requested < total - start ? requested : total - start;
        final pcm = Float32List(count * 2 * roles.length);
        for (var i = 0; i < roles.length; i++) {
          final status = api.read(decoders[roles[i]]!.pointer, start, requested,
              scratch, maxFrames * 8, readCount);
          if (status != 0 || readCount.value != count) {
            throw NativeStemDecoderException(
                'read ${roles[i]}: native status $status, unaligned count');
          }
          pcm.setRange(i * count * 2, (i + 1) * count * 2,
              scratch.asTypedList(count * 2));
        }
        reply.send([
          'window',
          command[1],
          count,
          TransferableTypedData.fromList([pcm])
        ]);
      } catch (error) {
        reply.send(['readError', command[1], error.toString()]);
      }
    }
  } catch (error) {
    reply.send(['openError', error.toString()]);
  } finally {
    for (final decoder in decoders.values) {
      decoder.close();
    }
    if (scratch != ffi.nullptr) api!.free(scratch.cast());
    if (readCount != ffi.nullptr) api!.free(readCount.cast());
    commands.close();
    reply.send(['closed']);
  }
}
