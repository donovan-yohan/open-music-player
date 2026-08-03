import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/stems/stem_edit_playback_stub.dart';
import 'package:open_music_player/models/stem_edits.dart';

void main() {
  StemEdits edits({List<StemGainEvent> events = const <StemGainEvent>[]}) =>
      StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: 'sha256:deadbeef',
        events: events,
      );

  test('the stub never reports available and mirrors pending from status', () {
    final stub = StemEditPlaybackStub(edits: edits());

    for (final status in StemsStatus.values) {
      stub.status = status;
      expect(stub.isAvailable, isFalse,
          reason: 'Rung A never mixes stems live');
      expect(stub.isPending, status == StemsStatus.pending);
    }
  });

  test('channels expose the active set with honest labels', () {
    final stub = StemEditPlaybackStub(edits: edits());

    expect(stub.channels.map((c) => c.id).toList(),
        ['vocals', 'melody', 'bass', 'kick', 'perc']);
    expect(
      stub.channels.firstWhere((c) => c.id == 'kick').label,
      'Kick (low drums)',
    );
    expect(
      stub.channels.firstWhere((c) => c.id == 'perc').label,
      'Hats & Percussion',
    );
  });

  test('channel gains are read from the document at the position', () {
    final stub = StemEditPlaybackStub(
      edits: edits(
        events: [StemGainEvent(channel: 'vocals', atMs: 5000, gain: 0)],
      ),
      positionMs: 4999,
    );

    expect(stub.channels.firstWhere((c) => c.id == 'vocals').gain, 1.0);
    expect(stub.channels.firstWhere((c) => c.id == 'vocals').muted, isFalse);

    stub.positionMs = 5000;

    expect(stub.channels.firstWhere((c) => c.id == 'vocals').gain, 0.0);
    expect(stub.channels.firstWhere((c) => c.id == 'vocals').muted, isTrue);
    expect(stub.channels.firstWhere((c) => c.id == 'bass').gain, 1.0);
  });

  test('setGain writes a click-safe change point and notifies', () async {
    final observed = <StemEdits>[];
    final stub = StemEditPlaybackStub(
      edits: edits(),
      positionMs: 12000,
      onEditsChanged: observed.add,
    );

    await stub.setGain('vocals', 0.25);

    expect(stub.edits.events, hasLength(1));
    final written = stub.edits.events.single;
    expect(written.channel, 'vocals');
    expect(written.atMs, 12000);
    expect(written.gain, 0.25);
    expect(written.rampMs, stemRampDefaultMs);
    expect(observed.single, stub.edits);
  });

  test('setMute cuts and unmutes through the document', () async {
    final stub = StemEditPlaybackStub(edits: edits(), positionMs: 3000);

    await stub.setMute('kick', true);
    expect(stub.edits.gainAt('kick', 3000), 0.0);
    expect(stub.channels.firstWhere((c) => c.id == 'kick').muted, isTrue);

    stub.positionMs = 9000;
    await stub.setMute('kick', false);
    expect(stub.edits.gainAt('kick', 9000), 1.0);
    expect(stub.edits.events, hasLength(2));
  });

  test('writing twice at the same position collapses to one change point',
      () async {
    final stub = StemEditPlaybackStub(edits: edits(), positionMs: 1000);

    await stub.setGain('bass', 0.5);
    await stub.setGain('bass', 0.0);

    expect(stub.edits.events, hasLength(1));
    expect(stub.edits.events.single.gain, 0.0);
  });

  test('a channel outside the set is rejected', () async {
    final stub = StemEditPlaybackStub(edits: edits());

    expect(
      () => stub.setGain('hihat', 0),
      throwsA(isA<StemEditsFormatException>()),
    );
  });

  test('the unavailable source exposes no channels', () async {
    const source = UnavailableStemChannelSource(isPending: true);

    expect(source.isAvailable, isFalse);
    expect(source.isPending, isTrue);
    expect(source.channels, isEmpty);
    await source.setGain('vocals', 0);
    await source.setMute('vocals', true);
  });

  test('the stub imports no audio engine, playback state, or voice pool', () {
    final source = File(
      'lib/features/stems/stem_edit_playback_stub.dart',
    ).readAsStringSync();
    final imports = RegExp(r"^import\s+'([^']+)'", multiLine: true)
        .allMatches(source)
        .map((match) => match.group(1)!)
        .toList();

    expect(imports, ['../../models/stem_edits.dart'],
        reason: 'playback wiring is intentionally stubbed (ADR 0006 Rung A/B)');

    // The header comment deliberately names the engine types this file must
    // not touch, so only executable lines are searched for them.
    final code = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    for (final banned in [
      'just_audio',
      'VoicePool',
      'PlaybackState',
      'QueueTimelineController',
      'PlaybackEngine',
      'TimelineClock',
    ]) {
      expect(code.contains(banned), isFalse,
          reason: '$banned must stay out of the stem authoring stub');
    }
  });
}
