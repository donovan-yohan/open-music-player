#!/usr/bin/env python3
"""Independent waveform/FFT oracle for actual native engine PCM output.
Usage: python tempo_pcm_oracle.py /absolute/build/soundq_tempo_pcm_tests /scratch/results
Requires numpy. All fixtures are generated locally; no OS audio or accounts.
"""
import json, math, pathlib, struct, subprocess, sys
import numpy as np
exe=pathlib.Path(sys.argv[1]); dest=pathlib.Path(sys.argv[2]);dest.mkdir(parents=True,exist_ok=True)
def wav(path,rate,pcm):
    raw=np.asarray(pcm,dtype='<f4').tobytes();fmt=struct.pack('<HHIIHH',3,2,rate,rate*8,8,32)
    path.write_bytes(b'RIFF'+struct.pack('<I',36+len(raw))+b'WAVEfmt '+struct.pack('<I',16)+fmt+b'data'+struct.pack('<I',len(raw))+raw)
def integral(t,target,curve):
    x=np.asarray(t)-1.;u=np.clip(x/4.,0,1)
    area=u**3-.5*u**4 if curve else .5*u*u
    return np.where(x<=0,120*x,4*(120*u+(target-120)*area)+np.maximum(0,x-4)*target)+120
def inverse(q,target,curve):
    lo=0.;hi=30.
    for _ in range(70):
        mid=(lo+hi)/2
        if integral(mid,target,curve)<q:lo=mid
        else:hi=mid
    return (lo+hi)/2
results=[]
def run(kind,target=100,curve=0,decks=2,mode='continuous'):
    paths=[]
    # Distinct source rate/BPM. Per-source spectral channels are isolated by
    # silence in opposite stereo channels, so peer mapping is measured separately.
    for idx,(rate,bpm) in enumerate([(48000,120),(44100,100)]):
        t=np.arange(rate*8)/rate;pcm=np.zeros((len(t),2));
        if kind=='tone':pcm[:,idx]=.2*np.sin(2*np.pi*(440 if idx==0 else 659.255)*t)
        elif kind=='transient':
            for beat in [1.37,2.23,3.81,5.42,7.67,9.26,11.33]:
                center=beat*60/bpm
                # Asymmetric broadband packet with a distinct physical energy peak.
                off=t-center;packet=np.exp(-((off)/.00045)**2)*np.sin(2*np.pi*3600*off)
                pcm[:,idx]+=.5*packet
        elif kind=='over':pcm[:,idx]=2*np.sin(2*np.pi*440*t)
        path=dest/f'{kind}-{idx}.wav';wav(path,rate,pcm);paths.append(path)
    out=dest/f'{kind}-{target}-{curve}-{decks}-{mode}.f32'
    cmd=[str(exe),*map(str,paths),str(out),str(target),str(curve),str(decks),mode]
    p=subprocess.run(cmd,capture_output=True,text=True,timeout=90)
    (dest/(out.stem+'.log')).write_text('command: '+' '.join(cmd)+'\n'+p.stdout+p.stderr)
    assert p.returncode==0,(cmd,p.stdout,p.stderr)
    if mode=='host':return
    receipt=json.loads(p.stdout.strip().splitlines()[-1]);pcm=np.fromfile(out,dtype='<f4').reshape(-1,2)
    assert len(pcm)==receipt['frames'] and np.isfinite(pcm).all() and np.max(np.abs(pcm))<=1.000001
    expected=math.ceil(inverse(8*100+120 if mode=='overlap' else 8*120,target,curve)*48000-1e-7)
    assert receipt['duration']==expected,(receipt,expected)
    assert np.max(np.abs(pcm[-1]))<.01,('end declick',pcm[-1])
    metrics=dict(receipt,kind=kind)
    if kind=='tone' and mode=='continuous':
        errors=[]
        for ch,hz in enumerate([440,659.255]):
            for center in [0.5,2.,4.,6.]:
                x=pcm[int((center-.2)*48000):int((center+.2)*48000),ch]
                spec=np.abs(np.fft.rfft(x*np.hanning(len(x)),131072));k=np.argmax(spec)
                logs=np.log(np.maximum(spec[k-1:k+2],1e-30));frac=.5*(logs[0]-logs[2])/(logs[0]-2*logs[1]+logs[2])
                f=(k+frac)*48000/131072;errors.append(abs(1200*np.log2(f/hz)))
        metrics['maxPitchCents']=max(errors);metrics['maxStep']=float(np.max(np.abs(np.diff(pcm,axis=0))))
        assert max(errors)<1,metrics
        assert metrics['maxStep']<.05,metrics
    if mode=='overlap':
        # Native output-time equal-power fades, independently of source tempo.
        # Source A reaches exact trimOut at 5s; no post-EOF A signal remains.
        for center in [1.5,2.5,3.5,4.5]:
            u=(center-1)/4
            amplitudes=[]
            for ch,hz in enumerate([440,659.255]):
                times=np.arange(round((center-.02)*48000),round((center+.02)*48000))/48000
                x=pcm[round((center-.02)*48000):round((center+.02)*48000),ch]
                amplitudes.append(float(2*abs(np.sum(x*np.exp(-2j*np.pi*hz*times)))/len(x)))
            assert abs(amplitudes[0]-.1*math.sin((1-u)*math.pi/2))<.004,(center,amplitudes)
            assert abs(amplitudes[1]-.1*math.sin(u*math.pi/2))<.004,(center,amplitudes)
        assert np.max(np.abs(pcm[240000:,0]))==0,'outgoing must stop at recomputed exact EOF'
    if kind=='transient':
        residuals=[];skews=[]
        for beat in [1.37,2.23,3.81,5.42,7.67,9.26,11.33]:
            expected=inverse(beat*60,target,curve)*48000;peaks=[]
            for ch in range(2):
                first=round(expected)-240;last=round(expected)+241
                signal=pcm[first:last,ch];energy=np.convolve(signal**2,np.ones(9),mode='same');peak=first+int(np.argmax(energy));peaks.append(peak)
                residuals.append(abs(peak-expected)/48)
            skews.append(abs(peaks[0]-peaks[1])/48)
        metrics['maxTransientResidualMs']=max(residuals);metrics['maxPeerSkewMs']=max(skews)
        # Report feasibility only. This is NOT acceptance of a product tolerance.
        metrics['oneFrameAcousticGate']=max(skews)<=1/48
    results.append(metrics);(dest/'metrics.json').write_text(json.dumps(results,indent=2));print(json.dumps(metrics),flush=True)
for target in [100,110,120,144]:
    for curve in [0,1]:run('tone',target,curve)
run('tone',110,0,4)
run('tone',110,0,2,'lifecycle')
run('tone',100,0,2,'overlap')
run('tone',110,0,2,'host')
run('over',110)
for target in [100,110]:run('transient',target)
print('PASS actual native PCM oracle',len(results),'renders plus Host V2 lifecycle')
