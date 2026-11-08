#!/usr/bin/env python3
"""Source contract gate only; not mounted Compose/raster acceptance."""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--lane',type=Path);a=p.parse_args()
r=Path(__file__).resolve().parents[1]
s=(a.lane or r/'app/src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt').read_text()
panel=s[s.index('@Composable internal fun TimelinePanel'):s.index('@Composable private fun TimelineRuler')]
lane=s[s.index('@Composable internal fun TimelineLane'):s.index('@Composable private fun TimingInspector')]
assert 'Arrangement draft' not in panel,'Primary surface still begins with editorial/debug copy'
assert 'modifier:Modifier=Modifier' in panel.split('{')[0], 'Append optional Modifier for bounded parent'
assert 'SEMANTIC_DIMENSION_APP_MAX' not in panel and 'COMPONENT_ARRANGEMENT_LANE_GAP' not in panel
assert 'LazyColumn(Modifier.fillMaxWidth().weight(1f)' in panel,'Lane list must consume bounded remaining viewport'
assert 'readKey' in panel and 'readAdmission' in panel and 'latestAdmission' not in panel
assert 'loadWaveform' in panel and 'runCatching {if(scope' not in panel
assert 'if(showMore)SoundQSheet' in lane and 'if(selected)TimingInspector' not in lane
assert '.height(bodyHeight)' in lane and '.height(48.dp)' in lane
assert 'BoxWithConstraints' not in panel and 'bodyHeight=bodyHeight' not in panel,'Rows must not grow to fill the screen'
assert 'TimelineGuides(' in panel and 'Shared timeline playhead' in s
assert 'Loading waveform' not in panel,'Loading belongs inside reserved lane body'
assert 'soundq.design.generated' in s and 'projectSpectralWaveform(peaks,shown,v)' in lane
assert 'for(column in paint.columns)' in lane and 'waveSelection' not in lane,'Selection must not recolor samples'
print('PASS bounded workspace / contextual controls / readiness effect wiring source contracts (not mounted UI)')
