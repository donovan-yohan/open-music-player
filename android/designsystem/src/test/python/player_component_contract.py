#!/usr/bin/env python3
"""Dependency-free source contract only. Not a mounted geometry/behavior test."""
from pathlib import Path
import hashlib
import unittest

ROOT = Path(__file__).resolve().parents[4]
MAIN = ROOT / 'designsystem/src/main/kotlin/com/soundq/designsystem'

class PlayerSourceContract(unittest.TestCase):
    def test_media_geometry_has_explicit_fixed_height_and_no_visible_current(self):
        source = (MAIN / 'ProductComponents.kt').read_text()
        media = source.split('@Composable fun SoundQMediaRow(', 1)[1].split('/** Shared in compact', 1)[0]
        self.assertIn('.height(72.dp)', media)
        self.assertIn('SoundQArtworkSlot', media)
        self.assertNotIn('Text("Current"', media)
        self.assertIn('stateDescription="Current track"', media)
        self.assertIn('softWrap=false', media)

    def test_generated_icon_bytes_remain_frozen(self):
        frozen = ROOT / 'design-input/queue-r1/generated/SoundQIcons.kt'
        actual = ROOT / 'designsystem/src/generated/kotlin/soundq/design/generated/SoundQIcons.kt'
        self.assertEqual(hashlib.sha256(frozen.read_bytes()).digest(), hashlib.sha256(actual.read_bytes()).digest())

if __name__ == '__main__':
    unittest.main(verbosity=2)
