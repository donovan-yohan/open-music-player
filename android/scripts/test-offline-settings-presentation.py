#!/usr/bin/env python3
"""Source-composition gates, not mounted visual or device acceptance."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
PRODUCT=ROOT/'app/src/main/kotlin/com/soundq/android/product'
class OfflineSettingsPresentationTest(unittest.TestCase):
    def test_settings_choices_cancel_only_their_own_inset(self):
        source=(PRODUCT/'preferences/PreferencesScreen.kt').read_text()
        self.assertIn('internal fun SettingsChoices(',source)
        self.assertIn('requiredWidth(maxWidth+SoundQ.spacing.gutter*2)',source)
        self.assertIn('Column(Modifier.fillMaxWidth().selectableGroup())',source)
        self.assertIn('SettingsChoices {\n        for(mode in',source)
        self.assertIn('SettingsChoices {\n        SoundQRow("Temporary audio"',source)
        self.assertIn('SettingsChoices {\n        SoundQRow("Device unlock"',source)
        self.assertGreaterEqual(source.count('role=Role.RadioButton'),3)
    def test_copy_keeps_consequences_but_moves_diagnostics_into_details(self):
        source=(PRODUCT/'preferences/PreferencesScreen.kt').read_text()
        self.assertIn('"Downloads are kept"',source)
        self.assertIn('"Refresh"',source)
        self.assertIn('"Storage details"',source)
        self.assertIn('In-use files are removed only after playback releases them.',source)
        self.assertIn('Crossfade is unavailable',source)
        self.assertIn('Account deletion is not available',source)
        self.assertNotIn('Local device unlock protects this installed session.',source)
        self.assertNotIn('Read cache status again',source)
    def test_download_rows_keep_duration_and_full_details(self):
        source=(PRODUCT/'offline/DownloadsScreen.kt').read_text()
        self.assertIn('memberDurationMetadata(row.track.durationMs)',source)
        self.assertIn('metadata={',source)
        self.assertIn('downloadStatus(row)',source)
        self.assertIn('downloadStatus(row,compact=false)',source)
        self.assertIn('DownloadStatus.Complete',source)
        self.assertIn('queueEnabled',source)
if __name__=='__main__':unittest.main()
