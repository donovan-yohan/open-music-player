// Same routed/native action and raster contrast gates, with actual bundled
// glyphs. Keep the original default-font suite independently runnable.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_native_control_regression_test.dart' as native;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in {
      'Space Grotesk': [
        'spacegrotesk/SpaceGrotesk-Regular.ttf',
        'spacegrotesk/SpaceGrotesk-Medium.ttf',
        'spacegrotesk/SpaceGrotesk-SemiBold.ttf',
        'spacegrotesk/SpaceGrotesk-Bold.ttf',
      ],
      'MaterialIcons': ['../fonts/MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(rootBundle.load(
            file.startsWith('../') ? file.substring(3) : 'assets/fonts/$file'));
      }
      await loader.load();
    }
  });
  native.main();
}
