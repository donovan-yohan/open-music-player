#!/usr/bin/env python3
"""Guard the established native media-row owner and its actual list callers."""
from pathlib import Path
import unittest
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
PRODUCT = ROOT / 'android/app/src/main/kotlin/com/soundq/android/product'
DESIGN = ROOT / 'android/designsystem/src/main/kotlin/com/soundq/designsystem'


class SharedMediaContract(unittest.TestCase):
    def test_home_uses_media_row_not_generic_row(self):
        source = (PRODUCT / 'home/HomeScreens.kt').read_text()
        self.assertIn('SoundQMediaRow(', source)
        self.assertNotIn('SoundQRow(', source)
        self.assertIn('TrackArtwork(', source)
        self.assertNotIn('contentPadding=PaddingValues(SoundQ.spacing.gutter)', source)
        self.assertNotIn('verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)', source)

    def test_arrangement_queue_has_real_occurrence_list(self):
        source = (PRODUCT / 'QueuePanel.kt').read_text()
        self.assertNotIn('else if(mixed)Text("Arrangement"', source)
        self.assertIn('ArrangementQueueList(', source)
        self.assertIn('artwork=', source)

    def test_queue_forwards_occurrence_artwork_into_shared_row(self):
        source = (DESIGN / 'OccurrenceQueue.kt').read_text()
        self.assertIn('artwork:@Composable (String)->Unit', source)
        self.assertIn('artwork={artwork(row.occurrence)}', source)
        self.assertIn('SoundQMediaRow(', source)

    def test_harmonic_song_results_share_media_anatomy(self):
        source=(PRODUCT / 'playlists/HarmonicDiscovery.kt').read_text()
        self.assertIn('SoundQMediaRow(row.title,',source)
        self.assertNotIn('SoundQRow(row.title,',source)

    def test_song_rows_do_not_rebuild_generic_rows(self):
        for name in ['home/HomeScreens.kt', 'playlists/PlaylistDetailScreen.kt', 'playlists/PlaylistMemberOrderList.kt', 'offline/DownloadsScreen.kt']:
            source = (PRODUCT / name).read_text()
            with self.subTest(name=name):
                self.assertNotIn('SoundQRow(', source)
                self.assertIn('SoundQMediaRow(', source)


if __name__ == '__main__':
    specification=importlib.util.spec_from_file_location('row_callers',Path(__file__).with_name('test-shared-media-row-callers.py'))
    assert specification is not None and specification.loader is not None
    module=importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(SharedMediaContract),unittest.defaultTestLoader.loadTestsFromModule(module)])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
