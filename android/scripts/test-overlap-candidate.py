#!/usr/bin/env python3
"""Execute actual candidate source with encoded-source/MediaItem boundary facades.
Uses already-compiled actual timeline and strict MixJson. No Android runtime claim.
"""
from pathlib import Path
import argparse, os, subprocess
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);a=p.parse_args();a.build.mkdir(parents=True,exist_ok=True)
r=Path(__file__).resolve().parents[2];base=r/'android/app/src/main/kotlin/com/soundq/android/playback/nativeengine'
media=a.build/'MediaItem.kt';media.write_text('''package androidx.media3.common
class MediaItem(val mediaId:String,val localConfiguration:LocalConfiguration?) {
 class LocalConfiguration(val uri:String)
 class Builder {var id="";var uri="";fun setMediaId(v:String)=apply{id=v};fun setUri(v:String)=apply{uri=v};fun build()=MediaItem(id,LocalConfiguration(uri))}
}
''')
facade=a.build/'Source.kt';facade.write_text('''package com.soundq.android.playback.nativeengine
import androidx.media3.common.MediaItem
import java.io.File
internal fun interface NativeCallbackSource { fun prepare(item:MediaItem,current:()->Boolean):File }
internal class GrantedNativeCallbackSource:NativeCallbackSource {
 override fun prepare(item:MediaItem,current:()->Boolean):File=error("Real IO is not admitted in host facade")
 fun prepareBounded(item:MediaItem,maxBytes:Long,current:()->Boolean):File=error("Real IO is not admitted in host facade")
}
''')
cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
cp=[r/'android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes']
cp+=list((cache/'org.jetbrains.kotlinx/kotlinx-serialization-core-jvm/1.12.0').glob('*/*.jar'))+list((cache/'org.jetbrains.kotlinx/kotlinx-serialization-json-jvm/1.12.0').glob('*/*.jar'))
jar=a.build/'checks.jar'
subprocess.run(['kotlinc','-J-Xmx768m','-J-XX:ActiveProcessorCount=1','-jvm-target','17','-cp',os.pathsep.join(map(str,cp)),str(media),str(facade),str(base/'NativeCallbackArrangement.kt'),str(r/'android/scripts/NativeArrangementHostChecks.kt'),'-include-runtime','-d',str(jar)],check=True)
subprocess.run(['java','-Xmx768m','-XX:ActiveProcessorCount=1','-cp',os.pathsep.join(map(str,[jar]+cp)),'com.soundq.android.playback.nativeengine.NativeArrangementHostChecks',str(a.build/'files')],check=True)
