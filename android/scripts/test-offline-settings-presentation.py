#!/usr/bin/env python3
"""Source-composition gates, not mounted visual or device acceptance."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
PRODUCT=ROOT/'app/src/main/kotlin/com/soundq/android/product'
DESIGN=ROOT/'designsystem/src/main/kotlin/com/soundq/designsystem'
class OfflineSettingsPresentationTest(unittest.TestCase):
    def test_settings_rows_own_one_gutter_without_width_compensation(self):
        settings=''.join((PRODUCT/'preferences'/name).read_text() for name in ('PreferencesScreen.kt','AppearanceSetting.kt','CrossfadeSetting.kt','DjModeSetting.kt'))
        self.assertNotIn('requiredWidth',settings)
        self.assertNotIn('SettingsChoices',settings)
        self.assertNotIn('SoundQRow(',settings)
        self.assertGreaterEqual(settings.count('selectableGroup()'),5)
        rows=(DESIGN/'SettingsComponents.kt').read_text()
        self.assertIn('padding(horizontal = SoundQSettingsMetrics.gutter, vertical = SoundQ.spacing.medium)',rows)
        self.assertIn('Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scrollState))',rows)
    def test_copy_is_literal_without_disclaimers(self):
        source=(PRODUCT/'preferences/PreferencesScreen.kt').read_text()
        self.assertIn('"Clear temporary audio?"',source)
        self.assertIn('"Downloads and artwork stay on this device."',source)
        self.assertIn('"Storage details"',source)
        self.assertIn('"Refresh"',source)
        for retired in ('Account deletion is not available','Other DJ controls are unavailable','Less crossfade','Back to Settings','Unknown files were preserved'):
            self.assertNotIn(retired,source)
    def test_download_rows_keep_duration_and_full_details(self):
        source=(PRODUCT/'offline/DownloadsScreen.kt').read_text()
        self.assertIn('memberDurationMetadata(row.track.durationMs)',source)
        self.assertIn('metadata={',source)
        self.assertIn('downloadStatus(row)',source)
        self.assertIn('downloadStatus(row,compact=false)',source)
        self.assertIn('DownloadStatus.Complete',source)
        self.assertIn('queueEnabled',source)
if __name__=='__main__':unittest.main()
