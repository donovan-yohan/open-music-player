"""Fast source adoption gates; mounted Compose motion tests remain a separate gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[4]
DESIGN = ROOT / "android/designsystem/src/main/kotlin/com/soundq/designsystem"
PRODUCT = ROOT / "android/app/src/main/kotlin/com/soundq/android/product"


class SelectedSongMarqueeCallers(unittest.TestCase):
    def test_both_row_branches_and_compact_player_use_shared_identity_text(self):
        source = (DESIGN / "ProductComponents.kt").read_text()
        self.assertEqual(source.count("SoundQMediaIdentityText("), 5)
        self.assertIn('selected=timing.selected', source)
        self.assertIn('LocalMediaMarqueeIdentity.current', source)

    def test_native_motion_has_explicit_accessibility_and_timing_policy(self):
        source = (DESIGN / "MediaIdentityText.kt").read_text()
        for contract in ['basicMarquee(', 'MotionDurationScale', 'scaleFactor',
                         'SoundQ.motion.reduced', 'clipToBounds()',
                         'initialDelayMillis=2000', 'repeatDelayMillis=2000',
                         'velocity=24.dp', 'iterations=Int.MAX_VALUE',
                         'TextOverflow.Ellipsis', 'key(identity,text,selected,motionAllowed']:
            self.assertIn(contract, source)
        self.assertNotIn('delay(', source)
        self.assertNotIn('LaunchedEffect', source)

    def test_playlist_all_three_branches_use_one_projection(self):
        source = (PRODUCT / "playlists/PlaylistDetailScreen.kt").read_text()
        self.assertIn('playback:PlaybackProjection', source)
        self.assertIn('playback.source==PlaybackSource.Queue', source)
        self.assertIn('it.occurrenceId==playback.selectedOccurrence', source)
        self.assertEqual(source.count('selectedTrack==track.id.value'), 2)
        self.assertIn('it.artist,selectedTrack==it.id.value', source)
        self.assertNotIn('track.title,track.artist,false', source)
        app = (PRODUCT / 'ProductApp.kt').read_text()
        self.assertIn('playback=playback', app)

    def test_downloaded_fallback_and_shared_source_reset_are_wired(self):
        source = (PRODUCT / "ProductApp.kt").read_text()
        fallback = source[source.index('if(index<0)'):source.index('val mutation=library.mutations')]
        self.assertIn('playback.source==', fallback)
        self.assertIn('it.occurrenceId==playback.selectedOccurrence&&it.trackId==track.id.value', fallback)
        self.assertNotIn('track.title,track.artist,false', fallback)
        self.assertIn('LocalMediaMarqueeIdentity provides', source)
        identity = source[source.index('LocalMediaMarqueeIdentity provides'):source.index('AppearanceSystemBars(')]
        self.assertIn('playback.selectionIncarnation', identity)
        self.assertIn('playback.sourceQueueIncarnation', identity)
        self.assertIn('playback.selectedOccurrence', identity)
        self.assertNotIn('positionMs', identity)

    def test_unauthoritative_candidates_remain_static(self):
        for name in ['catalog/CatalogScreen.kt', 'discovery/DiscoverScreen.kt',
                     'playlists/HarmonicDiscovery.kt', 'jam/JamHostPanel.kt']:
            with self.subTest(name=name):
                self.assertIn('false,', (PRODUCT / name).read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
