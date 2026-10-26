// Executable profile journey. Calls the production entrypoint; no test binding,
// replacement widget root, fake backend, fake audio or synthetic position ticks.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:open_music_player/main.dart' as production;
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/performance/fixture_tokens.dart';
import 'package:open_music_player/core/performance/performance_fixture_io.dart';
import 'package:open_music_player/core/performance/profile_scroll_leg.dart';
import 'package:open_music_player/features/library/library_screen.dart';

final _frames = <Map<String, int>>[];
final _windows = <Map<String, Object?>>[];
final _seenRows = <int>{};
final _legs = <Map<String, Object>>[];
int _errorCount = 0;

Future<void> main() async {
  // Preflight occurs inside production.main before binding/preferences/storage.
  if (!performanceFixtureEnabled) throw StateError('fixture-opt-in-required');
  final previousError = FlutterError.onError;
  final previousPlatformError = ui.PlatformDispatcher.instance.onError;
  FlutterError.onError = (details) {
    _errorCount++;
    previousError?.call(details);
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    _errorCount++;
    return previousPlatformError?.call(error, stack) ?? false;
  };
  void timings(List<ui.FrameTiming> batch) {
    for (final t in batch) {
      if (_frames.length >= 100000) {
        _errorCount++;
        continue;
      }
      _frames.add({
        'frameNumber': t.frameNumber,
        for (final phase in ui.FramePhase.values)
          phase.name: t.timestampInMicroseconds(phase),
        'uiUs': t.buildDuration.inMicroseconds,
        'rasterUs': t.rasterDuration.inMicroseconds,
        'totalSpanUs': t.totalSpan.inMicroseconds,
        'vsyncOverheadUs': t.vsyncOverhead.inMicroseconds,
      });
    }
  }

  WidgetsBinding? binding;
  PerformanceFixture? fixture;
  var status = 'failed';
  var failure = 'journey-incomplete';
  var loadedRows = 0;
  try {
    await production.main();
    fixture = PerformanceFixture.active;
    if (fixture == null) throw StateError('fixture-preflight-required');
    binding = WidgetsBinding.instance;
    binding.addTimingsCallback(timings);
    if (_errorCount != 0) throw StateError('fixture-startup-error');
    final app = await _waitFor<OpenMusicPlayerApp>();
    if (!app.authState.isAuthenticated) throw StateError('fixture-auth-failed');
    // Uses the mounted production router and its ordinary LibraryScreen.
    app.router.go('/library');
    await _waitFor<LibraryTrackListTile>();
    ListView? list;
    // Warm the production pagination path, never inject rows or bypass its API.
    final populationClock = Stopwatch()..start();
    while (populationClock.elapsed < const Duration(seconds: 45)) {
      list = _libraryList();
      loadedRows = list?.childrenDelegate.estimatedChildCount ?? 0;
      _observeRows();
      if (loadedRows >= 500) break;
      final controller = list?.controller;
      if (controller != null && controller.hasClients) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (list == null || loadedRows < 500) {
      throw StateError('fixture-population-incomplete');
    }
    final scroll = list.controller!;
    scroll.jumpTo(0);
    await Future<void>.delayed(const Duration(seconds: 1));
    if (app.playbackState.isPlaying) throw StateError('fixture-idle-required');
    void requireIdle() {
      if (app.playbackState.isPlaying) _errorCount++;
    }

    app.playbackState.addListener(requireIdle);
    try {
      await _window('populated-idle', scroll, () async {
        await Future<void>.delayed(const Duration(milliseconds: 3200));
      });
      await _window('populated-scroll-audio-unavailable', scroll, () async {
        for (var leg = 0; leg < 4; leg++) {
          final target = leg.isEven ? scroll.position.maxScrollExtent : 0.0;
          final clock = Stopwatch()..start();
          await scroll.animateTo(
            target,
            duration: const Duration(seconds: 2),
            curve: Curves.linear,
          );
          final observation = ProfileScrollLeg(
            target: target,
            offset: scroll.offset,
            elapsedUs: clock.elapsedMicroseconds,
            requestedUs: const Duration(seconds: 2).inMicroseconds,
          );
          _legs.add(observation.toJson());
          observation.requireComplete();
          _observeRows();
        }
      });
    } finally {
      app.playbackState.removeListener(requireIdle);
    }
    if (_errorCount != 0) throw StateError('fixture-framework-error');
    status = 'completed-diagnostic';
    failure = 'audio-native-readback-unavailable';
  } catch (_) {
    // Fixed code only: backend exceptions may contain account or bearer URLs.
    stderr.writeln('soundq-fixture-journey-failed');
    failure = 'journey-failed';
  } finally {
    // Flutter may batch FrameTiming reports for ~1s in profile mode.
    fixture ??= PerformanceFixture.active;
    await Future<void>.delayed(const Duration(seconds: 2));
    binding?.removeTimingsCallback(timings);
    FlutterError.onError = previousError;
    ui.PlatformDispatcher.instance.onError = previousPlatformError;
    for (final window in _windows) {
      final start = window['start'] as int;
      final end = window['end'] as int;
      final count = _frames
          .where(
            (frame) =>
                frame['vsyncStart']! > start && frame['vsyncStart']! <= end,
          )
          .length;
      window['frame_count'] = count;
      if (end <= start || count == 0) {
        status = 'failed';
        failure = 'renderer-population-unavailable';
      }
    }
    if (_errorCount != 0) {
      status = 'failed';
      failure = 'fixture-framework-error';
    }
    if (fixture != null) {
      final view = ui.PlatformDispatcher.instance.views.first;
      final report = {
        'schema': 'soundq.flutter.actual-root.profile.v1',
        ...fixture.provenance,
        'pid': pid,
        'build_mode': 'profile',
        'entrypoint': 'production.main',
        'route': '/library',
        'status': status,
        'hold': failure,
        'preferences': 'ephemeral-plugin-adapter',
        'storage': 'EPHEMERAL STORAGE',
        'artwork': 'placeholder-only-memory-cache',
        'excluded_operations': [
          'disk',
          'downloads',
          'playback-cache',
          'artwork-acquisition',
          'audio',
        ],
        'audio': 'unavailable-native-readback-not-proven',
        'full_app_accepted': false,
        'framework_error_count': _errorCount,
        'loaded_list_slots': loadedRows,
        'witnessed_row_ids': _seenRows.toList()..sort(),
        'physical_viewport': [
          view.physicalSize.width,
          view.physicalSize.height,
        ],
        'scale': view.devicePixelRatio,
        'clock': 'flutter-frame-timing',
        'boundary_clock': 'SchedulerBinding.currentSystemFrameTimeStamp',
        'boundary_frames_requested': true,
        'windows': _windows,
        'scroll_legs': _legs,
        'rawFrames': _frames,
      };
      await fixture.exportReport(report);
    }
    // Runtime owner owns shutdown and OS cleanup. Never exit/kill/replace apps.
  }
}

Iterable<Element> _elements() sync* {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return;
  final pending = <Element>[root];
  while (pending.isNotEmpty) {
    final element = pending.removeLast();
    yield element;
    element.visitChildren(pending.add);
  }
}

Future<T> _waitFor<T extends Widget>() async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 20)) {
    for (final element in _elements()) {
      if (element.widget is T) return element.widget as T;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('fixture-mounted-widget-timeout');
}

ListView? _libraryList() {
  for (final element in _elements()) {
    if (element.widget is! ListView) continue;
    var inLibrary = false;
    element.visitAncestorElements((ancestor) {
      if (ancestor.widget is LibraryScreen) {
        inLibrary = true;
        return false;
      }
      return true;
    });
    final list = element.widget as ListView;
    if (inLibrary && list.controller?.hasClients == true) return list;
  }
  return null;
}

void _observeRows() {
  for (final element in _elements()) {
    final widget = element.widget;
    if (widget is LibraryTrackListTile) _seenRows.add(widget.track.id);
  }
}

Future<int> _boundary() async {
  final binding = SchedulerBinding.instance;
  final completed = Completer<int>();
  binding.addPostFrameCallback((_) {
    completed.complete(binding.currentSystemFrameTimeStamp.inMicroseconds);
  });
  binding.scheduleFrame();
  return completed.future.timeout(const Duration(seconds: 5));
}

Future<void> _window(
  String name,
  ScrollController scroll,
  Future<void> Function() action,
) async {
  final before = scroll.offset;
  var lastOffset = before;
  var distance = 0.0;
  void moved() {
    final offset = scroll.offset;
    distance += (offset - lastOffset).abs();
    lastOffset = offset;
  }

  final start = await _boundary();
  scroll.addListener(moved);
  try {
    await action();
  } finally {
    scroll.removeListener(moved);
  }
  final end = await _boundary();
  if (name.contains('scroll') && distance <= 0) {
    throw StateError('fixture-scroll-unavailable');
  }
  _windows.add({
    'name': name,
    'clock': 'flutter-frame-timing',
    'start': start,
    'end': end,
    'audio_active': false,
    'cursor': null,
    'scroll_start': before,
    'scroll_end': scroll.offset,
    'scroll_max_extent': scroll.position.maxScrollExtent,
    'scroll_distance': distance,
    'motion': name.contains('scroll'),
  });
}
