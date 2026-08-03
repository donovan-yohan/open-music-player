import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_state.dart';
import '../../core/audio/signed_audio_url_service.dart';
import '../../core/api/api_client.dart';
import '../../core/cache/playback_cache_manager.dart';
import '../../core/download/download_service.dart';
import '../../core/engine/engine_audio_source_resolver.dart';
import '../../core/services/api_client.dart' as services;
import '../../core/services/stems_service.dart';
import '../../providers/queue_provider.dart';
import '../stems/track_stem_channel_source.dart';
import 'dj_layout.dart';
import 'engine/deck_controller.dart';
import 'providers/dj_session_provider.dart';

/// Spike-only direct-Voice performance view.
///
/// TODO(dj-production): replace [DjSessionProvider] direct voices with the
/// QueueTimelineController projection required by ADR 0001.
class DjScreen extends StatefulWidget {
  const DjScreen({super.key, this.session, this.filePicker});
  final DjSessionProvider? session;
  final DjFilePicker? filePicker;

  @override
  State<DjScreen> createState() => _DjScreenState();
}

class _DjScreenState extends State<DjScreen> {
  DjSessionProvider? _session;
  TrackStemChannelSource? _stems;
  bool _ownsSession = false;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session ??= widget.session ?? _newPrototypeSession();
    _ownsSession = widget.session == null;
    if (_seeded) return;
    _seeded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Direct prototype voices share the app audio session; park its canonical
      // session before they are loaded.
      try {
        await context.read<PlaybackState>().pause();
      } on ProviderNotFoundException {
        // Focused widget tests may intentionally mount the view without app
        // playback. Production always supplies PlaybackState.
      }
      if (!mounted) return;
      final queue = context.read<QueueProvider?>();
      final rawCurrent = queue?.currentTrack;
      final rawNext =
          queue?.upNext.isEmpty ?? true ? null : queue!.upNext.first;
      // Register both visible lanes with QueueProvider's bounded hydration
      // path before passing their rich analysis snapshots to the session.
      final current = rawCurrent == null || queue == null
          ? rawCurrent
          : queue.trackWithAnalysis(rawCurrent);
      final next = rawNext == null || queue == null
          ? rawNext
          : queue.trackWithAnalysis(rawNext);
      await _session!.seed(
        current: current,
        next: next,
        filePicker: widget.filePicker ?? _promptForLocalFile,
      );
      // Resolve stem availability for whatever actually landed on deck A. A
      // local-file fallback load has no library track id, so the panel says so
      // rather than offering a separation that cannot be queued.
      await _stems?.bindTrack(_libraryTrackId(_session!.deckA.trackRef));
    });
  }

  /// Deck refs are `playbackTrackId ?? queueItemId` for library tracks and
  /// `local:<path>` for the picker fallback; only the former can be separated.
  static int? _libraryTrackId(String? trackRef) {
    if (trackRef == null) return null;
    final parsed = int.tryParse(trackRef.trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }

  DjSessionProvider _newPrototypeSession() {
    // The parser-based client is not in the provider tree (only the Dio one
    // is), so it is constructed here the same way main.dart does for
    // LibraryService. Its default SecureStorage is the shared token authority,
    // so this is not a second session.
    _stems = TrackStemChannelSource(service: StemsService(services.ApiClient()));
    return DjSessionProvider.prototype(
      resolver: DefaultEngineAudioSourceResolver(
        signedAudioUrlService: SignedAudioUrlService(context.read<ApiClient>()),
        localResolver: context.read<DownloadService>(),
        cacheManager: context.read<PlaybackCacheManager?>(),
      ),
      stems: _stems,
    );
  }

  /// Dependency-free local source fallback for an empty queue. A user supplies
  /// an absolute device path; DeckController accepts only the resulting file:
  /// URI and refuses remote schemes.
  Future<DjDeckLoad?> _promptForLocalFile() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Load local audio file'),
        content: TextField(
          key: const ValueKey('dj_local_file_path'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/Music/track.mp3',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Load'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    return DjDeckLoad(
      trackRef: 'local:$trimmed',
      title: slash < 0 ? trimmed : trimmed.substring(slash + 1),
      localUri: Uri.file(trimmed),
    );
  }

  @override
  void dispose() {
    _stems?.dispose();
    if (_ownsSession) {
      // DeckController.dispose releases its Voice; do not overlap it with a
      // second release from stopAll.
      _session?.dispose();
    } else {
      // The injected session remains caller-owned, but an exited screen must
      // still park its prototype voices.
      unawaited(_session?.stopAll() ?? Future<void>.value());
    }
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ChangeNotifierProvider<DjSessionProvider>.value(
        value: _session!,
        child: const Scaffold(
          key: ValueKey('dj_screen'),
          body: DjLayout(),
        ),
      );
}
