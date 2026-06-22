import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/discovery/discovery_models.dart';

void main() {
  test('parses a grounded search assist envelope', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': 'ok',
      'assistantText': "Here's what I found from your sources.",
      'intent': {
        'kind': 'search',
        'searchQuery': 'porter robinson shelter live',
        'providers': ['youtube', 'soundcloud'],
      },
      'search': {
        'query': 'porter robinson shelter live',
        'results': [
          {
            'candidateId': 'youtube:abc',
            'provider': 'youtube',
            'sourceId': 'abc',
            'sourceUrl': 'https://youtube.com/watch?v=abc',
            'title': 'Porter Robinson - Shelter (Live)',
            'artist': 'Porter Robinson',
            'durationMs': 245000,
            'downloadable': true,
            'playable': false,
          },
        ],
        'providers': [
          {
            'provider': 'youtube',
            'status': 'ok',
            'resultCount': 1,
            'elapsedMs': 30,
          },
        ],
      },
      'caveats': ['These are likely matches, not a confirmed live version.'],
    });

    expect(response.isOk, isTrue);
    expect(response.assistantText, "Here's what I found from your sources.");
    expect(response.intent?.kind, 'search');
    expect(response.intent?.searchQuery, 'porter robinson shelter live');
    expect(response.intent?.providers, ['youtube', 'soundcloud']);
    expect(response.search?.sections.single.kind, 'sources');
    expect(
      response.search?.sections.single.items.single.candidate?.candidateId,
      'youtube:abc',
    );
    expect(response.search?.providers.single.status, 'ok');
    expect(response.caveats, hasLength(1));
    expect(response.hasSearchResults, isTrue);
    // A grounded search envelope carries no top-level direct-URL candidates:
    // those are exclusive to the resolver path.
    expect(response.hasCandidates, isFalse);
    expect(response.hasGroundedResults, isTrue);
  });

  test('parses a direct-URL assist envelope with a grounded candidate', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': 'ok',
      'assistantText': 'I recognized a direct link. Confirm to add it.',
      'intent': {
        'kind': 'direct_url',
        'detectedUrl': 'https://youtu.be/abc',
      },
      'candidates': [
        {
          'candidateId': 'youtube:abc',
          'provider': 'youtube',
          'sourceId': 'abc',
          'sourceUrl': 'https://youtu.be/abc',
          'title': 'Pasted Track',
          'downloadable': true,
          'playable': false,
        },
      ],
    });

    expect(response.isOk, isTrue);
    expect(response.intent?.isDirectUrl, isTrue);
    expect(response.intent?.detectedUrl, 'https://youtu.be/abc');
    expect(response.candidates.single.title, 'Pasted Track');
    expect(response.candidates.single.downloadable, isTrue);
    expect(response.hasCandidates, isTrue);
    // A direct-URL envelope carries no provider search payload.
    expect(response.hasSearchResults, isFalse);
    expect(response.hasGroundedResults, isTrue);
  });

  test('parses a disabled assist envelope', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': 'disabled',
      'assistantText':
          'AI assist is not configured. You can still search directly or paste a link.',
      'error': {'code': 'AI_DISABLED', 'message': 'ai assist is disabled'},
    });

    expect(response.isDisabled, isTrue);
    expect(response.isOk, isFalse);
    expect(response.error?.code, 'AI_DISABLED');
    expect(response.assistantText, contains('not configured'));
    expect(response.hasGroundedResults, isFalse);
  });

  test('parses an error assist envelope', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': 'error',
      'assistantText': 'The assistant is unavailable right now.',
      'error': {'code': 'AI_UPSTREAM', 'message': 'upstream timeout'},
    });

    expect(response.isError, isTrue);
    expect(response.error?.code, 'AI_UPSTREAM');
    expect(response.error?.message, 'upstream timeout');
  });

  test('parses a clarification assist envelope', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': 'clarification',
      'assistantText': 'Could you give me a bit more detail?',
      'clarification': {
        'question': 'Which Shelter do you mean?',
        'options': ['The 2016 single', 'A live festival set'],
      },
      'intent': {'kind': 'clarify'},
    });

    expect(response.isClarification, isTrue);
    expect(response.clarification?.question, 'Which Shelter do you mean?');
    expect(response.clarification?.options, hasLength(2));
    expect(response.intent?.kind, 'clarify');
  });

  test('defaults a blank status to error and drops blank caveats', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': '',
      'caveats': ['  ', '', 'youtube: degraded'],
    });

    expect(response.isError, isTrue);
    expect(response.caveats, ['youtube: degraded']);
    expect(response.candidates, isEmpty);
    expect(response.intent, isNull);
    expect(response.search, isNull);
  });

  test('defaults unknown statuses to error', () {
    final response = DiscoveryAssistResponse.fromJson({
      'status': 'surprise-computer-garbage',
      'assistantText': 'unknown backend status',
    });

    expect(response.isError, isTrue);
    expect(response.isOk, isFalse);
    expect(response.isDisabled, isFalse);
    expect(response.isClarification, isFalse);
    expect(response.hasGroundedResults, isFalse);
  });

  test('defaults a fully absent status key to error', () {
    final response = DiscoveryAssistResponse.fromJson({
      'assistantText': 'no status field at all',
    });

    expect(response.isError, isTrue);
    expect(response.hasGroundedResults, isFalse);
  });
}
