#!/usr/bin/env python3
"""Compile exact player artwork and shared slot against cached real Compose/Android APIs.
Feature graph and unrelated glyph/theme are declaration-only facades. No Gradle/device.
"""
from pathlib import Path
from host_probe import directory, gradle_cache, kotlin_plugin, android_jar
import argparse
import os
import subprocess
import zipfile

p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
r=Path(__file__).resolve().parents[1]
main=r/'app/src/main/kotlin/com/soundq/android'
cache=gradle_cache()/'modules-2/files-2.1'
def module(group,name,version):
    paths=list((cache/group/name/version).glob('**/*.jar'))
    assert paths, name
    return paths[0]
jars=[]
for group,name in [('androidx.compose.ui','ui-android'),('androidx.compose.ui','ui-unit-android'),('androidx.compose.ui','ui-geometry-android'),('androidx.compose.ui','ui-graphics-android'),('androidx.compose.runtime','runtime-android'),('androidx.compose.foundation','foundation-android'),('androidx.compose.foundation','foundation-layout-android')]:
    aar=next((cache/group/name/'1.12.1').glob('**/*.aar'))
    destination=a.output/(name+'.jar')
    with zipfile.ZipFile(aar) as archive:destination.write_bytes(archive.read('classes.jar'))
    jars.append(destination)
jars += [android_jar(),module('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),module('com.squareup.okio','okio-jvm','3.18.1')]
http=next((gradle_cache()/'9.7.0/transforms').glob('*/transformed/okhttp-runtime.jar'))
jars.append(http)
for name in ['PlayerArtwork.kt','SelectedPlayerArtwork.kt','TrackArtwork.kt','LibraryArtwork.kt','LibraryRowArtwork.kt']:
    (a.output/name).write_text((main/'product/artwork'/name).read_text())
for name in ['Contracts.kt','AccountSession.kt']:(a.output/name).write_text((main/'data'/name).read_text())
projection=(main/'playback/ControllerProjection.kt').read_text()
start=projection.index('@kotlinx.serialization.Serializable data class QueueOccurrence')
end=projection.index('/** Disposable immutable projection')
declarations=projection[start:end].replace('@kotlinx.serialization.Serializable ','').replace('Player.REPEAT_MODE_OFF','0')
arrangement=(main/'playback/Arrangement.kt').read_text()
identities=arrangement[arrangement.index('@Serializable data class ArrangementIdentity'):arrangement.index('/** No gain')].replace('@Serializable ','')
performance=(main/'playback/TransientPerformance.kt').read_text()
performance=performance[performance.index('@Serializable data class PerformanceTarget'):performance.index('/** Explicit bounded')].replace('@Serializable ','')
(a.output/'Projection.kt').write_text('package com.soundq.android.playback\nimport com.soundq.android.data.*\nimport com.soundq.android.data.timeline.*\nenum class QueueOrigin {Manual, Context, Continuation}\n'+identities+performance+declarations)
for name in ['Timeline.kt','TempoTransition.kt']:
    text=(main/'data/timeline'/name).read_text().replace('import kotlinx.serialization.Serializable\n','').replace('@kotlinx.serialization.Transient ','').replace('@Serializable ','')
    (a.output/name).write_text(text)
owner=(main/'data/timeline/TimelineOwner.kt').read_text()
validate=owner[owner.index('fun validateTimeline('):owner.index('/** Durable draft timing owner.')]
rate=next(line for line in (main/'data/timeline/LinkedPhase.kt').read_text().splitlines() if line.startswith('internal fun TimelineClip.rateOne()'))
owner=owner[owner.index('@Serializable data class TimelineDocument'):owner.index('fun validateTempoDocument')].replace('@Serializable ','')
(a.output/'TimelineDocument.kt').write_text('package com.soundq.android.data.timeline\nclass PhaseLink { fun contains(occurrence:String)=false }\n'+owner+validate+rate)
(a.output/'LibraryCapture.kt').write_text('package com.soundq.android.data.playlists\nimport com.soundq.android.data.*\nclass LibraryTrackCapture internal constructor(internal val scope:AccountScope,val track:Track,internal val lifetime:Long)\n')
api=(main/'data/SoundQApi.kt').read_text();start=api.index('        fun safeMediaUrl(value: String)');end=api.index('\n    }\n}',start)
(a.output/'MediaPolicy.kt').write_text('package com.soundq.android.data\nimport okhttp3.HttpUrl.Companion.toHttpUrlOrNull\nobject SoundQApi {\n'+api[start:end]+'\n}\n')
(a.output/'GraphBoundary.kt').write_text('''package com.soundq.android
import com.soundq.android.data.*
import com.soundq.android.product.artwork.*
internal class AppGraph(val session:AccountSession,val playerArtwork:SelectedPlayerArtwork,val libraryArtwork:LibraryArtwork) {
 fun track(id:TrackId):Track?=error("compile-only graph boundary")
}
''')
slot=(r/'designsystem/src/main/kotlin/com/soundq/designsystem/PlayerComponents.kt').read_text()
start=slot.index('@Composable fun SoundQArtworkSlot(');end=slot.index('\n/** Shared five-control',start)
(a.output/'SlotBoundary.kt').write_text('''package com.soundq.designsystem
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
object SoundQ {val colors:Colors @Composable get()=Colors()}
class Colors {val raised=Color.Black;val muted=Color.Gray}
enum class SoundQIcon {Note}
@Composable fun SoundQIcon(icon:SoundQIcon,contentDescription:String?,tint:Color) {}
'''+slot[start:end])
command=['kotlinc','-jvm-target','17','-J-XX:ActiveProcessorCount=1','-Xplugin='+kotlin_plugin('compose-compiler-plugin.jar'),*[str(x) for x in a.output.glob('*.kt')],'-cp',os.pathsep.join(map(str,jars)),'-d',str(a.output/'ui.jar')]
result=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=dict(os.environ,TMPDIR=str(a.output.resolve())))
(a.output/'compile.log').write_text(result.stdout)
print(result.stdout,end='')
if result.returncode:raise SystemExit(result.returncode)
print('Compiled exact player artwork and actual shared SoundQArtworkSlot with Compose compiler. No native execution claimed.')
