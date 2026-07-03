import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Sound Q theme locks the orange-on-black brand contract', () {
    final theme = AppTheme.darkTheme;

    expect(AppTheme.brandName, 'Sound Q');
    expect(AppTheme.brandGlyph, '三九');
    expect(theme.scaffoldBackgroundColor, AppTheme.inkBlack);
    expect(theme.colorScheme.primary, AppTheme.brandColor);
    expect(theme.textTheme.labelLarge?.color, AppTheme.brandColor);
    expect(theme.dividerColor, AppTheme.divider);
  });

  test('light theme intentionally maps to Sound Q dark direction', () {
    final lightTheme = AppTheme.lightTheme;

    expect(lightTheme.brightness, AppTheme.darkTheme.brightness);
    expect(lightTheme.scaffoldBackgroundColor, AppTheme.darkBackground);
    expect(lightTheme.colorScheme.primary, AppTheme.brandColor);
  });

  test('brand logo asset is bundled for auth and splash screens', () async {
    final logo = await rootBundle.load(AppTheme.brandLogoAsset);

    expect(logo.lengthInBytes, greaterThan(0));
  });
}
