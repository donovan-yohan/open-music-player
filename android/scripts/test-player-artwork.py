#!/usr/bin/env python3
"""Standalone selected-player artwork test. No Gradle, device or shared build outputs.
Runs exact loader/session/policy source using real OkHttp HTTPS. BitmapFactory is a
hardware-only ImageIO bounds/sample facade, not Android decode or Compose paint.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import re

p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--loader-source', type=Path)
p.add_argument('--presentation-source', type=Path)
p.add_argument('--designsystem-root',type=Path)
p.add_argument('--graph-source',type=Path)
p.add_argument('--library-loader-source',type=Path)
p.add_argument('--shared-only',action='store_true')
p.add_argument('--library-binding-source',type=Path)
p.add_argument('--phone-source',type=Path)
p.add_argument('--lookahead-only',action='store_true')
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
r = Path(__file__).resolve().parents[1]
main = r / 'app/src/main/kotlin/com/soundq/android'
source = a.loader_source or main / 'product/artwork/SelectedPlayerArtwork.kt'
assert source.exists(), 'Selected-player artwork capability is absent (API discovery RED, not behavioral RED)'
cache = Path.home() / '.gradle/caches'
modules = cache / 'modules-2/files-2.1'
def jar(group, artifact, version):
    candidates = list((modules / group / artifact / version).glob('**/*.jar'))
    assert candidates, f'Missing cached {artifact} {version}'
    return candidates[0]
# OkHttp 5 is an Android AAR in this checkout. Use its exact cached runtime jar.
http = list((cache / '9.7.0/transforms').glob('*/transformed/okhttp-runtime.jar'))
assert len(http) == 1, f'Expected one cached OkHttp Android runtime, got {len(http)}'
jars = [http[0], jar('com.squareup.okio', 'okio-jvm', '3.18.1'),
        jar('com.squareup.okhttp3', 'okhttp-tls', '5.5.1'),
        jar('com.squareup.okhttp3', 'mockwebserver3', '5.5.1'),
        jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.10.2'),
        jar('junit', 'junit', '4.13.2'), jar('org.hamcrest', 'hamcrest-core', '1.3'),
        jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.12.0'),
        jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.12.0')]
cp = os.pathsep.join(map(str, jars))
inputs = [source, main / 'product/artwork/LibraryArtwork.kt', main / 'data/Contracts.kt', main / 'data/AccountSession.kt',
          r / 'scripts/player-artwork-tests/SelectedPlayerArtworkTest.kt',
          r / 'scripts/player-artwork-tests/SharedArtworkTest.kt',
          main/'data/LibraryCollection.kt',main/'data/BoundedLibraryCorpus.kt',main/'data/LibrarySortStore.kt',main/'playback/QueuePolicy.kt']
if not a.shared_only:
    inputs += [main/'product/artwork/ThumbnailReadGate.kt',r/'scripts/player-artwork-tests/ThumbnailLookaheadTest.kt']
for f in inputs:
    (a.output / f.name).write_text(f.read_text())
if not a.shared_only:
    safety=r/'scripts/player-artwork-tests/ThumbnailSafetyTest.kt'
    inputs.append(safety);(a.output/safety.name).write_text(safety.read_text())
if a.library_loader_source:
    (a.output/'LibraryArtwork.kt').write_text(a.library_loader_source.read_text())
    inputs.append(a.library_loader_source)
# Projection/type declarations come from production. Only unrelated persistent phase-link type is facaded.
projection = (main / 'playback/ControllerProjection.kt').read_text()
start = projection.index('@kotlinx.serialization.Serializable data class QueueOccurrence')
end = projection.index('/** Disposable immutable projection')
declarations = projection[start:end].replace('@kotlinx.serialization.Serializable ', '').replace('Player.REPEAT_MODE_OFF', '0')
arrangement=(main/'playback/Arrangement.kt').read_text()
identities=arrangement[arrangement.index('@Serializable data class ArrangementIdentity'):arrangement.index('/** No gain')].replace('@Serializable ','')
performance=(main/'playback/TransientPerformance.kt').read_text()
performance=performance[performance.index('@Serializable data class PerformanceTarget'):performance.index('/** Explicit bounded')].replace('@Serializable ','')
(a.output/'AnnotatedStringBoundary.kt').write_text('package androidx.compose.ui.text\ndata class AnnotatedString(val text:String)\n')
(a.output/'UnrelatedPlaybackTypes.kt').write_text('''package com.soundq.android.playback
// Declaration-only: the artwork tests never construct these unrelated playback capabilities.
interface PlaybackRef {class Device(val id:String):PlaybackRef}
class PlaybackClockAuthority
class ListeningSpeedState
class SelectedDevicePlaybackOwner
''')
(a.output / 'ProjectionBoundary.kt').write_text('package com.soundq.android.playback\nimport com.soundq.android.data.*\nimport com.soundq.android.data.timeline.*\nenum class QueueOrigin {Manual, Context, Continuation}\n'+identities+performance+declarations)
for name in ['Timeline.kt','TempoTransition.kt']:
    text=(main/'data/timeline'/name).read_text().replace('import kotlinx.serialization.Serializable\n','').replace('@kotlinx.serialization.Transient ','').replace('@Serializable ','')
    (a.output/name).write_text(text)
owner=(main/'data/timeline/TimelineOwner.kt').read_text()
validate=owner[owner.index('fun validateTimeline('):owner.index('/** Durable draft timing owner.')]
rate=next(line for line in (main/'data/timeline/LinkedPhase.kt').read_text().splitlines() if line.startswith('internal fun TimelineClip.rateOne()'))
owner=owner[owner.index('@Serializable data class TimelineDocument'):owner.index('fun validateTempoDocument')].replace('@Serializable ','')
(a.output/'TimelineDocument.kt').write_text('package com.soundq.android.data.timeline\nclass PhaseLink { fun contains(occurrence:String)=false }\n'+owner+validate+rate)
# Extract the actual URL policy, not a hand-written accepting stand-in.
api = (main / 'data/SoundQApi.kt').read_text()
policy = api[api.index('        fun safeMediaUrl(value: String)'):api.index('\n    }\n}', api.index('        fun safeMediaUrl(value: String)'))]
(a.output / 'MediaPolicy.kt').write_text('''package com.soundq.android.data
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
object SoundQApi {
''' + policy + '\n}\n')
(a.output / 'BitmapHardwareFacade.kt').write_text('''package android.graphics
// Bounds/sample hardware facade. ImageIO, not native BitmapFactory.
class Bitmap(val width:Int,val height:Int,val allocationByteCount:Int=width*height*4) {
 enum class Config {ARGB_8888}
}
object BitmapFactory {
 class Options {var inJustDecodeBounds=false;var outWidth=0;var outHeight=0;var inSampleSize=1;var inPreferredConfig:Bitmap.Config?=null}
 fun decodeByteArray(data:ByteArray,offset:Int,length:Int,o:Options):Bitmap? {
  javax.imageio.ImageIO.createImageInputStream(java.io.ByteArrayInputStream(data,offset,length)).use {input->
   val readers=javax.imageio.ImageIO.getImageReaders(input)
   if(!readers.hasNext())return null
   val reader=readers.next()
   try {reader.input=input;o.outWidth=reader.getWidth(0);o.outHeight=reader.getHeight(0)
    return if(o.inJustDecodeBounds)null else Bitmap((o.outWidth+o.inSampleSize-1)/o.inSampleSize,(o.outHeight+o.inSampleSize-1)/o.inSampleSize)
   } finally {reader.dispose()}
  }
 }
}
''')
presentation = a.presentation_source or main / 'product/artwork/TrackArtwork.kt'
inputs.append(presentation)
if not a.shared_only:
    import runpy
    generate=runpy.run_path(str(r/'scripts/player-artwork-tests/native_binding.py'))['generate']
    binding=a.library_binding_source or main/'product/artwork/LibraryRowArtwork.kt'
    inputs.append(binding)
    generate(a.output,presentation,binding)
    phone=a.phone_source or main/'product/artwork/PhoneArtwork.kt'
    inputs.append(phone)
    runpy.run_path(str(r/'scripts/player-artwork-tests/phone_binding.py'))['generate'](a.output,phone)
ui = presentation.read_text()
opening = ui.index('{', ui.index('Canvas(Modifier.fillMaxSize())'))
end = opening + 1
depth = 1
while depth:
    depth += (ui[end] == '{') - (ui[end] == '}')
    end += 1
draw = ui[opening + 1:end - 1]
# Shared paint accepts a checked read callback. The predecessor used its selected lease directly.
shared_draw = 'bitmap()' in draw and 'lease.bitmap()' not in draw
(a.output / 'DrawBoundary.kt').write_text('''package com.soundq.android.product.artwork
import android.graphics.Bitmap
import java.util.concurrent.atomic.AtomicBoolean
data class IntOffset(val x:Int,val y:Int)
data class IntSize(val width:Int,val height:Int)
data class DrawSize(val width:Float,val height:Float)
fun Bitmap.asImageBitmap()=this
// Only the raster hardware is replaced. paint below contains the exact production Canvas body.
internal class DrawBoundary {
 val size=DrawSize(320f,320f);val background=0;var images=0
 fun drawRect(color:Int) {}
 fun drawImage(image:Bitmap,srcOffset:IntOffset,srcSize:IntSize,dstSize:IntSize) {images++}
 fun paint(pixels:Bitmap?,mounted:AtomicBoolean,lease:SelectedPlayerArtwork.Lease) {
  paintChecked(pixels,mounted,lease::bitmap)
 }
 fun paintRow(pixels:Bitmap?,mounted:AtomicBoolean,row:LibraryArtwork.Row) {paintChecked(pixels,mounted,row::bitmap)}
 fun paintChecked(pixels:Bitmap?,mounted:AtomicBoolean,bitmap:()->Bitmap?) {
''' + (draw if shared_draw else draw.replace('lease.bitmap()', 'bitmap()')) + '\n }\n}\n')
(a.output / 'AndroidLogBoundary.kt').write_text('''package android.util
object Log {
 @JvmStatic fun isLoggable(tag:String,level:Int)=false
 @JvmStatic fun println(priority:Int,tag:String,message:String)=0
 @JvmStatic fun getStackTraceString(error:Throwable)=error.stackTraceToString()
}
''')
(a.output / 'AndroidBuildBoundary.kt').write_text('''package android.os
object Build {object VERSION {@JvmField val SDK_INT=0}}
''')
(a.output/'LibraryCaptureBoundary.kt').write_text('''package com.soundq.android.data.playlists
import com.soundq.android.data.*
class LibraryTrackCapture internal constructor(internal val scope:AccountScope,val track:Track,internal val lifetime:Long)
''')
# Preserve the existing Library TLS and slot families alongside the shared-player suite.
library_output=a.output/'library-existing'
library_command=['python3',str(r/'scripts/test-library-artwork.py'),'--generate',str(library_output)]
if a.designsystem_root:library_command+=['--designsystem-root',str(a.designsystem_root)]
subprocess.run(library_command,check=True)
if a.library_loader_source:
    extracted=a.library_loader_source.read_text().replace('package com.soundq.android.product.artwork','package com.soundq.android.artworkfixture').replace('import android.graphics.Bitmap\n','').replace('import android.graphics.BitmapFactory\n','')
    (library_output/'LibraryArtworkExtracted.kt').write_text(extracted)
(a.output/'LibraryRepository.kt').write_text((main/'data/LibraryRepository.kt').read_text())
(a.output/'MemoryStore.kt').write_text('''package com.soundq.android.data
class MemoryStore:SessionStore {
 var tokens:SecretTokens?=null
 override fun load(endpoint:ApiEndpoint)=tokens
 override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){this.tokens=tokens}
 override fun clear(){tokens=null}
}
''')
graph_source=a.graph_source or main/'SoundQApplication.kt'
graph_text=graph_source.read_text()
inputs.append(graph_source)
(a.output/'GraphMetadataBoundary.kt').write_text('''package com.soundq.android
import com.soundq.android.data.*
// Only unrelated playlist read owner is facaded. Tests use actual acknowledged LibraryRepository.
class PlaylistDetailBoundary {fun capturePlayback():PlaylistCaptureBoundary?=null}
class PlaylistCaptureBoundary(val detail:PlaylistBoundary)
class PlaylistBoundary(val tracks:List<Track>)
class GraphMetadataBoundary(val session:AccountSession,val library:LibraryRepository) {
 val playlistDetail=PlaylistDetailBoundary()
'''+graph_text.split('    private val known=',1)[1].split('    init {localUnlock',1)[0].join(['    private val known=',''])+
graph_text.split('    fun rememberTracks(',1)[1].split('    fun retireCatalog()',1)[0].join(['    fun rememberTracks(',''])+'\n}\n')
files = [str(x) for x in a.output.glob('*.kt') if not(a.shared_only and x.name=='SelectedPlayerArtworkTest.kt')]
if not a.shared_only:files += [str(x) for x in library_output.glob('*.kt')]
env = dict(os.environ, TMPDIR=str(a.output.resolve()))
commands = [ ['kotlinc', '-J-XX:ActiveProcessorCount=1', *files, '-cp', cp, '-include-runtime', '-d', str(a.output / 'test.jar')],
             ['java', '-XX:ActiveProcessorCount=1', '-Djava.io.tmpdir=' + str(a.output.resolve()), '-cp', str(a.output / 'test.jar') + os.pathsep + cp, 'org.junit.runner.JUnitCore', 'com.soundq.android.product.artwork.SelectedPlayerArtworkTest', 'com.soundq.android.product.artwork.SharedArtworkTest', 'com.soundq.android.artworkfixture.LibraryArtworkTlsTest', 'com.soundq.android.artworkvisualfixture.LibraryArtworkVisualSlotTest'] ]
if a.shared_only:commands[1]=commands[1][:commands[1].index('org.junit.runner.JUnitCore')+1]+['com.soundq.android.product.artwork.SharedArtworkTest']
else:commands[1]+= ['com.soundq.android.product.artwork.ThumbnailSafetyTest','com.soundq.android.product.artwork.ThumbnailLookaheadTest']
if a.lookahead_only:commands[1]=commands[1][:commands[1].index('org.junit.runner.JUnitCore')+1]+['com.soundq.android.product.artwork.ThumbnailLookaheadTest']
# Preserve exact fixtures/commands even for an intentionally failing predecessor/control.
(a.output / 'sources.json').write_text(json.dumps({str(f.resolve()):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}, indent=2))
(a.output / 'compiled-inputs.json').write_text(json.dumps({str(Path(f).resolve()):hashlib.sha256(Path(f).read_bytes()).hexdigest() for f in files},indent=2))
classes=commands[1][commands[1].index('org.junit.runner.JUnitCore')+1:]
inventory=[]
for f in files:
    text=Path(f).read_text()
    package=re.search(r'^package\s+(\S+)',text,re.M)
    if not package:continue
    for cls in classes:
        if cls.rsplit('.',1)[0]==package[1] and re.search(r'\bclass\s+'+re.escape(cls.rsplit('.',1)[1])+r'\b',text):
            inventory += [cls+'.'+name for name in re.findall(r'@Test\s+fun\s+(\w+)',text)]
assert len(inventory)==len(set(inventory))
(a.output/'test-inventory.json').write_text(json.dumps(inventory,indent=2))
(a.output/'commands.json').write_text(json.dumps({'cwd':os.getcwd(),'TMPDIR':env['TMPDIR'],'commands':commands},indent=2))
exits=[]
for index, command in enumerate(commands):
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (a.output / ('compile.log' if index == 0 else 'test.log')).write_text(result.stdout)
    exits.append(result.returncode)
    (a.output/'exits.json').write_text(json.dumps(exits))
    print(result.stdout, end='')
    if index==1:
        match=re.search(r'(?:OK \((\d+) tests\)|Tests run: (\d+))',result.stdout)
        assert match and int(match[1] or match[2])==len(inventory), 'JUnit/inventory count mismatch'
    if result.returncode:
        raise SystemExit(result.returncode)
print('Executed selected-player artwork JVM boundary tests. Native draw/decode not claimed.')
