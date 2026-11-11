#!/usr/bin/env python3
"""Controlled callback JNI/codec proof, independent every-sample oracle. No OS audio.
Prereqs: source-built decoder dylib, configured host signalsmith outputs, cached
Kotlin 2.4.21 jars in the explicitly supplied PRIVATE Gradle home, JDK JNI headers.
"""
import argparse,array,hashlib,json,math,os,subprocess,wave
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--decoder',type=Path,required=True);p.add_argument('--host-build',type=Path,required=True);p.add_argument('--jdk-headers',type=Path,required=True);p.add_argument('--codec',choices=['wav','mp3','opus'],required=True);p.add_argument('--reverse',action='store_true');a=p.parse_args()
r=Path(__file__).resolve().parents[2];h=r/'android/app/src/main/cpp/nativeengine';a.build.mkdir(parents=True,exist_ok=True)
cache=Path(os.environ['GRADLE_USER_HOME'])/'caches/modules-2/files-2.1'
def jar(g,n,v):return next((cache/g/n/v).glob('*/*.jar'))
def run(cmd,**kw):print('+',*map(str,cmd),flush=True);return subprocess.run(list(map(str,cmd)),check=True,**kw)
paths=[];references=[];hashes={}
for voice,rate in [('a',48000),('b',44100)]:
    raw=array.array('h')
    for f in range(rate*6):
        v=round(1500*math.sin(f*(.013 if voice=='a' else .023))+700*math.cos(f*.029))
        raw.extend((v,round(v*.3)) if voice=='a' else (round(v*-.4),v))
    wav=a.build/f'{voice}.wav'
    with wave.open(str(wav),'wb') as out:out.setnchannels(2);out.setsampwidth(2);out.setframerate(rate);out.writeframes(raw.tobytes())
    path=a.build/f'{voice}.{a.codec}'
    if a.codec!='wav':run(['ffmpeg','-threads','1','-v','error','-y','-i',wav,'-c:a','libmp3lame' if a.codec=='mp3' else 'libopus',path])
    hz=48000 if a.codec=='opus' else rate;ref=a.build/f'{voice}.reference.f32'
    run(['ffmpeg','-threads','1','-v','error','-y','-i',path,'-f','f32le','-acodec','pcm_f32le','-ac','2','-ar',hz,ref])
    pcm=array.array('f');pcm.frombytes(ref.read_bytes());assert len(pcm)==hz*6*2
    references.append((hz,pcm));paths.append(path);hashes[path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
if a.reverse:paths.reverse();references.reverse()
lib=a.build/'libsoundq_callback_android.dylib'
includes=[h,r/'client/native/transport/include',r/'client/native/file_decoder/include',a.jdk_headers,a.jdk_headers/'darwin']
cmd=['c++','-std=c++17','-O1','-g','-dynamiclib','-Wall','-Wextra','-Werror']+[f'-I{x}' for x in includes]
for pattern in ['signalsmith-deps/signalsmith-stretch-*','signalsmith-deps/linear-*/include']:cmd+=['-isystem',next(a.host_build.glob(pattern))]
cmd += [h/'jni_bridge.cpp',h/'tests/crossfade_jni_output.cpp',h/'callback_host.cpp',h/'worker_deck.cpp',h/'tempo_processor.cpp',r/'client/native/transport/src/soundq_transport.cpp',a.decoder,f'-Wl,-rpath,{a.decoder.resolve().parent}','-o',lib]
run(cmd)
compiler=[jar('org.jetbrains.kotlin',n,'2.4.21') for n in ['kotlin-compiler-embeddable','kotlin-stdlib','kotlin-script-runtime','kotlin-daemon-embeddable']]+[jar('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0')]+list((cache/'org.jetbrains/annotations').glob('*/*/*.jar'))
std=jar('org.jetbrains.kotlin','kotlin-stdlib','2.4.21');cp=os.pathsep.join(map(str,[std]+[jar('org.jetbrains.kotlinx',n,'1.12.0') for n in ['kotlinx-serialization-core-jvm','kotlinx-serialization-json-jvm']]));java=Path(os.environ['JAVA_HOME'])/'bin/java'
run([java,'-Xmx768m','-XX:ActiveProcessorCount=1','-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',cp,'-d',a.build/'classes',r/'android/app/src/main/kotlin/com/soundq/android/playback/nativeengine/NativeCallbackBridge.kt',r/'android/scripts/OrdinaryCrossfadeJni.kt'])
run([java,'-Xcheck:jni','-XX:ActiveProcessorCount=1',f'-Djava.library.path={a.build}','-cp',str(a.build/'classes')+os.pathsep+cp,'com.soundq.android.playback.nativeengine.OrdinaryCrossfadeJniKt',*paths,a.build])
def tap(source,frame,ch):
    hz,pcm=source;pos=frame*hz/48000;first=int(pos);fraction=pos-first
    return pcm[2*first+ch]*(1-fraction)+pcm[2*min(first+1,len(pcm)//2-1)+ch]*fraction
maximum=0.;outgoing_only=0.;incoming_only=0.;butt_join=0.;samples=0
for name,start in [('before-pause.f32',0),('after-pause.f32',264000)]:
    actual=array.array('f');actual.frombytes((a.build/name).read_bytes())
    assert len(actual)==(264000 if start==0 else 72000)*2
    for f in range(len(actual)//2):
        t=start+f;phase=max(0.,min(1.,(t-240000)/48000))*math.pi/2
        for ch in range(2):
            av=tap(references[0],t,ch) if t<288000 else 0.;bv=tap(references[1],t-240000,ch) if t>=240000 else 0.
            expected=av*math.cos(phase)+bv*math.sin(phase)
            err=abs(actual[f*2+ch]-expected);maximum=max(maximum,err);samples+=1
            if 240000<=t<288000:
                outgoing_only=max(outgoing_only,abs(actual[f*2+ch]-av));incoming_only=max(incoming_only,abs(actual[f*2+ch]-bv));butt_join=max(butt_join,abs(actual[f*2+ch]-av))
tolerance=2e-7 if a.codec=='wav' else 2e-4
assert maximum<tolerance,(maximum,tolerance)
assert min(outgoing_only,incoming_only,butt_join)>.005
seek=array.array('f');seek.frombytes((a.build/'seek.f32').read_bytes());assert len(seek)==512
seek_error=max(abs(seek[2*f+ch]-tap(references[1],216000+f,ch)) for f in range(256) for ch in range(2));assert seek_error<tolerance,seek_error
retired=json.loads((a.build/'retired.json').read_text());assert retired['openDecoders']==0 and all(d['identity']==0 and d['openDecoders']==0 for d in retired['decks'])
result=dict(codec=a.codec,reverse=a.reverse,samples=samples+512,maxAbsoluteError=maximum,seekError=seek_error,counterfactualErrors=dict(outgoingOnly=outgoing_only,incomingOnly=incoming_only,buttJoined=butt_join),inputHashes=hashes,pcmPoolBytes=retired['pcmPoolBytes'],retiredDecoders=retired['openDecoders'],scope='actual production Kotlin/JNI/codec/worker/Host/Engine, controlled sole callback; no device/acoustic/deadline claim')
(a.build/'RESULT.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
