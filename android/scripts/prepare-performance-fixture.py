#!/usr/bin/env python3
"""Generate owned synthetic audio and measure actual decoded signed/RGB peaks.
No user music, backend records or production-analysis claims.
"""
from pathlib import Path
import subprocess, json, hashlib
import numpy as np
root=Path(__file__).resolve().parents[1]
out=root/'app/src/androidTest/assets/performance'
out.mkdir(parents=True,exist_ok=True)
hz=48000
seconds=128
n=hz*seconds
t=np.arange(n,dtype=np.float64)/hz
for index,bpm in enumerate([120,100,127,120],1):
    # Distinct low-level carriers and short source-grid transients with headroom
    # for a four-source sum. This is an annotated synthetic mechanism fixture.
    frequency=[220,330,440,550][index-1]
    pcm=.025*np.sin(2*np.pi*frequency*t)
    period=60.0/bpm
    for ordinal in range(int(seconds/period)):
        start=round((.2+ordinal*period)*hz)
        end=min(n,start+480)
        if start<n:pcm[start:end]+=.08*np.hanning(960)[:end-start]
    raw=out/f'track-{index}.input.f32'
    raw.write_bytes(np.repeat(pcm.astype('<f4')[:,None],2,axis=1).tobytes())
    asset=out/f'track-{index}.mp3'
    subprocess.run(['ffmpeg','-threads','1','-v','error','-y','-f','f32le','-ar',str(hz),'-ac','2','-i',str(raw),'-c:a','libmp3lame','-b:a','128k',str(asset)],check=True)
    raw.unlink()
    decoded=subprocess.check_output(['ffmpeg','-threads','1','-v','error','-i',str(asset),'-f','f32le','-ar',str(hz),'-ac','1','-'])
    values=np.frombuffer(decoded,dtype='<f4').astype(np.float64)
    edges=np.linspace(0,len(values),3200+1,dtype=np.int64)
    minima=[];maxima=[];bands=[[],[],[]]
    frequencies=np.fft.rfftfreq(2048,1/hz);window=np.hanning(2048)
    for start,end in zip(edges[:-1],edges[1:]):
        minima.append(round(float(np.clip(values[start:end].min(),-1,1)),6))
        maxima.append(round(float(np.clip(values[start:end].max(),-1,1)),6))
        center=(int(start)+int(end))//2;lo=max(0,center-1024);hi=min(len(values),center+1024);frame=np.zeros(2048)
        frame[lo-center+1024:hi-center+1024]=values[lo:hi]
        spectrum=np.abs(np.fft.rfft(frame*window))**2
        for output,mask in zip(bands,[frequencies<200,(frequencies>=200)&(frequencies<2000),frequencies>=2000]):output.append(float(np.sqrt(spectrum[mask].sum())))
    scalar=max(max(v)for v in bands)
    bands=[[round(v/scalar,6)for v in b]for b in bands]
    digest=hashlib.sha256(asset.read_bytes()).hexdigest()
    body={'track_id':index,'schema_version':1,'status':'analyzed','summary':{},'artifacts':{'source':{'duration_ms':round(len(values)*1000/hz),'fingerprint':'synthetic-performance-'+digest},'waveforms':{'detail':{'minima':minima,'maxima':maxima}},'channels':{'channel_set':'bands3-v1','audio_ref':None,'normalization':{'kind':'shared_peak','scalar':scalar},'weights':{'low':1.0,'mid':1.0,'high':1.0},'crossovers_hz':{'low_mid':200,'mid_high':2000},'provenance':'fixture:decoded-mp3-fft-rms-v1','detail':dict(zip(['low','mid','high'],bands))}}}
    (out/f'track-{index}-analysis.json').write_text(json.dumps(body,separators=(',',':'))+'\n')
    print(json.dumps({'track':index,'syntheticBpm':bpm,'anchorMs':200,'durationMs':body['artifacts']['source']['duration_ms'],'sha256':digest,'measuredColumns':len(minima)}))
