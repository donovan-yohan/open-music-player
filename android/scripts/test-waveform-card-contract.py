#!/usr/bin/env python3
"""Source-adoption guard, not mounted paint or native gesture evidence."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
LANE=ROOT/'app/src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt'
class WaveformCardContract(unittest.TestCase):
    def test_normal_plot_gains_height_without_a_reserved_header(self):
        source=LANE.read_text()
        self.assertIn('bodyHeight:Dp=125.dp',source)
        self.assertIn('waveformPlotBacking(colors)',source)
        self.assertNotIn('.background(S.W10_SPECTRUM_DECK)',source)
    def test_only_disclosure_and_more_exclude_body_contacts(self):
        source=LANE.read_text()
        self.assertIn('disclosureBounds?.contains(down.position)',source)
        self.assertNotIn('bpmBounds',source)
        self.assertNotIn('WaveformBpmButton(',source)
    def test_more_opens_anchored_menu_before_real_editor(self):
        source=LANE.read_text()
        self.assertIn('DropdownMenu(showMore',source)
        self.assertIn('Text("Set BPM")',source)
        self.assertNotIn('SoundQSheet("Clip $laneNumber"',source)
        self.assertNotIn('val label="$laneNumber',source)
if __name__=='__main__': unittest.main(verbosity=2)
