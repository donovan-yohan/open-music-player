#!/usr/bin/env python3
"""Source-bound consuming seam regression, not rendered/native acceptance."""
from pathlib import Path
import unittest, os
ROOT=Path(os.environ.get("SOUNDQ_SOURCE_ROOT",Path(__file__).resolve().parents[1]))
P=ROOT/'app/src/main/kotlin/com/soundq/android/product'
D=ROOT/'designsystem/src/main/kotlin/com/soundq/designsystem'
class ListeningInformationContract(unittest.TestCase):
    def test_shared_compact_consumes_clock_and_nonseekable_progress(self):
        s=(D/'ProductComponents.kt').read_text().split('@Composable fun SoundQCompactPlayer',1)[1].split('/** A single shared edge',1)[0]
        self.assertIn('timing:CompactSongTiming',s)
        self.assertIn('ProgressBarRangeInfo(',s)
        self.assertIn('timing.clockText',s)
        self.assertNotIn('Slider(',s)
        self.assertNotIn('LaunchedEffect',s)
    def test_all_actual_compact_callers_supply_projection(self):
        for path,n in [('ProductApp.kt',2),('QueuePanel.kt',1)]:
            s=(P/path).read_text()
            self.assertEqual(n,s.count('timing=compactSongTiming(playback)'))
    def test_queue_and_all_playlist_duration_supply_survives_shared_owner(self):
        self.assertIn('item.durationMs',(P/'QueuePanel.kt').read_text())
        self.assertIn('slot(row)',(D/'OccurrenceQueue.kt').read_text())
        self.assertIn('durationMs:Long',(D/'OccurrenceQueue.kt').read_text())
        s=(P/'playlists/PlaylistDetailScreen.kt').read_text()
        self.assertEqual(2,s.count('memberDurationMetadata(track.durationMs)'))
        self.assertIn('it.durationMs',s)
        self.assertIn('memberDurationMetadata(row.durationMs)',(P/'playlists/PlaylistMemberOrderList.kt').read_text())
if __name__=='__main__': unittest.main()
