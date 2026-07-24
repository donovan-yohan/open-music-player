import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AudioFocusCoordinator is the sole interruption owner', () {
    final playerConstructions = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .expand((file) => _audioPlayerConstructions(file.readAsStringSync()))
        .toList();
    final coordinatorSource =
        File('lib/core/audio/audio_focus_coordinator.dart').readAsStringSync();

    expect(
      playerConstructions,
      isNotEmpty,
      reason: 'The client must retain at least one AudioPlayer construction.',
    );
    expect(
      playerConstructions.where(_disablesPluginInterruptions).length,
      playerConstructions.length,
      reason: 'Every AudioPlayer in client/lib must delegate interruptions to '
          'AudioFocusCoordinator.',
    );
    expect(
      coordinatorSource,
      isNot(contains(RegExp(r'''import\s+['"][^'"]*engine[^'"]*['"]'''))),
      reason: 'AudioFocusCoordinator must use the canonical playback facade.',
    );
  });

  test('comments and strings cannot spoof interruption ownership', () {
    final commentDecoy = _audioPlayerConstructions('''
      AudioPlayer(
        /* handleInterruptions: false, and unmatched decoy parens: ))) */
        audioLoadConfiguration: "handleInterruptions: false ((((",
      );
    ''').single;
    expect(_disablesPluginInterruptions(commentDecoy), isFalse);

    expect(
      _audioPlayerConstructions(
        '"AudioPlayer(handleInterruptions: false)"',
      ),
      isEmpty,
    );

    final nestedArgumentDecoy = _audioPlayerConstructions('''
      AudioPlayer(
        audioLoadConfiguration: Builder(handleInterruptions: false),
      );
    ''').single;
    expect(_disablesPluginInterruptions(nestedArgumentDecoy), isFalse);
  });

  test('reordered and reformatted ownership argument remains valid', () {
    final construction = _audioPlayerConstructions('''
      AudioPlayer(
        audioLoadConfiguration: const AudioLoadConfiguration(),
        handleInterruptions
          :
          false,
      );
    ''').single;

    expect(_disablesPluginInterruptions(construction), isTrue);
  });
}

typedef _Construction = List<String>;

Iterable<_Construction> _audioPlayerConstructions(String source) sync* {
  final tokens = _dartCodeTokens(source);
  for (var index = 0; index + 1 < tokens.length; index++) {
    if (tokens[index] != 'AudioPlayer' || tokens[index + 1] != '(') continue;
    var depth = 0;
    final body = <String>[];
    for (var cursor = index + 1; cursor < tokens.length; cursor++) {
      final token = tokens[cursor];
      if (token == '(') {
        depth++;
        if (depth > 1) body.add(token);
        continue;
      }
      if (token == ')') {
        depth--;
        if (depth == 0) {
          yield body;
          break;
        }
      }
      body.add(token);
    }
  }
}

bool _disablesPluginInterruptions(_Construction construction) {
  var depth = 0;
  for (var index = 0; index + 2 < construction.length; index++) {
    final token = construction[index];
    if (token == '(' || token == '[' || token == '{') {
      depth++;
      continue;
    }
    if (token == ')' || token == ']' || token == '}') {
      depth--;
      continue;
    }
    if (depth == 0 &&
        token == 'handleInterruptions' &&
        construction[index + 1] == ':' &&
        construction[index + 2] == 'false') {
      return true;
    }
  }
  return false;
}

List<String> _dartCodeTokens(String source) {
  final tokens = <String>[];
  var index = 0;
  while (index < source.length) {
    final char = source[index];
    if (_isWhitespace(char)) {
      index++;
      continue;
    }
    if (char == '/' && index + 1 < source.length) {
      if (source[index + 1] == '/') {
        index = _skipLineComment(source, index + 2);
        continue;
      }
      if (source[index + 1] == '*') {
        index = _skipBlockComment(source, index + 2);
        continue;
      }
    }
    if (char == "'" || char == '"') {
      index = _skipString(source, index);
      continue;
    }
    if (_isIdentifierStart(char)) {
      final start = index++;
      while (index < source.length && _isIdentifierPart(source[index])) {
        index++;
      }
      tokens.add(source.substring(start, index));
      continue;
    }
    tokens.add(char);
    index++;
  }
  return tokens;
}

int _skipLineComment(String source, int index) {
  while (index < source.length && source[index] != '\n') {
    index++;
  }
  return index;
}

int _skipBlockComment(String source, int index) {
  var depth = 1;
  while (index + 1 < source.length && depth > 0) {
    if (source[index] == '/' && source[index + 1] == '*') {
      depth++;
      index += 2;
    } else if (source[index] == '*' && source[index + 1] == '/') {
      depth--;
      index += 2;
    } else {
      index++;
    }
  }
  return index;
}

int _skipString(String source, int index) {
  final quote = source[index];
  final triple = index + 2 < source.length &&
      source[index + 1] == quote &&
      source[index + 2] == quote;
  final raw = index > 0 &&
      (source[index - 1] == 'r' || source[index - 1] == 'R') &&
      (index < 2 || !_isIdentifierPart(source[index - 2]));
  index += triple ? 3 : 1;
  while (index < source.length) {
    if (!raw && source[index] == '\\') {
      index += 2;
      continue;
    }
    if (triple) {
      if (index + 2 < source.length &&
          source[index] == quote &&
          source[index + 1] == quote &&
          source[index + 2] == quote) {
        return index + 3;
      }
    } else if (source[index] == quote) {
      return index + 1;
    }
    index++;
  }
  return index;
}

bool _isWhitespace(String char) =>
    char == ' ' || char == '\t' || char == '\n' || char == '\r';

bool _isIdentifierStart(String char) =>
    char == '_' ||
    (char.codeUnitAt(0) >= 65 && char.codeUnitAt(0) <= 90) ||
    (char.codeUnitAt(0) >= 97 && char.codeUnitAt(0) <= 122);

bool _isIdentifierPart(String char) =>
    _isIdentifierStart(char) ||
    (char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57);
