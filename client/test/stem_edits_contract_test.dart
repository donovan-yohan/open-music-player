import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/stem_edits.dart';

void main() {
  StemEdits edits({
    StemChannelSet channelSet = StemChannelSet.stems5Hybrid,
    List<StemGainEvent> events = const <StemGainEvent>[],
    Map<String, dynamic> unknownKeys = const <String, dynamic>{},
  }) =>
      StemEdits(
        channelSet: channelSet,
        sourceFileHash: 'sha256:deadbeef',
        beatGridRef: StemBeatGridRef(
          analysisRef: 'analysis-77',
          analysisVersion: 'bands3-v1',
        ),
        events: events,
        unknownKeys: unknownKeys,
      );

  StemGainEvent event(String channel, int atMs, double gain, {int? beatIndex}) =>
      StemGainEvent(
        channel: channel,
        atMs: atMs,
        gain: gain,
        beatIndex: beatIndex,
      );

  group('channel set registry', () {
    test('stems5-hybrid-v1 pins canonical wire names and model version', () {
      const set = StemChannelSet.stems5Hybrid;

      expect(set.id, 'stems5-hybrid-v1');
      expect(set.stemModelVersion, 'htdemucs-4s-v1+lr4-180');
      expect(set.channelIds, ['vocals', 'melody', 'bass', 'kick', 'perc']);
      expect(set.contains('hihat'), isFalse,
          reason: 'hihat is retired; perc is canonical');
      expect(set.descriptorFor('melody').modelSourceChannel, 'other');
    });

    test('stems4-demucs-v1 pins canonical wire names and model version', () {
      const set = StemChannelSet.stems4Demucs;

      expect(set.id, 'stems4-demucs-v1');
      expect(set.stemModelVersion, 'htdemucs-4s-v1');
      expect(set.channelIds, ['vocals', 'drums', 'bass', 'other']);
    });

    test('lossy channels carry ADR 0006 honesty labels', () {
      const set = StemChannelSet.stems5Hybrid;

      expect(set.descriptorFor('kick').label, 'Kick (low drums)');
      expect(set.descriptorFor('perc').label, 'Hats & Percussion');
      expect(stemCutActionLabel, contains('mostly removed'));
      expect(stemCutHonestyCopy, contains('mostly removed'));
      expect(stemCutHonestyCopy, contains('not isolated'));
    });

    test('unknown channel set is rejected instead of guessed at', () {
      expect(
        () => StemChannelSet.byId('stems7-fantasy-v9'),
        throwsA(isA<StemEditsFormatException>()),
      );
      expect(StemChannelSet.tryById('stems7-fantasy-v9'), isNull);
    });
  });

  group('stemEdits json', () {
    test('round-trips through toJson and fromJson', () {
      final source = edits(
        events: [
          event('vocals', 12000, 0, beatIndex: 32),
          event('bass', 4000, 0.5),
        ],
      );

      final decoded = StemEdits.fromJson(source.toJson());

      expect(decoded, source);
      expect(decoded.toJson(), source.toJson());
      expect(decoded.schemaVersion, 1);
      expect(decoded.channelSet.id, 'stems5-hybrid-v1');
      expect(decoded.stemModelVersion, 'htdemucs-4s-v1+lr4-180');
      expect(decoded.sourceFileHash, 'sha256:deadbeef');
      expect(decoded.beatGridRef?.analysisRef, 'analysis-77');
      expect(decoded.eventsFor('bass').single.beatIndex, isNull,
          reason: 'bass event carries no beat index');
      expect(decoded.eventsFor('vocals').single.beatIndex, 32);
    });

    test('default ramp is written explicitly and stays click-safe', () {
      final json = edits(events: [event('vocals', 1000, 0)]).toJson();
      final rawEvent = (json['events'] as List).single as Map<String, dynamic>;

      expect(rawEvent['rampMs'], stemRampDefaultMs);
      expect(
        StemGainEvent(channel: 'vocals', atMs: 0, gain: 0, rampMs: 0).rampMs,
        stemRampMinMs,
      );
      expect(
        StemGainEvent(channel: 'vocals', atMs: 0, gain: 0, rampMs: 9999).rampMs,
        stemRampMaxMs,
      );
    });

    test('unknown keys survive decode then encode at every level', () {
      final json = <String, dynamic>{
        'schemaVersion': 1,
        'channelSet': 'stems5-hybrid-v1',
        'stemModelVersion': 'htdemucs-4s-v1+lr4-180',
        'sourceFileHash': 'sha256:deadbeef',
        'futureTopLevel': {'nested': true},
        'beatGridRef': {
          'analysisRef': 'analysis-77',
          'analysisVersion': 'bands3-v1',
          'futureGridKey': 'keep me',
        },
        'events': [
          {
            'channel': 'vocals',
            'atMs': 12000,
            'gain': 0.0,
            'rampMs': 8,
            'futureEventKey': 42,
          },
        ],
      };

      final encoded = StemEdits.fromJson(json).toJson();

      expect(encoded['futureTopLevel'], {'nested': true});
      expect(
        (encoded['beatGridRef'] as Map)['futureGridKey'],
        'keep me',
      );
      expect(
        ((encoded['events'] as List).single as Map)['futureEventKey'],
        42,
      );
    });

    test('unknown schemaVersion is rejected rather than coerced', () {
      final json = edits().toJson()..['schemaVersion'] = 2;

      expect(
        () => StemEdits.fromJson(json),
        throwsA(
          isA<StemEditsFormatException>().having(
            (e) => e.message,
            'message',
            contains('schemaVersion 2'),
          ),
        ),
      );
    });

    test('missing schemaVersion is rejected', () {
      final json = edits().toJson()..remove('schemaVersion');

      expect(
        () => StemEdits.fromJson(json),
        throwsA(isA<StemEditsFormatException>()),
      );
    });

    test('event on a channel outside the set is rejected', () {
      final json = edits().toJson()
        ..['events'] = [
          {'channel': 'hihat', 'atMs': 1000, 'gain': 0.0},
        ];

      expect(
        () => StemEdits.fromJson(json),
        throwsA(
          isA<StemEditsFormatException>().having(
            (e) => e.message,
            'message',
            contains('hihat'),
          ),
        ),
      );
    });
  });

  group('canonical ordering', () {
    test('events sort by atMs then channel', () {
      final doc = edits(
        events: [
          event('vocals', 9000, 0),
          event('bass', 1000, 0),
          event('vocals', 1000, 0.25),
        ],
      );

      expect(
        doc.events.map((e) => '${e.channel}@${e.atMs}').toList(),
        ['bass@1000', 'vocals@1000', 'vocals@9000'],
      );
    });

    test('duplicate channel and atMs collapse to the later write', () {
      final doc = edits(
        events: [
          event('vocals', 5000, 1),
          event('vocals', 5000, 0.25),
        ],
      );

      expect(doc.events, hasLength(1));
      expect(doc.events.single.gain, 0.25);
    });

    test('withEvent replaces an existing change point at the same ms', () {
      final doc = edits(events: [event('vocals', 5000, 1)])
          .withEvent(event('vocals', 5000, 0));

      expect(doc.events, hasLength(1));
      expect(doc.events.single.gain, 0);
    });

    test('withEvent rejects a channel outside the set', () {
      expect(
        () => edits().withEvent(event('hihat', 1000, 0)),
        throwsA(isA<StemEditsFormatException>()),
      );
    });

    test('withoutEvent removes exactly one change point', () {
      final doc = edits(
        events: [
          event('vocals', 1000, 0),
          event('vocals', 2000, 1),
          event('bass', 1000, 0),
        ],
      ).withoutEvent(channel: 'vocals', atMs: 1000);

      expect(doc.events, hasLength(2));
      expect(doc.eventsFor('vocals').single.atMs, 2000);
      expect(doc.eventsFor('bass').single.atMs, 1000);
    });
  });

  group('gain hold semantics', () {
    test('implicit gain before the first change point is full', () {
      final doc = edits(events: [event('vocals', 12000, 0)]);

      expect(doc.gainAt('vocals', 0), 1.0);
      expect(doc.gainAt('vocals', 11999), 1.0);
      expect(doc.gainAt('vocals', 12000), 0.0);
    });

    test('a gain is held until the next change point on the same channel', () {
      final doc = edits(
        events: [
          event('vocals', 1000, 0),
          event('vocals', 5000, 0.5),
          event('bass', 2000, 0.25),
        ],
      );

      expect(doc.gainAt('vocals', 4999), 0.0);
      expect(doc.gainAt('vocals', 5000), 0.5);
      expect(doc.gainAt('vocals', 999999), 0.5);
      expect(doc.gainAt('bass', 4999), 0.25,
          reason: 'a vocals change point must not move bass');
      expect(doc.gainAt('kick', 999999), 1.0,
          reason: 'an untouched channel stays at full gain');
    });

    test('gain is clamped to the linear 0..1 range', () {
      expect(
        StemGainEvent(channel: 'vocals', atMs: 0, gain: 4).gain,
        1.0,
      );
      expect(
        StemGainEvent(channel: 'vocals', atMs: 0, gain: -2).gain,
        0.0,
      );
      expect(
        StemGainEvent(channel: 'vocals', atMs: 0, gain: 0).isCut,
        isTrue,
      );
    });
  });

  group('compileRanges', () {
    const clipDurationMs = 60000;

    test('a channel with no change points compiles to one full-gain range', () {
      final ranges = edits().compileRanges(clipDurationMs: clipDurationMs);

      expect(ranges, hasLength(StemChannelSet.stems5Hybrid.channels.length));
      for (final range in ranges) {
        expect(range.startMs, 0);
        expect(range.endMs, clipDurationMs);
        expect(range.gain, 1.0);
      }
    });

    test('emits the implicit leading full-gain range and runs to clip end', () {
      final ranges = edits(
        events: [
          event('vocals', 12000, 0),
          event('vocals', 20000, 1),
        ],
      ).compileRanges(clipDurationMs: clipDurationMs);
      final vocals =
          ranges.where((range) => range.channel == 'vocals').toList();

      expect(vocals, hasLength(3));
      expect(vocals[0].startMs, 0);
      expect(vocals[0].endMs, 12000);
      expect(vocals[0].gain, 1.0);
      expect(vocals[1].startMs, 12000);
      expect(vocals[1].endMs, 20000);
      expect(vocals[1].gain, 0.0);
      expect(vocals[2].startMs, 20000);
      expect(vocals[2].endMs, clipDurationMs);
      expect(vocals[2].gain, 1.0);
    });

    test('a change point at zero suppresses the implicit leading range', () {
      final vocals = edits(events: [event('vocals', 0, 0)])
          .compileRanges(clipDurationMs: clipDurationMs)
          .where((range) => range.channel == 'vocals')
          .toList();

      expect(vocals, hasLength(1));
      expect(vocals.single.startMs, 0);
      expect(vocals.single.gain, 0.0);
    });

    test('change points at or past clip end are not compiled', () {
      final vocals = edits(
        events: [
          event('vocals', 1000, 0),
          event('vocals', clipDurationMs, 1),
          event('vocals', clipDurationMs + 5000, 0.5),
        ],
      )
          .compileRanges(clipDurationMs: clipDurationMs)
          .where((range) => range.channel == 'vocals')
          .toList();

      expect(vocals, hasLength(2));
      expect(vocals.last.endMs, clipDurationMs);
      expect(vocals.last.gain, 0.0);
    });

    test('ranges are half-open and equivalent to gainAt across the clip', () {
      final doc = edits(
        events: [
          event('vocals', 12000, 0),
          event('vocals', 20000, 1),
          event('bass', 0, 0.25),
          event('kick', 33333, 0),
          event('perc', 59999, 0),
        ],
      );
      final ranges = doc.compileRanges(clipDurationMs: clipDurationMs);

      for (final channel in doc.channelSet.channelIds) {
        for (var ms = 0; ms < clipDurationMs; ms += 137) {
          final covering = ranges
              .where((range) => range.channel == channel && range.contains(ms))
              .toList();

          expect(covering, hasLength(1),
              reason: '$channel at ${ms}ms must be covered exactly once');
          expect(covering.single.gain, doc.gainAt(channel, ms),
              reason: '$channel at ${ms}ms must agree with gainAt');
        }
      }
    });

    test('ranges tile the clip with no gap and no overlap', () {
      final doc = edits(
        events: [
          event('vocals', 12000, 0),
          event('vocals', 20000, 1),
        ],
      );
      final vocals = doc
          .compileRanges(clipDurationMs: clipDurationMs)
          .where((range) => range.channel == 'vocals')
          .toList();

      expect(vocals.first.startMs, 0);
      expect(vocals.last.endMs, clipDurationMs);
      for (var i = 1; i < vocals.length; i++) {
        expect(vocals[i].startMs, vocals[i - 1].endMs);
      }
    });

    test('a zero-length clip compiles to no ranges', () {
      expect(edits().compileRanges(clipDurationMs: 0), isEmpty);
    });
  });

  group('quantizeToBeats', () {
    test('snaps ms to the nearest beat and records advisory provenance', () {
      final beats = [0, 500, 1000, 1500, 2000];
      final doc = edits(
        events: [
          event('vocals', 1100, 0),
          event('bass', 1900, 0.5),
        ],
      ).quantizeToBeats(beats);

      expect(doc.eventsFor('vocals').single.atMs, 1000);
      expect(doc.eventsFor('vocals').single.beatIndex, 2);
      expect(doc.eventsFor('bass').single.atMs, 2000);
      expect(doc.eventsFor('bass').single.beatIndex, 4);
    });

    test('the snapped millisecond is what is stored', () {
      final doc = edits(events: [event('vocals', 1100, 0)])
          .quantizeToBeats([0, 500, 1000, 1500]);
      final reloaded = StemEdits.fromJson(doc.toJson());

      expect(reloaded.eventsFor('vocals').single.atMs, 1000,
          reason: 'ms stays authoritative after a round-trip');
      expect(reloaded.gainAt('vocals', 1000), 0.0);
      expect(reloaded.gainAt('vocals', 999), 1.0);
    });

    test('snapping can collapse two change points onto one beat', () {
      final doc = edits(
        events: [
          event('vocals', 980, 1),
          event('vocals', 1020, 0),
        ],
      ).quantizeToBeats([0, 1000, 2000]);

      expect(doc.eventsFor('vocals'), hasLength(1));
      expect(doc.eventsFor('vocals').single.atMs, 1000);
    });

    test('an empty beat grid leaves the document untouched', () {
      final doc = edits(events: [event('vocals', 1100, 0)]);

      expect(doc.quantizeToBeats(const []), doc);
    });

    test('nearestBeatIndex resolves ties to the earlier beat', () {
      expect(nearestBeatIndex(const [0, 1000], 500), 0);
      expect(nearestBeatIndex(const [], 500), isNull);
    });
  });
}
