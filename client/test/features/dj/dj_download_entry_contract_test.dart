import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #414 D11: the deck may *consume* the app's download pipeline, never build a
/// second one. `shared/widgets/download_button.dart` is the pattern; the deck
/// matches it from exactly one place.
void main() {
  late List<File> sources;

  setUp(() {
    sources = Directory('lib/features/dj')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
  });

  int occurrences(RegExp pattern) => sources.fold<int>(
        0,
        (total, file) =>
            total + pattern.allMatches(file.readAsStringSync()).length,
      );

  List<String> filesMatching(RegExp pattern) => [
        for (final file in sources)
          if (pattern.hasMatch(file.readAsStringSync())) file.path,
      ];

  test('the deck has exactly one entry into the download pipeline', () {
    expect(sources, isNotEmpty);
    final call = RegExp(r'\.downloadTrack\(');
    expect(occurrences(call), 1);
    expect(filesMatching(call), ['lib/features/dj/dj_screen.dart']);
  });

  test('the deck never constructs a download pipeline of its own', () {
    expect(occurrences(RegExp(r'\bDownloadService\s*\(')), 0);
    expect(occurrences(RegExp(r'\bDownloadState\s*\(')), 0);
    expect(occurrences(RegExp(r'\bdefaultAudioArtifactDownloader\b')), 0);
  });

  test('the deck downloads one track at a time', () {
    expect(occurrences(RegExp(r'\bdownloadTracks\(|\bdownloadPlaylist\(')), 0);
  });
}
