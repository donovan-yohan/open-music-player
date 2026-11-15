#!/usr/bin/env python3
"""Source-bound consuming seam regression, not rendered/native acceptance."""
from pathlib import Path
import unittest, os, re
ROOT=Path(os.environ.get("SOUNDQ_SOURCE_ROOT",Path(__file__).resolve().parents[1]))
P=ROOT/'app/src/main/kotlin/com/soundq/android/product'
D=ROOT/'designsystem/src/main/kotlin/com/soundq/designsystem'


def compact_player_arguments(source):
    # Keep offsets, but ignore delimiters/call-shaped text in comments and strings.
    code=re.sub(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"',
                lambda m:' '*len(m[0]),source,flags=re.S)
    calls=[]
    for match in re.finditer(r'\bSoundQCompactPlayer\s*\(',code):
        stack=[')'];start=match.end();arguments=[]
        for i in range(start,len(code)):
            char=code[i]
            if char in '({[':stack.append({'(':')','{':'}','[':']'}[char])
            elif char in ')}]':
                assert stack and char==stack.pop(), 'Unbalanced compact player call'
                if not stack:
                    arguments.append(source[start:i].strip());break
            elif char==',' and len(stack)==1:
                arguments.append(source[start:i].strip());start=i+1
        else:raise AssertionError('Unclosed compact player call')
        calls.append(arguments)
    return calls


class ListeningInformationContract(unittest.TestCase):
    def test_shared_compact_consumes_clock_and_nonseekable_progress(self):
        s=(D/'ProductComponents.kt').read_text().split('@Composable fun SoundQCompactPlayer',1)[1].split('/** A single shared edge',1)[0]
        self.assertIn('timing:CompactSongTiming',s)
        self.assertIn('ProgressBarRangeInfo(',s)
        self.assertIn('timing.clockText',s)
        self.assertNotIn('Slider(',s)
        self.assertNotIn('LaunchedEffect',s)
    def test_all_actual_compact_callers_supply_projection(self):
        # The shell and Queue panel each construct one real shared compact player.
        # Inspect its top-level arguments, not unused projections elsewhere in a file.
        for path,empty in [('ProductApp.kt','Nothing playing'),('QueuePanel.kt','Queue empty')]:
            with self.subTest(caller=path):
                calls=compact_player_arguments((P/path).read_text())
                self.assertEqual(len(calls),1,'missing or duplicated compact player consumer')
                arguments=calls[0]
                self.assertEqual(arguments[:3],[f'playback.title ?: "{empty}"','playback.artist','playback.isPlaying'])
                timing=[arg for arg in arguments if re.match(r'timing\s*=',arg)]
                self.assertEqual(timing,['timing=compactSongTiming(playback)'],
                                 'the displayed player must consume its own playback timing projection')
    def test_queue_and_all_playlist_duration_supply_survives_shared_owner(self):
        self.assertIn('item.durationMs',(P/'QueuePanel.kt').read_text())
        self.assertIn('slot(row)',(D/'OccurrenceQueue.kt').read_text())
        self.assertIn('durationMs:Long',(D/'OccurrenceQueue.kt').read_text())
        s=(P/'playlists/PlaylistDetailScreen.kt').read_text()
        self.assertEqual(2,s.count('memberDurationMetadata(track.durationMs)'))
        self.assertIn('it.durationMs',s)
        self.assertIn('memberDurationMetadata(row.durationMs)',(P/'playlists/PlaylistMemberOrderList.kt').read_text())
if __name__=='__main__': unittest.main()
