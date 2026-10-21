// Executable macOS profile workload, NOT a flutter_test wall-clock FPS test.
// Build/run via scripts/profile-desktop-scroll. Never initializes audio/auth.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:just_audio/just_audio.dart' show LoopMode, ProcessingState;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:open_music_player/features/desktop/desktop_transport.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/shared/models/track.dart';

const _width = int.fromEnvironment('SOUNDQ_PROFILE_WIDTH', defaultValue: 1440);
const _height = int.fromEnvironment('SOUNDQ_PROFILE_HEIGHT', defaultValue: 900);
const _runCount = 5;
const _leg = Duration(seconds: 4);
const _distance = 6000.0;
final _boundary = GlobalKey();
final _scroll = ScrollController();
final _rawFrames = <Map<String, int>>[];
final _windows = <Map<String, dynamic>>[];
final _errors = <String>[];
final _rowIds = <int>{};
int _rowBuilds = 0;
int _networkAttempts = 0;
int _apiAttempts = 0;
int _actionAttempts = 0;

Future<void> main() async {
  if (!Platform.isMacOS || !kProfileMode) {
    stderr.writeln('Requires native macOS --profile (not debug/release/test).');
    exit(64);
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    _errors.add(details.toString());
    FlutterError.presentError(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    _errors.add('$error\n$stack');
    stderr.writeln('$error\n$stack');
    return true;
  };
  HttpOverrides.global = _DenyNetwork();
  final playback = _FixturePlayback();
  final downloads = _FixtureDownloads();
  final api = _NoApi();
  final library = LibraryService(api);
  final liked = LikedTracksState(library);
  final commands = CommandRegistry(playbackState: playback);
  final tracks = List.generate(
      10000,
      (i) => Track(
          id: i + 1,
          identityHash: 'controlled-profile-fixture-${i + 1}',
          title: '${_titles[i % _titles.length]} · ${i + 1}',
          artist: _artists[i % _artists.length],
          durationMs: 180000 + (i % 90) * 1000,
          mbVerified: true,
          isLiked: i % 5 == 0,
          artworkKind: TrackArtworkKind.none,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026)));
  liked.seed(tracks);
  binding.addTimingsCallback((timings) {
    for (final t in timings) {
      _rawFrames.add({
        'frameNumber': t.frameNumber,
        for (final phase in ui.FramePhase.values)
          phase.name: t.timestampInMicroseconds(phase),
        'uiUs': t.buildDuration.inMicroseconds,
        'rasterUs': t.rasterDuration.inMicroseconds,
        'totalSpanUs': t.totalSpan.inMicroseconds,
        'vsyncOverheadUs': t.vsyncOverhead.inMicroseconds,
      });
    }
  });
  runApp(MultiProvider(
    providers: [
      ListenableProvider<PlaybackState>.value(value: playback),
      ListenableProvider<DownloadState>.value(value: downloads),
      ChangeNotifierProvider<LikedTracksState>.value(value: liked),
      Provider<CommandRegistry>.value(value: commands),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: RepaintBoundary(
        key: _boundary,
        child: DesktopListeningShell(
          compact: false,
          selectedIndex: 2,
          onDestinationSelected: (_) => _actionAttempts++,
          miniPlayer: const DesktopTransport(),
          child: Material(
              child: Column(children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Library · controlled profile fixture',
                          style: TextStyle(fontSize: 24)),
                      SizedBox(height: 8),
                      Text(
                          '10,000 production rows · simulated position ticks · no audio / network'),
                    ],
                  )),
            ),
            Expanded(
                child: ListView.builder(
              controller: _scroll,
              itemCount: tracks.length,
              scrollCacheExtent: const ScrollCacheExtent.pixels(200),
              itemBuilder: (context, index) {
                _rowBuilds++;
                _rowIds.add(index + 1);
                return LibraryTrackListTile(
                  key: ValueKey(tracks[index].id),
                  track: tracks[index],
                  libraryService: library,
                  detailApiClient: api,
                  onPlay: () => _actionAttempts++,
                );
              },
            )),
          ])),
        ),
      ),
    ),
  ));
  Timer? ticker;
  Directory? output;
  try {
    await Future<void>.delayed(const Duration(seconds: 2));
    _resizeNativeWindow(_width.toDouble(), _height.toDouble());
    await Future<void>.delayed(const Duration(seconds: 2));
    final view = ui.PlatformDispatcher.instance.views.single;
    final logical = view.physicalSize / view.devicePixelRatio;
    if ((logical.width - _width).abs() > 1 ||
        (logical.height - _height).abs() > 1) {
      throw StateError(
          'Native content viewport ${logical.width} × ${logical.height} '
          '(physical ${view.physicalSize.width} × ${view.physicalSize.height}, '
          'DPR ${view.devicePixelRatio}) != $_width × $_height; '
          'AppKit may constrain the window to the current display');
    }
    final cache = await getApplicationCacheDirectory();
    final id = Platform.environment['SOUNDQ_PROFILE_RUN_ID'] ??
        DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    output = await Directory('${cache.path}/soundq-scroll-profile-$id')
        .create(recursive: true);
    print('SOUNDQ_PROFILE_OUTPUT=${output.path}');
    ticker = Timer.periodic(
        const Duration(milliseconds: 150), (_) => playback.tick());
    await _traversal('warmup', playback, downloads);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final initialRows = _rowBuilds;
    final initialChecks = downloads.checks;
    final initialTicks = playback.ticks;
    // Position-only stationary control, outside timing samples.
    await Future<void>.delayed(const Duration(seconds: 2));
    final stationary = {
      'ticks': playback.ticks - initialTicks,
      'rowBuilderCalls': _rowBuilds - initialRows,
      'downloadChecks': downloads.checks - initialChecks,
    };
    // Raster-only capture of our own Flutter fixture, never the desktop.
    await binding.endOfFrame;
    final repaint =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await repaint.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('${output.path}/fixture.png')
        .writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    for (var run = 1; run <= _runCount; run++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _traversal('run-$run', playback, downloads);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final samples = [
      for (final w in _windows)
        if (w['name'] != 'warmup') _summarizeWindow(w),
    ];
    final measured = _rawFrames
        .where((f) => _windows.any((w) =>
            w['name'] != 'warmup' &&
            f['vsyncStart']! >= (w['startVsyncUs'] as int) &&
            f['vsyncStart']! <= (w['endVsyncUs'] as int)))
        .toList();
    final result = {
      'schema': 1,
      'label':
          'Controlled fixture, not authenticated library or sustained audio',
      'buildMode': 'profile',
      'platform': Platform.operatingSystemVersion,
      'dart': Platform.version,
      'viewportLogical': [logical.width, logical.height],
      'viewportPhysical': [view.physicalSize.width, view.physicalSize.height],
      'devicePixelRatio': view.devicePixelRatio,
      'displayRefreshRateReportedHz': view.display.refreshRate,
      'thresholdPolicy':
          'Fixed 8333us / 16667us; no assertion about actual display refresh',
      'measurement':
          'Native engine FrameTiming; nearest-rank percentiles; no wall-time FPS',
      'workload': {
        'rows': 10000,
        'widget':
            'LibraryTrackListTile > NowPlayingRow > SongListItem, unchanged production source',
        'shell': 'DesktopListeningShell + DesktopTransport, AppTheme.darkTheme',
        'scroll':
            'ScrollController.animateTo linear: 0 to 6000 logical px in 4s, back in 4s',
        'inputQualification':
            'Repeatable framework scroll animation, not physical trackpad gesture/momentum',
        'cacheExtentPx': 200,
        'fixedItemExtent': false,
        'warmupTraversals': 1,
        'measuredTraversals': _runCount,
        'positionTickPeriodMs': 150,
        'positionPort':
            'Fixture ChangeNotifier implementing PlaybackState with coherent immutable snapshot/cue',
        'artwork':
            'Production TrackArtwork none-placeholder; no image fetch/decode workload',
        'analysis': 'Absent; metadata chips not exercised',
        'downloadPort':
            'In-memory completed Future<bool>(false), no database/filesystem',
        'exclusions': [
          'audio runtime/OS output',
          'auth',
          'network/backend',
          'library paging/filtering',
          'physical input',
          'remote artwork decode'
        ],
      },
      'stationaryPositionControl': stationary,
      'runs': samples,
      'aggregate': _distribution(measured),
      'counters': {
        'rowBuilderCallsIncludingWarmup': _rowBuilds,
        'uniqueRowIds': _rowIds.toList()..sort(),
        'downloadChecks': downloads.checks,
        'downloadProgressReads': downloads.progressReads,
        'positionNotifications': playback.ticks,
        'snapshotReads': playback.snapshotReads,
        'apiAttempts': _apiAttempts,
        'httpClientAttempts': _networkAttempts,
        'actionAttempts': _actionAttempts,
        'audioPlayersCreated': 0,
      },
      'errors': _errors,
      'windows': _windows,
      'rawFrames': _rawFrames,
    };
    await File('${output.path}/timings.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    if (samples.length != _runCount ||
        measured.isEmpty ||
        _errors.isNotEmpty ||
        _apiAttempts != 0 ||
        _networkAttempts != 0 ||
        _actionAttempts != 0 ||
        stationary['rowBuilderCalls'] != 0 ||
        stationary['downloadChecks'] != 0) {
      throw StateError('Profile validation failed; inspect timings.json');
    }
    print('SOUNDQ_PROFILE_COMPLETE=${output.path}/timings.json');
    print('SOUNDQ_PROFILE_SUMMARY=${jsonEncode(result['aggregate'])}');
    ticker.cancel();
    exit(0);
  } catch (error, stack) {
    ticker?.cancel();
    stderr.writeln('SOUNDQ_PROFILE_FAILED=$error\n$stack');
    if (output != null) {
      await File('${output.path}/failure.json').writeAsString(jsonEncode({
        'error': '$error',
        'stack': '$stack',
        'errors': _errors,
        'windows': _windows,
        'rawFrames': _rawFrames,
      }));
    }
    exit(1);
  }
}

Future<void> _traversal(
    String name, _FixturePlayback playback, _FixtureDownloads downloads) async {
  if (_scroll.offset != 0) {
    throw StateError('Each traversal must begin at zero');
  }
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame;
  final start =
      SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
  final rows = _rowBuilds;
  final checks = downloads.checks;
  final ticks = playback.ticks;
  final reads = playback.snapshotReads;
  await _scroll.animateTo(_distance, duration: _leg, curve: Curves.linear);
  final reached = _scroll.offset;
  await _scroll.animateTo(0, duration: _leg, curve: Curves.linear);
  _windows.add({
    'name': name,
    'startVsyncUs': start,
    'endVsyncUs':
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds,
    'reachedOffsetPx': reached,
    'finalOffsetPx': _scroll.offset,
    'rowBuilderCalls': _rowBuilds - rows,
    'downloadChecks': downloads.checks - checks,
    'positionNotifications': playback.ticks - ticks,
    'snapshotReads': playback.snapshotReads - reads,
    'mountedRowsAtEnd': _countRows(),
  });
  print('SOUNDQ_PROFILE_WINDOW=${jsonEncode(_windows.last)}');
}

int _countRows() {
  var count = 0;
  void visit(Element element) {
    if (element.widget is LibraryTrackListTile) count++;
    element.visitChildren(visit);
  }

  _boundary.currentContext!.visitChildElements(visit);
  return count;
}

Map<String, dynamic> _summarizeWindow(Map<String, dynamic> window) => {
      ...window,
      ..._distribution(_rawFrames
          .where((f) =>
              f['vsyncStart']! >= (window['startVsyncUs'] as int) &&
              f['vsyncStart']! <= (window['endVsyncUs'] as int))
          .toList()),
    };

Map<String, dynamic> _distribution(List<Map<String, int>> frames) => {
      'frames': frames.length,
      for (final metric in [
        'uiUs',
        'rasterUs',
        'totalSpanUs',
        'vsyncOverheadUs'
      ])
        metric: _stats(frames.map((f) => f[metric]!).toList()),
      for (final limit in [8333, 16667])
        'eitherUiOrRasterOver${limit}Us': frames
            .where((f) => f['uiUs']! > limit || f['rasterUs']! > limit)
            .length,
    };

Map<String, num> _stats(List<int> values) {
  values.sort();
  int quantile(double q) =>
      values.isEmpty ? 0 : values[math.max(0, (values.length * q).ceil() - 1)];
  return {
    'p50': quantile(.50),
    'p95': quantile(.95),
    'p99': quantile(.99),
    'max': values.isEmpty ? 0 : values.last,
    'over8333Us': values.where((v) => v > 8333).length,
    'over16667Us': values.where((v) => v > 16667).length,
  };
}

const _titles = [
  'Midnight City',
  'Open Eye Signal',
  'Kerala',
  'Two Thousand and Seventeen',
  'A Walk',
  'Cirrus'
];
const _artists = [
  'M83',
  'Jon Hopkins',
  'Bonobo',
  'Four Tet',
  'Tycho',
  'Bonobo'
];

class _FixturePlayback extends ChangeNotifier implements PlaybackState {
  int ticks = 0;
  int snapshotReads = 0;
  Duration cursor = const Duration(seconds: 30);
  final item = const MediaItem(
      id: '1',
      title: 'Midnight City · 1',
      artist: 'M83',
      duration: Duration(minutes: 3));
  late final cue = PlaybackCue(
    cueId: 'profile-cue-1',
    queueItemId: 'profile-occurrence-1',
    queueIndex: 0,
    trackId: '1',
    mediaItem: item,
    audioUri: Uri.parse('file:///never-opened-profile-fixture.wav'),
    sourceDuration: duration,
    sourceStart: Duration.zero,
    sourceEnd: duration,
    timelineStart: Duration.zero,
  );
  @override
  PlaybackSnapshot get snapshot {
    snapshotReads++;
    return PlaybackSnapshot(
      sessionId: 'controlled-profile-fixture',
      cues: [cue],
      currentCueId: cue.cueId,
      currentQueueIndex: 0,
      currentMediaItem: item,
      localPosition: cursor,
      localDuration: duration,
      globalPosition: cursor,
      globalDuration: duration,
      playing: true,
      processingState: ProcessingState.ready,
      activeVoiceCount: 1,
    );
  }

  void tick() {
    ticks++;
    cursor += const Duration(milliseconds: 150);
    notifyListeners();
  }

  @override
  bool get hasTrack => true;
  @override
  bool get isPlaying => true;
  @override
  bool get isResolvingSignedUrl => false;
  @override
  Duration get position => cursor;
  @override
  Duration get duration => const Duration(minutes: 3);
  @override
  List<MediaItem> get queue => [item];
  @override
  int get currentIndex => 0;
  @override
  bool get canSkipNext => false;
  @override
  bool get hasPreviousInPlayOrder => false;
  @override
  bool get shuffleEnabled => false;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    _actionAttempts++;
    throw StateError('Unstubbed playback ${invocation.memberName}');
  }
}

class _FixtureDownloads extends ChangeNotifier implements DownloadState {
  int checks = 0;
  int progressReads = 0;
  @override
  Future<bool> isDownloaded(int trackId) async {
    checks++;
    return false;
  }

  @override
  DownloadProgress? getProgress(int trackId) {
    progressReads++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _actionAttempts++;
    throw StateError('Unstubbed download ${invocation.memberName}');
  }
}

class _NoApi implements ApiClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    _apiAttempts++;
    throw StateError('Network API forbidden: ${invocation.memberName}');
  }
}

class _DenyNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    _networkAttempts++;
    throw StateError('HTTP forbidden in controlled profile');
  }
}

// Minimal Cocoa window sizing from the merged UI/platform thread. No runner or
// production-source edits, accessibility permission or desktop capture needed.
final class _NativeSize extends ffi.Struct {
  @ffi.Double()
  external double width;
  @ffi.Double()
  external double height;
}

void _resizeNativeWindow(double width, double height) {
  final objc = ffi.DynamicLibrary.process();
  final selector = objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>),
      ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Char>)>('sel_registerName');
  final getClass = objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Char>)>('objc_getClass');
  final malloc = objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.UintPtr),
      ffi.Pointer<ffi.Void> Function(int)>('malloc');
  final free = objc.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Void>),
      void Function(ffi.Pointer<ffi.Void>)>('free');
  ffi.Pointer<ffi.Void> name(String text, bool isClass) {
    final p = malloc(text.length + 1).cast<ffi.Char>();
    final bytes = p.cast<ffi.Uint8>().asTypedList(text.length + 1);
    bytes.setAll(0, utf8.encode(text));
    bytes[text.length] = 0;
    final result = isClass ? getClass(p) : selector(p);
    free(p.cast());
    return result;
  }

  final send = objc.lookupFunction<
      ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
      ffi.Pointer<ffi.Void> Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>('objc_msgSend');
  final sendBool = objc.lookupFunction<
      ffi.Int8 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>),
      int Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>('objc_msgSend');
  if (sendBool(name('NSThread', true), name('isMainThread', false)) == 0) {
    throw StateError('Cocoa sizing requires Flutter merged UI/platform thread');
  }
  final app =
      send(name('NSApplication', true), name('sharedApplication', false));
  final windows = send(app, name('windows', false));
  final window = send(windows, name('firstObject', false));
  if (window == ffi.nullptr) throw StateError('No native profile window');
  final ptr = malloc(ffi.sizeOf<_NativeSize>()).cast<_NativeSize>();
  ptr.ref.width = width;
  ptr.ref.height = height;
  final setSize = objc.lookupFunction<
      ffi.Void Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, _NativeSize),
      void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
          _NativeSize)>('objc_msgSend');
  setSize(window, name('setContentSize:', false), ptr.ref);
  free(ptr.cast());
  send(window, name('center', false));
  send(window, name('orderFrontRegardless', false));
  final activate = objc.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.Int8),
      void Function(
          ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, int)>('objc_msgSend');
  activate(app, name('activateIgnoringOtherApps:', false), 1);
}
