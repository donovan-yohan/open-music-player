import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:open_music_player/shared/widgets/like_button.dart';
import 'package:open_music_player/shared/widgets/download_button.dart';

import 'flight_callers_test.dart'
    show pumpFixture, pixel, contrast, macOS, save;

void main() {
  testWidgets(
      'liked selected heart uses resolved pressed foreground not child orange',
      (tester) async {
    final service = _Library();
    final liked = LikedTracksState(service)..seedValue(1, true);
    addTearDown(liked.dispose);
    await pumpFixture(
        tester,
        ChangeNotifierProvider.value(
            value: liked,
            child: const Row(children: [LikeToggleButton.forId(trackId: 1)])));
    final button = find.byType(IconButton);
    expect(tester.widget<IconButton>(button).isSelected, isTrue);
    await measureNativeStates(tester, button, Icons.favorite, 'liked');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final icon = find.byIcon(Icons.favorite);
    Focus.of(tester.element(icon)).requestFocus();
    await mouse.moveTo(tester.getCenter(button));
    await tester.pumpAndSettle();
    await mouse.down(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final ink = tester.widget<InkWell>(
        find.descendant(of: button, matching: find.byType(InkWell)));
    expect(
        ink.statesController!.value,
        containsAll(
            [WidgetState.focused, WidgetState.hovered, WidgetState.pressed]));
    final actualIcon = tester.widget<Icon>(icon);
    final fg = actualIcon.color ?? IconTheme.of(tester.element(icon)).color!;
    final material =
        find.descendant(of: button, matching: find.byType(Material));
    final fill = await pixel(
        tester, tester.getRect(material).topLeft + const Offset(5, 5));
    expect(contrast(fg, fill), greaterThanOrEqualTo(4.5));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(service.unliked, [1]);
  }, variant: macOS);
  testWidgets('download default and progress are equal 40 paint and 20 glyph',
      (tester) async {
    final downloads = _Downloads();
    addTearDown(downloads.dispose);
    final track = Track.fromJson({'id': 1, 'title': 'Glasshouse'});
    await pumpFixture(
        tester,
        ChangeNotifierProvider<DownloadState>.value(
            value: downloads,
            child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [DownloadButton(track: track)])));
    var button = find.byType(IconButton);
    var material = find.descendant(of: button, matching: find.byType(Material));
    final rect = tester.getRect(material);
    expect(rect.size, const Size(40, 40));
    expect(tester.getSize(find.byIcon(Icons.download_outlined)),
        const Size(20, 20));
    await tester.tap(button);
    expect(downloads.requested, [1]);
    downloads.progress = DownloadProgress(
        trackId: 1, progress: .4, status: DownloadStatus.downloading);
    downloads.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    button = find.byType(IconButton);
    material = find.descendant(of: button, matching: find.byType(Material));
    expect(tester.getRect(material), rect);
    expect(tester.getSize(find.byIcon(Icons.close)), const Size(20, 20));
    final ring = tester.getRect(find.byType(CircularProgressIndicator));
    expect(tester.getRect(material).contains(ring.topLeft), isTrue);
    expect(tester.getRect(material).contains(ring.bottomRight), isTrue);
    expect(ring.center, rect.center);
    expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(40));
    await measureNativeStates(tester, button, Icons.close, 'download-progress');
    await tester.tap(button);
    expect(downloads.cancelled, [1]);
  }, variant: macOS);
  testWidgets(
      'download completed selected native contrast and confirmation are preserved',
      (tester) async {
    final downloads = _Downloads()..downloaded = true;
    addTearDown(downloads.dispose);
    await pumpFixture(
        tester,
        ChangeNotifierProvider<DownloadState>.value(
            value: downloads,
            child: Row(children: [
              DownloadButton(
                  track: Track.fromJson({'id': 1, 'title': 'Glasshouse'}))
            ])));
    final button = find.byType(IconButton);
    expect(tester.widget<IconButton>(button).isSelected, isTrue);
    expect(tester.getSize(find.byIcon(Icons.check_circle)), const Size(20, 20));
    await measureNativeStates(tester, button, Icons.check_circle, 'downloaded');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Remove Download'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(downloads.deleted, isEmpty);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(downloads.deleted, [1]);
  }, variant: macOS);

  testWidgets(
      'busy optimistic like keeps geometry and rejects duplicate input then rolls back error',
      (tester) async {
    final service = _Library()..barrier = Completer<void>();
    final liked = LikedTracksState(service)..seedValue(1, false);
    addTearDown(liked.dispose);
    await pumpFixture(
        tester,
        ChangeNotifierProvider.value(
            value: liked,
            child: const Row(children: [LikeToggleButton.forId(trackId: 1)])));
    final button = find.byType(IconButton);
    final material =
        find.descendant(of: button, matching: find.byType(Material));
    final rect = tester.getRect(material);
    await tester.tap(button);
    await tester.pump();
    expect(liked.isLiked(1), isTrue);
    expect(liked.isToggling(1), isTrue);
    expect(tester.widget<IconButton>(button).onPressed, isNull);
    expect(tester.getRect(material), rect);
    expect(tester.getSize(find.byIcon(Icons.favorite)), const Size(20, 20));
    await tester.tap(button);
    expect(service.liked, [1]);
    service.barrier!
        .completeError(StateError('intentional persistence failure'));
    await tester.pumpAndSettle();
    expect(liked.isLiked(1), isFalse);
    expect(liked.isToggling(1), isFalse);
    expect(find.text('Could not update liked status'), findsOneWidget);
    expect(tester.getRect(material.first), rect);
  }, variant: macOS);

  for (final width in [959.0, 960.0]) {
    for (final size in [20.0, 24.0, 32.0]) {
      testWidgets('download role geometry $width requested$size',
          (tester) async {
        final downloads = _Downloads();
        addTearDown(downloads.dispose);
        await pumpFixture(
            tester,
            ChangeNotifierProvider<DownloadState>.value(
                value: downloads,
                child: Row(children: [
                  DownloadButton(
                      track: Track.fromJson({'id': 1, 'title': 'Track'}),
                      size: size)
                ])),
            width: width,
            scale: 2);
        final glyph = find.byIcon(Icons.download_outlined);
        expect(tester.getSize(glyph),
            Size.square(width < 960 || size > 24 ? size : 20));
        if (width >= 960) {
          final material = find.descendant(
              of: find.byType(IconButton), matching: find.byType(Material));
          expect(tester.getSize(material),
              Size.square(size > 24 ? size + 16 : 40));
          await measureNativeStates(tester, find.byType(IconButton),
              Icons.download_outlined, 'download-${size.toInt()}');
        }
      }, variant: macOS);
    }
  }
  testWidgets(
      'explicit larger like role remains larger outside the normal row cell',
      (tester) async {
    final liked = LikedTracksState(_Library())..seedValue(1, false);
    addTearDown(liked.dispose);
    await pumpFixture(
        tester,
        ChangeNotifierProvider.value(
            value: liked,
            child: const Row(
                children: [LikeToggleButton.forId(trackId: 1, iconSize: 32)])));
    expect(
        tester.getSize(find.byIcon(Icons.favorite_border)), const Size(32, 32));
    final material = find.descendant(
        of: find.byType(IconButton), matching: find.byType(Material));
    expect(tester.getSize(material), const Size(48, 48));
  }, variant: macOS);

  for (final width in [959.0, 960.0]) {
    testWidgets('like mobile geometry and selected color remain scoped $width',
        (tester) async {
      final liked = LikedTracksState(_Library())..seedValue(1, true);
      addTearDown(liked.dispose);
      await pumpFixture(
          tester,
          ChangeNotifierProvider.value(
              value: liked,
              child: const Row(children: [LikeToggleButton.forId(trackId: 1)])),
          width: width,
          scale: 2);
      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(tester.getSize(find.byIcon(Icons.favorite)), const Size(20, 20));
      if (width < 960) {
        expect(button.isSelected, isNull);
        expect(
            tester.widget<Icon>(find.byIcon(Icons.favorite)).color,
            Theme.of(tester.element(find.byType(IconButton)))
                .colorScheme
                .primary);
        expect(button.visualDensity, VisualDensity.compact);
      } else {
        expect(button.isSelected, isTrue);
        expect(tester.widget<Icon>(find.byIcon(Icons.favorite)).color, isNull);
        await measureNativeStates(
            tester, find.byType(IconButton), Icons.favorite, 'like-960-2x');
      }
    }, variant: macOS);
  }
  testWidgets(
      'absent optional liked and collection download providers stay absent',
      (tester) async {
    await pumpFixture(
        tester,
        const Column(children: [
          LikeToggleButton.forId(trackId: 1),
          DownloadAllButton(tracks: [])
        ]));
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  }, variant: macOS);
}

Future<void> measureNativeStates(
    WidgetTester tester, Finder button, IconData data, String name) async {
  final icon = find.descendant(of: button, matching: find.byIcon(data));
  final material = find.descendant(of: button, matching: find.byType(Material));
  final rect = tester.getRect(material);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(800, 800));
  await mouse.moveTo(tester.getCenter(button));
  Focus.of(tester.element(icon)).requestFocus();
  await tester.pumpAndSettle();
  final ink = tester.widget<InkWell>(
      find.descendant(of: button, matching: find.byType(InkWell)));
  expect(ink.statesController!.value,
      containsAll([WidgetState.hovered, WidgetState.focused]));
  Future<void> sample() async {
    final fg = tester.widget<Icon>(icon).color ??
        IconTheme.of(tester.element(icon)).color!;
    final fill = await pixel(tester, rect.topLeft + const Offset(5, 5));
    expect(contrast(fg, fill), greaterThanOrEqualTo(4.5));
    expect(tester.getRect(material), rect);
  }

  await sample();
  await save(tester, '$name-focus-hover');
  await mouse.down(tester.getCenter(button));
  await tester.pump();
  expect(
      ink.statesController!.value,
      containsAll(
          [WidgetState.hovered, WidgetState.focused, WidgetState.pressed]));
  for (final ms in [0, 50, 150, 300]) {
    await tester.pump(Duration(milliseconds: ms));
    await sample();
  }
  await save(tester, '$name-held');
  await mouse.cancel();
  for (final ms in [0, 50, 150, 300]) {
    await tester.pump(Duration(milliseconds: ms));
    await sample();
  }
  await save(tester, '$name-release');
  await mouse.removePointer();
  await tester.pumpAndSettle();
}

class _Downloads extends ChangeNotifier implements DownloadState {
  bool downloaded = false;
  DownloadProgress? progress;
  final requested = <int>[], cancelled = <int>[], deleted = <int>[];
  @override
  DownloadProgress? getProgress(int id) => progress;
  @override
  Future<bool> isDownloaded(int id) async => downloaded;
  @override
  Future<void> downloadTrack(Track track) async => requested.add(track.id);
  @override
  void cancelDownload(int id) {
    cancelled.add(id);
    progress = null;
    notifyListeners();
  }

  @override
  Future<void> deleteDownload(int id) async => deleted.add(id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library extends LibraryService {
  _Library() : super(ApiClient());
  final liked = <int>[], unliked = <int>[];
  Completer<void>? barrier;
  @override
  Future<void> like(int id) async {
    liked.add(id);
    await barrier?.future;
  }

  @override
  Future<void> unlike(int id) async {
    unliked.add(id);
    await barrier?.future;
  }
}
