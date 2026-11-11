#!/usr/bin/env python3
"""Real generated MP3/Opus -> worker -> Host callback, every-sample independent oracle."""
from pathlib import Path
import argparse, array, json, math, subprocess, wave
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--decoder',type=Path,required=True);p.add_argument('--codec',choices=['mp3','opus'],required=True);a=p.parse_args()
r=Path(__file__).resolve().parents[7];h=r/'android/app/src/main/cpp/nativeengine';a.build.mkdir(parents=True,exist_ok=True)
paths=[];sources=[]
for voice in range(4):
    rate=44100 if voice==1 else 48000
    pcm=array.array('h')
    for f in range(rate*13):
        v=round(800*math.sin(f*(.007+voice*.003))+400*math.cos(f*(.021+voice*.002)))
        pcm.extend((v,round(v*.7)))
    wav=a.build/f'v{voice}.wav'
    with wave.open(str(wav),'wb') as out:out.setnchannels(2);out.setsampwidth(2);out.setframerate(rate);out.writeframes(pcm.tobytes())
    path=a.build/f'v{voice}.{a.codec}';decoded=a.build/f'v{voice}.f32'
    subprocess.run(['ffmpeg','-threads','1','-v','error','-y','-i',str(wav),'-c:a','libmp3lame' if a.codec=='mp3' else 'libopus',str(path)],check=True)
    hz=48000 if a.codec=='opus' else rate
    subprocess.run(['ffmpeg','-threads','1','-v','error','-y','-i',str(path),'-f','f32le','-acodec','pcm_f32le','-ac','2','-ar',str(hz),str(decoded)],check=True)
    data=array.array('f');data.frombytes(decoded.read_bytes());sources.append((hz,data));paths.append(path)
exe=a.build/'performance-file-test'
subprocess.run(['c++','-std=c++17','-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',f'-I{h}',f'-I{r}/client/native/transport/include',f'-I{r}/client/native/file_decoder/include',str(h/'tests/performance_file_tests.cpp'),str(h/'callback_host.cpp'),str(h/'worker_deck.cpp'),str(r/'client/native/transport/src/soundq_transport.cpp'),str(a.decoder),f'-Wl,-rpath,{a.decoder.resolve().parent}','-o',str(exe)],check=True)
prefix=a.build/'performance';subprocess.run([str(exe),*map(str,paths),str(prefix)],check=True)
actual=array.array('f');actual.frombytes(prefix.with_suffix('.f32').read_bytes());rows=[json.loads(l) for l in prefix.with_suffix('.jsonl').read_text().splitlines()]
commands={v['global']:v for v in rows if 'operation' in v};sync=next(v['global'] for v in rows if 'sync' in v);final=rows[-1]['finalState']
assert all(v['missingPcmFrames']==0 for v in final['decks']),final
assert final['openDecoders']<=4 and final['pcmPoolBytes']==12288000
assert len(final['latencySamples'])==64 and final['latencyDropped']>0
assert final['movesCoalesced']>=0
assert final['decks'][1]['syncState']==2 and abs(final['decks'][1]['syncPhaseErrorFrames'])<=1
# Independently solve the beat boundary in source seconds. Unequal decoder sample
# rates cancel only after source-rate normalization, not via raw-frame BPM ratios.
reference_seconds=.1+sync/48000
period=60/127
boundary=sync+math.ceil((.150+math.ceil((reference_seconds+.1-.150)/period)*period-reference_seconds)*48000)
incoming_seconds=.1+sync/48000
incoming_period=60/103
nearest=round((incoming_seconds+(boundary-sync)/48000*(127/103)-.225)/incoming_period)
target_seconds=.225+nearest*incoming_period
reference_target=.150+math.ceil((reference_seconds+.1-.150)/period)*period
target_seconds+=((boundary-sync)/48000-(reference_target-reference_seconds))*(127/103)
last_applied=final['decks'][0]['lastMoveAppliedNanos'];last_event=final['decks'][0]['lastMoveEventNanos']
last_age=(last_applied-last_event)*48000//1000000000
position=4800+144000;rate=1.;target=1.;step=0.;remaining=0;contact=False;last_move=0;move_age=0;release_fade=0
maximum=0.;worst=None
for offset in range(len(actual)//2):
    g=144000+offset
    command=commands.get(g)
    if command:
        op=command['operation']
        if op==1:contact=True;rate=target=0.;remaining=0;last_move=g
        else:
            target=command['rate'] if op==2 else 1.
            remaining=128;step=(target-rate)/128
            if op==2:
                last_move=g;move_age=last_age if command['eventNanos']==last_event else 0
            else:contact=False;release_fade=64
    if contact and g-last_move+move_age>=1920-128 and target!=0:
        target=0.;remaining=128;step=-rate/128
    if remaining:
        remaining-=1;rate=target if remaining==0 else rate+step
    expected=[0.,0.]
    for voice,(hz,data) in enumerate(sources):
        gain=1.
        pos=hz*(.1+g/48000)
        if voice==0:
            pos=position;gain=min(1.,abs(rate)) if contact else 1.
            if release_fade:gain*=(64-release_fade)/64
        elif voice==1 and g>=sync:
            if g>=boundary:
                pos=hz*(target_seconds+(g-boundary)/48000*(127/103));gain=min(1.,(g-boundary)/64)
            elif boundary-g<=64:gain=(boundary-g)/64
        first=int(pos);fraction=pos-first
        for ch in range(2):expected[ch]+=(data[2*first+ch]*(1-fraction)+data[2*(first+1)+ch]*fraction)*gain
    for ch in range(2):
        error=abs(actual[offset*2+ch]-expected[ch])
        if error>maximum:maximum=error;worst=(g,ch,actual[offset*2+ch],expected[ch])
        assert error<2e-4,(error,worst,boundary)
    position=max(4800.,min(580800.,position+rate))
    if release_fade:release_fade-=1
print(json.dumps({'codec':a.codec,'samples':len(actual),'maxAbsoluteError':maximum,'worst':worst,'oracle':'every sample signed scratch ramp/zero/reverse/resume plus unequal-BPM live sync and three unaffected voices','latencyReceipts':final['latencyCount'],'latencyRetained':len(final['latencySamples']),'phaseErrorFrames':final['decks'][1]['syncPhaseErrorFrames']}))
