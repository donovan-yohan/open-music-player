#!/usr/bin/env python3
"""Bounded actual-file host and independent every-frame overlap oracle. No OS output."""
from pathlib import Path
import argparse, array, math, os, subprocess, wave
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--decoder',type=Path,required=True);p.add_argument('--codec',choices=['wav','mp3','opus'],default='wav');a=p.parse_args()
r=Path(__file__).resolve().parents[7];h=r/'android/app/src/main/cpp/nativeengine'
a.build.mkdir(parents=True,exist_ok=True)
for name,rate,channel in [('a',48000,0),('b',44100,1)]:
    data=array.array('h')
    for frame in range(rate*4):
        value=round(1800*math.sin(frame*.017)+900*math.cos(frame*.031))
        data.extend((value,0) if channel==0 else (0,value))
    with wave.open(str(a.build/f'{name}.wav'),'wb') as out:out.setnchannels(2);out.setsampwidth(2);out.setframerate(rate);out.writeframes(data.tobytes())
paths=[]
for name in ('a','b'):
    original=a.build/f'{name}.wav'
    target=a.build/f'{name}.{a.codec}'
    if a.codec!='wav':
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(original)]+(['-c:a','libmp3lame','-b:a','192k'] if a.codec=='mp3' else ['-c:a','libopus','-b:a','128k'])+[str(target)],check=True)
    paths.append(target)
exe=a.build/'overlap-file-test' 
subprocess.run(['c++','-std=c++17','-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',f'-I{h}',f'-I{r}/client/native/transport/include',f'-I{r}/client/native/file_decoder/include',str(h/'tests/overlap_file_tests.cpp'),str(h/'callback_host.cpp'),str(h/'worker_deck.cpp'),str(r/'client/native/transport/src/soundq_transport.cpp'),str(a.decoder),f'-Wl,-rpath,{a.decoder.resolve().parent}','-o',str(exe)],check=True)
subprocess.run([str(exe),str(paths[0]),str(paths[1]),str(a.build/'mixed.f32')],check=True)
actual=array.array('f');actual.frombytes((a.build/'mixed.f32').read_bytes());assert len(actual)==720000*2
sources=[]
for name,path in zip(('a','b'),paths):
    if a.codec=='wav':
        with wave.open(str(path)) as f:
            pcm=array.array('h');pcm.frombytes(f.readframes(f.getnframes()));sources.append((f.getframerate(),[x/32768 for x in pcm]))
    else:
        rate=48000 if a.codec=='opus' or name=='a' else 44100
        decoded=a.build/f'{name}.decoded.f32'
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(path),'-f','f32le','-acodec','pcm_f32le','-ac','2','-ar',str(rate),str(decoded)],check=True)
        pcm=array.array('f');pcm.frombytes(decoded.read_bytes());sources.append((rate,pcm))
maximum=0
for frame in range(720000):
    local=frame%144000
    shape=min(1,local/4800,(144000-local)/4800)
    gain=math.sin(shape*math.pi/2)*2
    for channel,(rate,pcm) in enumerate(sources):
        pos=rate*.1+local*rate/48000
        first=int(pos);fraction=pos-first
        expected=(pcm[first*2+channel]*(1-fraction)+pcm[(first+1)*2+channel]*fraction)*gain
        maximum=max(maximum,abs(actual[frame*2+channel]-expected))
tolerance=2e-7 if a.codec=='wav' else 2e-4
assert maximum<tolerance,maximum
seek=array.array('f');seek.frombytes((a.build/'mixed.f32.seek').read_bytes())
for frame in range(256):
    for channel,(rate,pcm) in enumerate(sources):
        pos=rate*.1+(72000+frame)*rate/48000
        first=int(pos);fraction=pos-first
        expected=(pcm[first*2+channel]*(1-fraction)+pcm[(first+1)*2+channel]*fraction)*2
        assert abs(seek[frame*2+channel]-expected)<tolerance

print(f'PASS actual {a.codec} decoder/worker/Host/Engine capture: all 1440000 samples, max_error={maximum:.9g}')
