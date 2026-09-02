import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';

/// #414 acceptance criteria 5 and 6: every user-facing string the deck's entry
/// contract introduces is sentence case, uses no exclamation marks and carries
/// no internal phase/roadmap language. The glyph labels `CUE`, `CUES`, `LOOP`,
/// `STEMS` and the deck letters are the deliberate exemption and are recorded
/// as such on [djDeckCopyStrings] and in docs/dj-deck-spec.md.
void main() {
  test('the deck copy contract is sentence case and free of jargon', () {
    expect(djDeckCopyStrings, isNotEmpty);

    for (final copy in djDeckCopyStrings) {
      expect(copy, isNot(contains('!')), reason: '"$copy" shouts');
      expect(copy, isNotEmpty);
      expect(
        copy,
        copy[0].toUpperCase() + copy.substring(1),
        reason: '"$copy" does not start sentence-cased',
      );
      expect(
        copy,
        isNot(copy.toUpperCase()),
        reason: '"$copy" is a glyph label, not prose; glyph labels are '
            'exempt from this contract and must not be listed in it',
      );
      expect(
        RegExp(r'\b(phase|roadmap|TODO|prototype|spike)\b',
                caseSensitive: false)
            .hasMatch(copy),
        isFalse,
        reason: '"$copy" leaks internal language to the user',
      );
    }
  });

  test('the copy contract cannot be quietly emptied to pass', () {
    // A future author who deletes entries rather than fixing them would
    // otherwise get a green build from an empty list.
    expect(djDeckCopyStrings.length, greaterThanOrEqualTo(8));
    expect(
      djDeckCopyStrings.toSet().length,
      djDeckCopyStrings.length,
      reason: 'the contract must not be padded with duplicates',
    );

    final source =
        File('lib/features/dj/dj_deck_copy.dart').readAsStringSync();
    for (final copy in djDeckCopyStrings) {
      expect(source, contains(copy),
          reason: 'every contract string is declared in dj_deck_copy.dart');
    }
  });

  test('the deck features carry no user-facing phase language', () {
    final sources = Directory('lib/features/dj')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(sources, isNotEmpty);

    // Comments are stripped first: a doc comment citing "docs/dj-deck-spec.md,
    // Phase 0 item 3" is a source reference, not something a user ever reads.
    // The tooltip that read `sync engine: phase 2` was a string literal, and
    // that is what this scan is for.
    final offenders = <String>[];
    for (final file in sources) {
      if (RegExp(r'phase\s*\d', caseSensitive: false)
          .hasMatch(_withoutComments(file.readAsStringSync()))) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'the sync tooltip used to read "sync engine: phase 2"');
  });
}

/// Drops block and line comments so a scan only sees code and string literals.
/// `//` preceded by `:` is left alone, so a URL inside a literal survives.
String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final match = RegExp(r'(?<!:)//').firstMatch(line);
      return match == null ? line : line.substring(0, match.start);
    })
    .join('\n');
