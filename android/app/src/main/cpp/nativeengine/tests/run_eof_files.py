#!/usr/bin/env python3
"""Generated MP3/Opus only; real decoder/Host and independent every-sample oracle."""
from pathlib import Path
import argparse, array, json, math, subprocess, wave
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--decoder',type=Path,required=True);p.add_argument('--codec',choices=['mp3','opus'],required=True);p.add_argument('--controls',action='store_true');a=p.parse_args()
r=Path(__file__).resolve().parents[7];h=r/'android/app/src/main/cpp/nativeengine';a.build.mkdir(parents=True,exist_ok=True)
paths=[];sources=[]
for name,frames,rate,channel in [('a',182400,48000,0),('b',159131,44100,1)]:
    pcm=array.array('h')
    for f in range(frames):
        v=round(1800*math.sin(f*.017)+900*math.cos(f*.031));pcm.extend((v,0) if channel==0 else (0,v))
    wav=a.build/f'{name}.wav'
    with wave.open(str(wav),'wb') as out:out.setnchannels(2);out.setsampwidth(2);out.setframerate(rate);out.writeframes(pcm.tobytes())
    path=a.build/f'{name}.{a.codec}';decoded=a.build/f'{name}.decoded.f32'
    subprocess.run(['ffmpeg','-threads','1','-v','error','-y','-i',str(wav),'-c:a','libmp3lame' if a.codec=='mp3' else 'libopus',str(path)],check=True)
    hz=48000 if a.codec=='opus' else rate
    subprocess.run(['ffmpeg','-threads','1','-v','error','-y','-i',str(path),'-f','f32le','-acodec','pcm_f32le','-ac','2','-ar',str(hz),str(decoded)],check=True)
    data=array.array('f');data.frombytes(decoded.read_bytes());sources.append((hz,data));paths.append(path)
exe=a.build/'eof-file-test'
subprocess.run(['c++','-std=c++17','-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',f'-I{h}',f'-I{r}/client/native/transport/include',f'-I{r}/client/native/file_decoder/include',str(h/'tests/eof_file_tests.cpp'),str(h/'callback_host.cpp'),str(h/'worker_deck.cpp'),str(r/'client/native/transport/src/soundq_transport.cpp'),str(a.decoder),f'-Wl,-rpath,{a.decoder.resolve().parent}','-o',str(exe)],check=True)
subprocess.run([str(exe),*map(str,paths),str(a.build/'mixed.f32'),'controls' if a.controls else 'rounded'],check=True)
if a.controls:raise SystemExit(0)
actual=array.array('f');actual.frombytes((a.build/'mixed.f32').read_bytes());maximum=0;ends=[]
for i,(hz,pcm) in enumerate(sources):
    frames=len(pcm)//2;num=(frames*1000-100*hz)*48000;den=hz*1000
    ends.append((1500 if i else 123)*48+(num+den-1)//den)
assert len(actual)==(max(ends)+256)*2,(len(actual),ends)
for frame in range(len(actual)//2):
    for ch,(hz,pcm) in enumerate(sources):
        start=(1500 if ch else 123)*48;end=ends[ch];expected=0.
        if start<=frame<end:
            local=frame-start;pos=hz*.1+local*hz/48000;first=int(pos);fraction=pos-first
            assert first<len(pcm)//2
            last=min(first+1,len(pcm)//2-1)
            gain=math.sin(min(1,local/4800,(end-frame)/9600)*math.pi/2)
            expected=(pcm[first*2+ch]*(1-fraction)+pcm[last*2+ch]*fraction)*gain
        error=abs(actual[frame*2+ch]-expected);maximum=max(maximum,error)
        assert error<2e-4,(frame,ch,actual[frame*2+ch],expected,error)
print(json.dumps({'codec':a.codec,'oracle':'ffmpeg every sample exact EOF, nonzero placement/trim-in, unequal rates, fades, overlap, tail silence','samples':len(actual),'durationFrames':max(ends),'maxAbsoluteError':maximum}))
