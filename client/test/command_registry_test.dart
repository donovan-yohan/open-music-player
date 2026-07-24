import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'package:open_music_player/core/commands/app_command.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/commands/command_shortcuts.dart';
import 'package:open_music_player/core/commands/command_widgets.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';

void main() {
  testWidgets(
    'derived availability notifies its first disabled to enabled transition',
    (tester) async {
      final source = ChangeNotifier();
      var enabled = false;
      final availability = DerivedCommandAvailability(
        source: source,
        derive: () => enabled
            ? const CommandAvailability.enabled()
            : const CommandAvailability.disabled('Unavailable'),
      );
      addTearDown(availability.dispose);
      addTearDown(source.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<CommandAvailability>(
            valueListenable: availability,
            builder: (_, value, __) => Text(
              value.enabled ? 'Enabled' : value.disabledReason!,
            ),
          ),
        ),
      );
      expect(find.text('Unavailable'), findsOneWidget);

      enabled = true;
      source.notifyListeners();
      await tester.pump();

      expect(find.text('Enabled'), findsOneWidget);
    },
  );

  test('every command exposes availability derived from playback changes', () {
    final playback = _PlaybackState();
    final registry = CommandRegistry(
      playbackState: playback,
      platform: TargetPlatform.linux,
    );
    addTearDown(registry.dispose);
    addTearDown(playback.disposeFake);

    for (final command in registry.commands) {
      expect(command.availability.value, isA<CommandAvailability>());
    }

    expect(registry[CommandId.next].availability.value.enabled, isFalse);
    expect(
      registry[CommandId.next].availability.value.disabledReason,
      'Nothing is queued',
    );
    expect(registry[CommandId.previous].availability.value.enabled, isFalse);

    playback
      ..fakeQueue = const [
        MediaItem(
          id: '1',
          title: 'One',
          duration: Duration(minutes: 3),
        ),
      ]
      ..fakeCurrentIndex = 0
      ..fakeDuration = const Duration(minutes: 3)
      ..emit();

    expect(registry[CommandId.next].availability.value.enabled, isFalse);
    expect(
      registry[CommandId.next].availability.value.disabledReason,
      'Already at the end of the queue',
    );

    playback
      ..fakeLoopMode = LoopMode.all
      ..emit();
    expect(registry[CommandId.next].availability.value.enabled, isTrue);
    expect(registry[CommandId.previous].availability.value.enabled, isFalse);
    expect(registry[CommandId.seekForward].availability.value.enabled, isTrue);

    playback
      ..fakeLoopMode = LoopMode.off
      ..fakeCurrentIndex = 0
      ..fakeCanSkipNext = true
      ..fakeHasPreviousInPlayOrder = false
      ..emit();
    expect(registry[CommandId.next].availability.value.enabled, isTrue);
    expect(registry[CommandId.previous].availability.value.enabled, isFalse);

    playback
      ..fakeHasPreviousInPlayOrder = true
      ..emit();
    expect(registry[CommandId.previous].availability.value.enabled, isTrue);
  });

  testWidgets(
    'Space is transport except while typing and disabled transport consumes it',
    (tester) async {
      final playback = _PlaybackState()
        ..fakeQueue = const [
          MediaItem(
            id: '1',
            title: 'One',
            duration: Duration(minutes: 3),
          ),
        ]
        ..fakeCurrentIndex = 0
        ..fakeDuration = const Duration(minutes: 3);
      final registry = CommandRegistry(
        playbackState: playback,
        platform: TargetPlatform.linux,
      );
      addTearDown(registry.dispose);
      addTearDown(playback.disposeFake);
      final listFocusNode = FocusNode();
      final buttonFocusNode = FocusNode();
      final textFocusNode = FocusNode();
      final textController = TextEditingController();
      addTearDown(listFocusNode.dispose);
      addTearDown(buttonFocusNode.dispose);
      addTearDown(textFocusNode.dispose);
      addTearDown(textController.dispose);
      var buttonCalls = 0;

      CommandContext contextFor(CommandId _) =>
          CommandContext(playbackState: playback);

      await tester.pumpWidget(
        MaterialApp(
          home: CommandHost(
            registry: registry,
            contextFor: contextFor,
            child: Scaffold(
              body: Column(
                children: [
                  ListTile(
                    focusNode: listFocusNode,
                    title: const Text('Command target'),
                  ),
                  ElevatedButton(
                    focusNode: buttonFocusNode,
                    onPressed: () => buttonCalls++,
                    child: const Text('Focused action'),
                  ),
                  TextField(
                    key: const ValueKey('command_text_field'),
                    focusNode: textFocusNode,
                    controller: textController,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      listFocusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playback.toggleCalls, 1);

      playback
        ..fakeQueue = const []
        ..fakeCurrentIndex = null
        ..emit();
      buttonFocusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playback.toggleCalls, 1);
      expect(buttonCalls, 0);

      textFocusNode.requestFocus();
      await tester.pump();
      final textFieldContext = tester.element(
        find.byKey(const ValueKey('command_text_field')),
      );
      const playPauseIntent = CommandIntent(
        CommandId.playPauseToggle,
      );
      final action = Actions.find<CommandIntent>(
        textFieldContext,
        intent: playPauseIntent,
      );
      expect(action.isEnabled(playPauseIntent), isFalse);
      expect(Actions.handler(textFieldContext, playPauseIntent), isNull);

      await tester.enterText(
        find.byKey(const ValueKey('command_text_field')),
        ' ',
      );
      expect(textController.text, ' ');
      expect(playback.toggleCalls, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(textFocusNode.hasFocus, isFalse);
    },
  );

  test('Apple platforms share Meta bindings and Cmd hints', () {
    final playback = _PlaybackState();
    final appleRegistry = CommandRegistry(
      playbackState: playback,
      platform: TargetPlatform.iOS,
    );
    final otherRegistry = CommandRegistry(
      playbackState: playback,
      platform: TargetPlatform.android,
    );
    addTearDown(appleRegistry.dispose);
    addTearDown(otherRegistry.dispose);
    addTearDown(playback.disposeFake);

    final apple = commandShortcutMap(TargetPlatform.iOS);
    final other = commandShortcutMap(TargetPlatform.android);
    final appleFocusSearch = apple.keys
        .whereType<SingleActivator>()
        .singleWhere(
            (activator) => activator.trigger == LogicalKeyboardKey.keyK);
    final otherFocusSearch = other.keys
        .whereType<SingleActivator>()
        .singleWhere(
            (activator) => activator.trigger == LogicalKeyboardKey.keyK);
    expect(appleFocusSearch.meta, isTrue);
    expect(appleFocusSearch.control, isFalse);
    expect(
      (apple[appleFocusSearch]! as CommandIntent).id,
      CommandId.focusSearch,
    );
    expect(otherFocusSearch.control, isTrue);
    expect(otherFocusSearch.meta, isFalse);
    expect(
      (other[otherFocusSearch]! as CommandIntent).id,
      CommandId.focusSearch,
    );
    expect(
      appleRegistry[CommandId.focusSearch].shortcutHint,
      'Cmd+K or /',
    );
    expect(
      otherRegistry[CommandId.focusSearch].shortcutHint,
      'Ctrl+K or /',
    );
    expect(
      (apple[const CharacterActivator('/')]! as CommandIntent).id,
      CommandId.focusSearch,
    );
    expect(
      (apple[const CharacterActivator('?')]! as CommandIntent).id,
      CommandId.showShortcutHelp,
    );
  });

  test('item commands preserve queue identity and liked authority', () async {
    final playback = _PlaybackState()
      ..fakeQueue = const [MediaItem(id: '42', title: 'Forty two')]
      ..fakeCurrentIndex = 0;
    final registry = CommandRegistry(playbackState: playback);
    final library = _LibraryService();
    final liked = LikedTracksState(library)..seedValue(42, false);
    addTearDown(registry.dispose);
    addTearDown(playback.disposeFake);
    addTearDown(liked.dispose);

    final context = CommandContext(
      playbackState: playback,
      likedTracksState: liked,
      queueItemId: 'session_7_item_3',
      trackId: 42,
      track: const {'id': 42, 'title': 'Forty two'},
    );

    await registry[CommandId.playNext].execute(context);
    await registry[CommandId.addToQueue].execute(context);
    await registry[CommandId.removeFromQueue].execute(context);
    await registry[CommandId.toggleLiked].execute(context);

    expect(playback.playNextTracks.single['id'], 42);
    expect(playback.enqueuedTracks.single['id'], 42);
    expect(playback.removedQueueItemIds, ['session_7_item_3']);
    expect(playback.positionalRemoveCalls, isEmpty);
    expect(library.likedTrackIds, [42]);
    expect(liked.isLiked(42), isTrue);

    var delegatedQueueCalls = 0;
    var delegatedLikeCalls = 0;
    final delegatedContext = CommandContext(
      playbackState: playback,
      likedTracksState: liked,
      trackId: 42,
      track: const {'id': 42, 'title': 'Forty two'},
      addToQueue: () async => delegatedQueueCalls++,
      toggleLiked: () async => delegatedLikeCalls++,
    );
    await registry[CommandId.addToQueue].execute(delegatedContext);
    await registry[CommandId.toggleLiked].execute(delegatedContext);

    expect(delegatedQueueCalls, 1);
    expect(delegatedLikeCalls, 1);
    expect(playback.enqueuedTracks, hasLength(1));
    expect(library.likedTrackIds, hasLength(1));
  });
}

class _PlaybackState extends Fake implements PlaybackState {
  final ChangeNotifier _notifier = ChangeNotifier();

  List<MediaItem> fakeQueue = const [];
  int? fakeCurrentIndex;
  Duration fakeDuration = Duration.zero;
  Duration fakePosition = Duration.zero;
  LoopMode fakeLoopMode = LoopMode.off;
  bool fakePlaying = false;
  bool? fakeCanSkipNext;
  bool? fakeCanSkipPrevious;
  bool fakeHasPreviousInPlayOrder = false;
  int toggleCalls = 0;
  final List<Duration> seekCalls = [];
  final List<Map<String, dynamic>> playNextTracks = [];
  final List<Map<String, dynamic>> enqueuedTracks = [];
  final List<String> removedQueueItemIds = [];
  final List<int> positionalRemoveCalls = [];

  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot.empty();

  @override
  List<MediaItem> get queue => fakeQueue;

  @override
  int? get currentIndex => fakeCurrentIndex;

  @override
  bool get hasTrack => fakeCurrentIndex != null && fakeQueue.isNotEmpty;

  @override
  Duration get duration => fakeDuration;

  @override
  Duration get position => fakePosition;

  @override
  LoopMode get loopMode => fakeLoopMode;

  @override
  bool get canSkipNext =>
      fakeCanSkipNext ??
      (fakeLoopMode != LoopMode.off ||
          (fakeCurrentIndex != null &&
              fakeCurrentIndex! < fakeQueue.length - 1));

  @override
  bool get canSkipPrevious =>
      fakeCanSkipPrevious ??
      (fakeLoopMode != LoopMode.off ||
          (fakeCurrentIndex != null && fakeCurrentIndex! > 0));

  @override
  bool get hasPreviousInPlayOrder => fakeHasPreviousInPlayOrder;

  @override
  bool get isPlaying => fakePlaying;

  @override
  Future<void> togglePlayPause() async {
    toggleCalls++;
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
  }

  @override
  Future<void> playNext(Map<String, dynamic> track) async {
    playNextTracks.add(track);
  }

  @override
  Future<void> enqueue(Map<String, dynamic> track) async {
    enqueuedTracks.add(track);
  }

  @override
  Future<void> removeFromQueueByQueueItemId(String queueItemId) async {
    removedQueueItemIds.add(queueItemId);
  }

  @override
  Future<void> removeFromQueue(int index) async {
    positionalRemoveCalls.add(index);
  }

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  void emit() => _notifier.notifyListeners();

  void disposeFake() => _notifier.dispose();
}

class _LibraryService extends LibraryService {
  _LibraryService() : super(ApiClient());

  final List<int> likedTrackIds = [];

  @override
  Future<void> like(int trackId) async {
    likedTrackIds.add(trackId);
  }
}
