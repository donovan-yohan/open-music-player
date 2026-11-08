#!/usr/bin/env python3
"""Compile the real TimelineLane preparation and waveform draw against a paint sink.

Only Compose's remember and draw primitives are facades. Production source mapping,
window selection, projection and both consuming lane blocks are extracted verbatim.
This is host consuming-path proof, not Android raster or gesture execution.
"""
import argparse
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--generate',required=True,type=Path)
p.add_argument('--lane',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
source=(a.lane or root/'app/src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt').read_text()
start=source.index('    val sourceStart=shown.sourceAt(')
end=source.index('    // Fixed complete row:',start) if '    // Fixed complete row:' in source[start:] else source.index('    Column(Modifier.fillMaxWidth()',start)
prepare=source[start:end]
start=source.index('                    // Cached min/max vertex path;') if '// Cached min/max vertex path;' in source else source.index('                    // Cached signed spectral columns;')
end=source.index('                    if(latestSelected&&',start)
draw=source[start:end]
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'TimelineLanePaintProbe.kt').write_text('''package com.soundq.android.product.timeline
import com.soundq.android.data.timeline.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import com.soundq.android.product.timeline.ProbePath as Path

import kotlin.math.*
private fun <T> remember(vararg keys:Any?, block:()->T):T=block()
internal data class ProbeColors(val waveform:Color)
internal fun probeLanePaint(shown:TimelineClip,v:TimelineViewport,wave:TrackWaveform?,window:(TrackWaveform,Long,Long,Int)->PeakWindow,colors:ProbeColors,sink:DrawScope) {
'''+prepare+'''
    with(sink) {
'''+draw+'''
    }
}
''')
phase_start=source.index('                    // Linked tick and guide consuming paint,')
phase_end=source.index('                    // End linked consuming paint.',phase_start)
phase_draw=source[phase_start:phase_end]
if '// Shared linked guide consuming paint.' in source:
    guide_start=source.index('        link?.let {',source.index('// Shared linked guide consuming paint.'))
    guide_end=source.index('        // End shared linked guide consuming paint.',guide_start)
    phase_draw+='\n'+source[guide_start:guide_end]
(a.generate/'LinkedLanePaintProbe.kt').write_text("""package com.soundq.android.product.timeline
import com.soundq.android.data.timeline.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.luminance
import com.soundq.designsystem.appearanceColors
import soundq.design.generated.SoundQAppearance
import soundq.design.generated.SoundQSpectralTokens as S
internal data class PhasePaintMark(val color:Color,val from:Offset,val to:Offset,val width:Float,val dashed:Boolean)
internal class PhaseDrawScope {
 val size=androidx.compose.ui.geometry.Size(400f,100f)
 val marks=mutableListOf<PhasePaintMark>()
 fun androidx.compose.ui.unit.Dp.toPx()=value
 fun drawLine(color:Color,start:Offset,end:Offset,strokeWidth:Float,pathEffect:androidx.compose.ui.graphics.PathEffect?=null){marks+=PhasePaintMark(color,start,end,strokeWidth,pathEffect!=null)}
}
internal fun probePhaseLanePaint(ticks:List<PhaseTick>,link:PhaseLink?,guide:Long?,v:TimelineViewport,phaseIsPreview:Boolean,sink:PhaseDrawScope) {
 val colors=appearanceColors(SoundQAppearance.Dark,false)
 val occlusions=emptyList<androidx.compose.ui.geometry.Rect>()
 with(sink) {
"""+phase_draw+"""
 }
}
""")
print('Extracted production TimelineLane preparation, spectrum and linked guide consuming draw',a.generate)
