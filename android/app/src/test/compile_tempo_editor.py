#!/usr/bin/env python3
"""Compile the integrated editor with real cached Compose and real repository/session types."""
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import scratch_root, gradle_cache, kotlin_plugin, android_jar
import subprocess
import tempfile
import zipfile
root=Path(__file__).resolve().parents[3]
cache=gradle_cache() / 'modules-2/files-2.1'
scratch=scratch_root()
def jar(group,name,version):return next((cache/group/name/version).glob('**/*.jar'))
with tempfile.TemporaryDirectory(prefix='tempo-editor-',dir=scratch) as directory:
    out=Path(directory);cp=[]
    for group,names,version in [
        ('androidx.compose.ui',['ui-android','ui-unit-android','ui-geometry-android','ui-graphics-android','ui-text-android','ui-util-android'],'1.12.1'),
        ('androidx.compose.runtime',['runtime-android','runtime-saveable-android'],'1.12.1'),
        ('androidx.compose.foundation',['foundation-android','foundation-layout-android'],'1.12.1'),
        ('androidx.compose.animation',['animation-android','animation-core-android'],'1.12.1'),
        ('androidx.compose.material3',['material3-android'],'1.4.0')]:
        for name in names:
            aar=next((cache/group/name/version).glob('**/*.aar'))
            target=out/(name+'.jar')
            with zipfile.ZipFile(aar) as z:target.write_bytes(z.read('classes.jar'))
            cp.append(target)
    cp += [android_jar(),root/'designsystem/build/intermediates/compile_library_classes_jar/debug/bundleLibCompileToJarDebug/classes.jar',jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),jar('com.squareup.okhttp3','okhttp','4.12.0'),next((cache/'com.squareup.okio/okio-jvm').glob('**/*.jar'))]
    main=root/'app/src/main/kotlin/com/soundq/android'
    sources=[main/'data/timeline'/x for x in ['Timeline.kt','TimelineOwner.kt','TimelineGeometry.kt','LinkedPhase.kt','TempoTransition.kt','Waveform.kt','TimelineRepository.kt']]
    sources += [main/'data'/x for x in ['Contracts.kt','AccountSession.kt']]
    sources += [main/'product/timeline'/x for x in ['TempoTransitionControls.kt','TempoTransitionEditor.kt','WaveformBpmControls.kt']]
    tests=[root/'app/src/test/kotlin/com/soundq/android/product/timeline/TempoEditorIntegrationTest.kt',root/'app/src/test/kotlin/com/soundq/android/data/timeline/TempoRepositoryIntegrationTest.kt']
    sources += [p for p in tests if p.exists()]
    sources += [root/'app/src/test/kotlin/com/soundq/android/product/timeline/WaveformBpmTraceTest.kt']
    (out/'ExportBoundary.kt').write_text('''package com.soundq.android.data
import com.soundq.android.data.mix.SavedMix
class SoundQApi(val session:AccountSession) {
    fun saveMix(scope:AccountScope,prior:SavedMix?,name:String,clips:List<String>,valid:()->Boolean):SavedMix=error("Export must not dispatch")
    fun mixPlan(scope:AccountScope,id:String,valid:()->Boolean):SavedMix=error("Export must not read")
}
''')
    (out/'MixBoundary.kt').write_text('''package com.soundq.android.data.mix
data class SavedMix(val clips:List<String> = emptyList())
''')
    (out/'PlanBoundary.kt').write_text('''package com.soundq.android.playback
import com.soundq.android.data.timeline.TimelineDocument
import com.soundq.android.data.mix.SavedMix
fun TimelineDocument.arrangementPlan(name:String):SavedMix=error("Ramp export must not serialize")
fun TimelineDocument.matchesArrangement(plan:SavedMix):Boolean=error("Ramp export must not compare")
''')
    sources += [main/'data/timeline/ArrangementSave.kt',out/'ExportBoundary.kt',out/'MixBoundary.kt',out/'PlanBoundary.kt',root/'app/src/test/kotlin/com/soundq/android/data/timeline/TempoExportGuardTest.kt']
    import sys
    if '--spectral' in sys.argv:
        sources += [main/'product/timeline/SpectralRateProjection.kt',root/'app/src/test/kotlin/com/soundq/android/product/timeline/TempoSpectralMapTest.kt']
    if '--panel' in sys.argv:
        for group,names,version in [
            ('androidx.lifecycle',['lifecycle-runtime-compose-android','lifecycle-runtime-android'],'2.11.0'),
            ('androidx.activity',['activity-compose','activity'],'1.13.0')]:
            for name in names:
                aar=next((cache/group/name/version).glob('**/*.aar'));target=out/(name+'.jar')
                with zipfile.ZipFile(aar) as z:target.write_bytes(z.read('classes.jar'))
                cp.append(target)
        cp.append(jar('androidx.lifecycle','lifecycle-common-jvm','2.11.0'))
        (out/'PanelModelBoundary.kt').write_text('''package com.soundq.android.product
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import kotlinx.coroutines.flow.MutableStateFlow
class Graph(val session:AccountSession,val timeline:TimelineRepository)
class ProductViewModel(val graph:Graph,val controller:ControllerProjection) {
 val timeline get()=graph.timeline.state
 val playback=MutableStateFlow(PlaybackProjection())
}
''')
        (out/'PanelTransportBoundary.kt').write_text('''package com.soundq.android.playback
import com.soundq.android.data.timeline.*
data class Identity(val revision:Long=0)
data class Accepted(val identity:Identity,val document:TimelineDocument)
enum class LiveSyncState {Off,Rejoining}
data class Deck(val syncReferenceOccurrence:String?=null,val syncState:LiveSyncState=LiveSyncState.Off,val ready:Boolean=false,val rate:Double=1.0,val effectiveBpm:Double?=null,val playing:Boolean=false,val scratching:Boolean=false,val sourcePositionMs:Double=0.0)
data class Occurrence(val occurrenceId:String,val trackId:Long)
data class PlaybackProjection(val queue:List<Occurrence> = emptyList(),val selectedOccurrence:String?=null,val arrangement:Accepted?=null,val positionMs:Long=0,val accountEpoch:Long=0,val performanceDecks:Map<String,Deck> = emptyMap(),val canPerformArrangement:Boolean=false)
fun PlaybackProjection.timelineSources():List<TimelineSource>?=error("Transport read boundary")
class ControllerProjection {
 fun pause():Unit=error("Transport pause boundary")
 fun seekArrangement(id:Identity,ms:Long):Unit=error("Transport seek boundary")
 fun seekOccurrence(id:String,ms:Long):Unit=error("Transport source seek boundary")
}
''')
        (out/'PanelScratchBoundary.kt').write_text('''package com.soundq.android.product.timeline
import com.soundq.android.playback.*
class LiveScratchContact(controller:ControllerProjection,id:Identity,occurrence:String,valid:()->Boolean) {
 fun retire():Unit=error("Scratch boundary")
 fun begin(time:Long):Boolean=error("Scratch boundary")
 fun move(rate:Double,time:Long):Unit=error("Scratch boundary")
 fun finish(time:Long,cancel:Boolean):Unit=error("Scratch boundary")
}
''')
        (out/'PanelAdvancedBoundary.kt').write_text('''package com.soundq.android.product.timeline
import androidx.compose.runtime.Composable
import com.soundq.android.product.ProductViewModel
import com.soundq.android.data.timeline.*
@Composable fun TimelineFadeControls(model:ProductViewModel,document:TimelineDocument,valid:()->Boolean,setBusy:(Boolean)->Unit,busy:Boolean):Unit=error("Gain feature boundary")
@Composable fun LiveSyncControls(model:ProductViewModel,waves:Map<Long,TrackWaveform>,valid:()->Boolean):Unit=error("Advanced feature boundary")
@Composable fun LinkedPhaseControls(document:TimelineDocument,waves:Map<Long,TrackWaveform>,busy:Boolean,undo:Boolean,valid:()->Boolean,preview:(PhaseEdit)->EditDecision,commit:(PhaseEdit)->Boolean,commitEdit:(TimelineEdit)->Boolean,unlock:(Long)->Boolean,onUndo:()->Boolean,movement:TimelineEdit?,clear:()->Unit,onPreview:(TimelineDocument?)->Unit,setBusy:(Boolean)->Unit):Unit=error("Advanced feature boundary")
''')
        if '--visual-timing' in sys.argv:
            transport=(out/'PanelTransportBoundary.kt').read_text().replace('enum class LiveSyncState {Off,Rejoining}','enum class LiveSyncState {Off,Pending,Locked,Rejoining,ScratchSuspended,Failed}').replace('val syncState:LiveSyncState=LiveSyncState.Off,','val syncState:LiveSyncState=LiveSyncState.Off,val syncBeats:Int=1,')
            transport=transport.replace('class ControllerProjection {','''data class QualifiedLiveGrid(val bpm:Double,val anchorMs:Double,val groupOriginMs:Double?,val sourceKey:String,val revision:String,val provenance:String="local_manual") {
 fun valid(durationMs:Long,beats:Int):Boolean=error("Live validation boundary")
}
class ControllerProjection {
 fun syncIncoming(id:Identity,a:String,b:String,beats:Int,ga:QualifiedLiveGrid,gb:QualifiedLiveGrid,done:(Boolean)->Unit):Unit=error("Live sync boundary")
 fun unlinkIncoming(id:Identity,b:String,done:(Boolean)->Unit):Unit=error("Live unlink boundary")''')
            (out/'PanelTransportBoundary.kt').write_text(transport)
            sources += [main/'product/timeline'/x for x in ['LinkedPhaseControls.kt','LiveSyncControls.kt','TimelineFadeControls.kt']]
        else:
            sources += [out/'PanelAdvancedBoundary.kt']
        sources += [out/'PanelModelBoundary.kt',out/'PanelTransportBoundary.kt',out/'PanelScratchBoundary.kt']
        sources += [main/'product/timeline'/x for x in ['StackedTimeline.kt','SourceMarkerPicker.kt','TimelinePlacementPicker.kt','VisualTimingMapping.kt','WaveformLoad.kt','WaveformOverview.kt','WaveformScratch.kt','VinylStroke.kt','ArrangementLifetime.kt','SpectralWaveformPaint.kt','SpectralRateProjection.kt']]
        sources += [main/'data/timeline/TimelineGesture.kt']
    sources=list(dict.fromkeys(sources))
    env=dict(os.environ,TMPDIR=str(out))
    subprocess.run(['kotlinc','-J-XX:ActiveProcessorCount=1','-jvm-target','17','-Xplugin='+kotlin_plugin('compose-compiler-plugin.jar'),'-Xplugin='+kotlin_plugin('kotlinx-serialization-compiler-plugin.jar'),*map(str,sources),'-cp',os.pathsep.join(map(str,cp)),'-d',str(out/'editor.jar')],check=True,env=env)
    if all(p.exists() for p in tests):
        subprocess.run(['kotlin','-J-XX:ActiveProcessorCount=1','-cp',str(out/'editor.jar')+os.pathsep+os.pathsep.join(map(str,cp)),'org.junit.runner.JUnitCore','com.soundq.android.product.timeline.TempoEditorIntegrationTest','com.soundq.android.data.timeline.TempoRepositoryIntegrationTest','com.soundq.android.data.timeline.TempoExportGuardTest','com.soundq.android.product.timeline.WaveformBpmTraceTest'],check=True,env=env)
    if '--spectral' in sys.argv:
        subprocess.run(['kotlin','-J-XX:ActiveProcessorCount=1','-cp',str(out/'editor.jar')+os.pathsep+os.pathsep.join(map(str,cp)),'org.junit.runner.JUnitCore','com.soundq.android.product.timeline.TempoSpectralMapTest'],check=True,env=env)
    print('Integrated editor, real repository/session, controls and serialization compiled. No mounted UI or audio claim.')
