#!/usr/bin/env python3
"""Independent PCM oracle. No transport map imports. 32k tone plus source attacks."""
import math
import struct
import sys
from pathlib import Path
pcm = Path(sys.argv[1]).read_bytes()
samples = struct.unpack('<' + str(len(pcm)//4) + 'f', pcm)
assert len(samples) == 64000
crossings=[]
for i in range(16000,len(samples)):
    if samples[i-1]<=0<samples[i]:
        crossings.append(i-1-samples[i-1]/(samples[i]-samples[i-1]))
hz=(len(crossings)-1)*32000/(crossings[-1]-crossings[0])
assert abs(hz-440)<2 and abs(hz-528)>50
# Remove the known 440-Hz carrier with an independent two-coefficient fit.
# Positive residual locates non-periodic attack content, rather than mistaking
# the unchanged pitch itself for a changed tempo.
attacks=[]
for offset in range(16000,len(samples)-128,64):
    values=samples[offset:offset+128]
    cos=[math.cos(2*math.pi*440*(offset+j)/32000) for j in range(128)]
    sin=[math.sin(2*math.pi*440*(offset+j)/32000) for j in range(128)]
    cc=sum(x*x for x in cos);ss=sum(x*x for x in sin)
    cs=sum(x*y for x,y in zip(cos,sin))
    yc=sum(x*y for x,y in zip(values,cos));ys=sum(x*y for x,y in zip(values,sin))
    d=cc*ss-cs*cs;a=(yc*ss-ys*cs)/d;b=(ys*cc-yc*cs)/d
    residual=sum(x-a*c-b*s for x,c,s in zip(values,cos,sin))/128
    attacks.append((residual,offset))
peaks=[]
for amp,offset in sorted(attacks,reverse=True):
    if amp<.01:break
    if all(abs(offset-x[1])>3000 for x in peaks):peaks.append((amp,offset))
peaks.sort(key=lambda x:x[1])
assert len(peaks)==3,peaks
intervals=[(peaks[i][1]-peaks[i-1][1])/32000 for i in range(1,len(peaks))]
# Source attacks are 0.5 seconds apart. Actual edited output is 1.2x tempo.
# Bound measured residual displacement separately from analytic source mapping.
assert all(abs(x-.5/1.2)<.012 for x in intervals),intervals
assert all(abs(x-.5)>.05 for x in intervals)
print(f'PASS PCM pitch={hz:.6f} Hz, attack intervals={intervals}, actual 1.2x attack rate; raw pitch-shift and unchanged-output controls excluded')
