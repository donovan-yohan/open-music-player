#!/usr/bin/env python3
"""Exercise real contact emissions with recording controller/clock boundaries."""
from pathlib import Path
import argparse,os,subprocess
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);a=p.parse_args();a.build.mkdir(parents=True,exist_ok=False)
r=Path(__file__).resolve().parents[2];c=Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(g,n,v):return next((c/g/n/v).glob('*/*.jar'))
stdlib=jar('org.jetbrains.kotlin','kotlin-stdlib','2.4.21');compiler=jar('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.21')
run=[compiler,stdlib,*list((c/'org.jetbrains.kotlin/kotlin-reflect').glob('*/*/*.jar')),*list((c/'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm').glob('*/*/*.jar')),*list((c/'org.jetbrains/annotations').glob('*/*/*.jar'))]
junit=jar('junit','junit','4.13.2');hamcrest=next((c/'org.hamcrest/hamcrest-core').glob('*/*/*.jar'))
(a.build/'Clock.kt').write_text('package android.os\nobject SystemClock { fun uptimeMillis()=1010L }\n')
(a.build/'Controller.kt').write_text('''package com.soundq.android.playback
class ArrangementIdentity
class ScratchLease
class ControllerProjection {
 val moves=mutableListOf<Pair<Double,Long>>()
 val terminals=mutableListOf<Pair<String,Long>>()
 var held=false
 private var done:((ScratchLease?)->Unit)?=null
 fun beginScratch(identity:ArrangementIdentity,occurrence:String,event:Long,callback:(ScratchLease?)->Unit){done=callback;if(!held)acknowledge()}
 fun acknowledge(){done?.invoke(ScratchLease());done=null}
 fun moveScratch(lease:ScratchLease,rate:Double,event:Long){moves.add(rate to event)}
 fun endScratch(lease:ScratchLease,event:Long){terminals.add("end" to event)}
 fun cancelScratch(lease:ScratchLease,event:Long){terminals.add("cancel" to event)}
}
''')
sources=[a.build/'Clock.kt',a.build/'Controller.kt',r/'android/scripts/LiveScratchContactTest.kt',r/'android/app/src/main/kotlin/com/soundq/android/product/timeline/LiveScratchContact.kt']
java=Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java');cp=[stdlib,junit,hamcrest];out=a.build/'classes'
subprocess.run([str(java),'-Xmx512m','-XX:ActiveProcessorCount=1','-cp',':'.join(map(str,run)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-cp',':'.join(map(str,cp)),'-d',str(out),*map(str,sources)],check=True)
subprocess.run([str(java),'-Xmx256m','-XX:ActiveProcessorCount=1','-cp',':'.join(map(str,[out,*cp])),'org.junit.runner.JUnitCore','com.soundq.android.product.timeline.LiveScratchContactTest'],check=True)
