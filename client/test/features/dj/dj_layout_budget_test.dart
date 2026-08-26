import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_layout.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #411: the four row heights used to be literals (120/44/flex-to-180/64), so
/// 228dp was consumed before the flexible control field got anything and the
/// deck overflowed as soon as the remainder dropped below the pitch fader's
/// 96dp floor.
void main() {
  final deck = useLoadedDjSession();

  group('DjRowBudget give-order', () {
    test('control field first, waveform second, header third, transport never',
        () {
      // Reference device, post-SafeArea: today's appearance, unchanged.
      final reference = DjRowBudget.of(378.67);
      expect(reference.waveformStack, kDjWaveformStackHeight);
      expect(reference.headerBand, kDjHeaderBandHeight);
      expect(reference.controlField, closeTo(150.67, 0.01));
      expect(reference.transport, kDjTransportHeight);

      // Density 540: the control field bottoms out and the waveform gives way.
      final dense = DjRowBudget.of(331.26);
      expect(dense.controlField, kDjControlFieldMinHeight);
      expect(dense.waveformStack, closeTo(103.26, 0.01));
      expect(dense.headerBand, kDjHeaderBandHeight);

      // The reported dpr-3.5 pitch-fader overflow case.
      final large = DjRowBudget.of(317.7);
      expect(large.controlField, kDjControlFieldMinHeight);
      expect(large.waveformStack, closeTo(89.7, 0.01));

      // The header band is the last thing to give, and the transport never
      // does.
      final minimum = DjRowBudget.of(kDjMinDeckHeight);
      expect(minimum.waveformStack, kDjWaveformStackMinHeight);
      expect(minimum.headerBand, kDjHeaderBandMinHeight);
      expect(minimum.controlField, kDjControlFieldMinHeight);
      expect(minimum.transport, kDjTransportHeight);
      expect(minimum.showsOverviewStrip, isFalse);

      for (final available in [284.0, 292.0, 317.7, 331.26, 361.6, 378.67]) {
        expect(DjRowBudget.of(available).total, lessThanOrEqualTo(available),
            reason: 'the rows must fit $available dp');
        expect(DjRowBudget.of(available).transport, kDjTransportHeight,
            reason: 'the transport never shrinks');
      }
    });
  });

  for (final base in djServiceableViewports) {
    for (final viewport in [base, base.withTextScale(1.3)]) {
      testWidgets('rows fit and the transport holds 64dp at ${viewport.name}',
          (tester) async {
        await pumpDjScreen(
            tester, session: deck.session, viewport: viewport);

        double height(String key) =>
            tester.getSize(find.byKey(ValueKey(key))).height;

        final total = height('dj_waveform_stack') +
            height('dj_header_row') +
            height('dj_control_field') +
            height('dj_transport_row');
        expect(total, lessThanOrEqualTo(viewport.safeAreaSize.height + 0.01));
        expect(height('dj_transport_row'), kDjTransportHeight);
        expect(height('dj_control_field'),
            greaterThanOrEqualTo(kDjControlFieldMinHeight));
      });
    }
  }
}
