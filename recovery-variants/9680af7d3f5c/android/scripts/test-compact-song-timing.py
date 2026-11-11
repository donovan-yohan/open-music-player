#!/usr/bin/env python3
"""Execute production immutable timing and pure adapter; no Android/UI/transport claim."""
import os, re, subprocess, tempfile
from pathlib import Path
R=Path(__file__).resolve().parents[1]
CACHE=Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(name,version='*'):
    return next(CACHE.glob(f'*/{name}/{version}/*/*.jar'))
compiler=[jar('kotlin-compiler-embeddable','2.3.21'),jar('kotlin-stdlib','2.3.21'),jar('kotlin-script-runtime','2.3.21'),jar('kotlin-reflect'),jar('kotlinx-coroutines-core-jvm'),jar('annotations','23.0.0')]
java='/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java'
with tempfile.TemporaryDirectory(prefix='compact-clock-',dir=os.environ['TMPDIR']) as out:
    d=Path(out)
    # Extract unchanged real DTO declarations, stub only unrelated Android collaborators.
    projection=(R/'app/src/main/kotlin/com/soundq/android/playback/ControllerProjection.kt').read_text()
    dtos=projection.split('@kotlinx.serialization.Serializable ',1)[1].split('/** Disposable immutable projection',1)[0]
    (d/'Projection.kt').write_text('package com.soundq.android.playback\nobject Player {const val REPEAT_MODE_OFF=0}\nenum class QueueOrigin {Manual,Context}\nclass AcceptedArrangement\nclass PerformanceDeck\nclass TempoPreviewState\n'+dtos)
    (d/'Compose.kt').write_text('package androidx.compose.runtime\nannotation class Composable\nfun <T> remember(vararg keys:Any?,block:()->T):T=block()\n')
    (d/'Test.kt').write_text('''package com.soundq.android.product
import com.soundq.android.playback.*
import com.soundq.designsystem.*
fun main() {
    var checks=0
    fun verify(value:Boolean){check(value);checks++}
    val a=QueueOccurrence("a",1,"Title","Artist",false,12000)
    val p=PlaybackProjection(connection=PlaybackProjection.Connection.Connected,title="Title",artist="Artist",queue=listOf(a),selectedOccurrence="a",positionMs=6000,durationMs=12000,accountEpoch=4,sessionIdentity="s",sourceQueueIncarnation="q",selectionIncarnation=7)
    val t=projectCompactSongTiming(p,a)
    verify(t.clockText=="0:06 / 0:12")
    verify(t.fraction==0.5f)
    verify(t.state==CompactPlaybackState.Paused)
    verify(projectCompactSongTiming(p.copy(localOnly=true),a)==t)
    verify(projectCompactSongTiming(p.copy(positionMs=24000),a).elapsed==12000L)
    verify(projectCompactSongTiming(p.copy(positionMs=-1),a).elapsed==0L)
    verify(projectCompactSongTiming(p.copy(durationMs=0),a).fraction==null)
    verify(projectCompactSongTiming(p.copy(durationMs=-1),a).clockText=="0:06 / —:—")
    verify(projectCompactSongTiming(p.copy(preparing=true),a).state==CompactPlaybackState.Preparing)
    verify(projectCompactSongTiming(p.copy(isPlaying=true),a).state==CompactPlaybackState.Playing)
    verify(projectCompactSongTiming(p.copy(error="failed"),a).state==CompactPlaybackState.Failed)
    verify(projectCompactSongTiming(p.copy(selectedOccurrence="b"),a).fraction==null)
    verify(projectCompactSongTiming(p.copy(title="Foreign"),a).fraction==null)
    verify(projectCompactSongTiming(p.copy(source=PlaybackSource.Arrangement),a).fraction==null)
    verify(projectCompactSongTiming(p.copy(source=PlaybackSource.SavedMix),a).fraction==null)
    verify(projectCompactSongTiming(p.copy(connection=PlaybackProjection.Connection.Disconnected),a).identity==null)
    verify(projectCompactSongTiming(p.copy(accountEpoch=5),a).identity!=t.identity)
    verify(projectCompactSongTiming(p.copy(sessionIdentity="new"),a).identity!=t.identity)
    verify(projectCompactSongTiming(p.copy(sourceQueueIncarnation="new"),a).identity!=t.identity)
    verify(projectCompactSongTiming(p.copy(selectionIncarnation=9),a).identity!=t.identity)
    verify(CompactSongTiming(elapsedMs=null,totalMs=12000).clockText=="—:— / 0:12")
    verify(formatSongTime(3661000)=="1:01:01")
    println("PASS $checks production timing/adapter assertions (not native UI)")
}
''')
    files=[R/'designsystem/src/main/kotlin/com/soundq/designsystem/CompactSongTiming.kt',R/'app/src/main/kotlin/com/soundq/android/product/CompactSongTimingAdapter.kt',*d.glob('*.kt')]
    subprocess.run([java,'-cp',':'.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',str(jar('kotlin-stdlib','2.3.21')),'-d',str(d/'classes'),*map(str,files)],check=True)
    subprocess.run([java,'-cp',str(d/'classes')+':'+str(jar('kotlin-stdlib','2.3.21')),'com.soundq.android.product.TestKt'],check=True)
