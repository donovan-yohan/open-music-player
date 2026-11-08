#!/usr/bin/env python3
"""Independent decoded-sample oracle for the JNI's exact production bridge."""
import ctypes as C
import json, math, os, pathlib, struct, subprocess, sys
root=pathlib.Path(__file__).resolve().parents[1]
build=pathlib.Path(sys.argv[1]);work=pathlib.Path(sys.argv[2]);work.mkdir(parents=True,exist_ok=True)
lib=C.CDLL(str(build/('libsoundq_mix_android.dylib' if sys.platform=='darwin' else 'libsoundq_mix_android.so')))
assert hasattr(lib,'sq_android_open'), 'Kotlin native decoder/schedule bridge is absent'
lib.sq_android_open.restype=C.c_void_p
lib.sq_android_open.argtypes=[C.POINTER(C.c_char_p),C.c_uint,C.POINTER(C.c_int64),C.c_uint,C.POINTER(C.c_float),C.POINTER(C.c_int64),C.POINTER(C.c_float),C.c_uint]
lib.sq_android_render.argtypes=[C.c_void_p,C.c_uint64,C.c_uint,C.POINTER(C.c_float)];lib.sq_android_render.restype=C.c_int
lib.sq_android_close.argtypes=[C.c_void_p]
frames=24000
for source in range(2):
    raw=b''.join(struct.pack('<ff',.1*math.sin((i+1)*(source+1)*.013),.07*math.cos((i+1)*(source+2)*.011)) for i in range(frames))
    p=work/f'{source}.f32';p.write_bytes(raw)
    subprocess.run(['ffmpeg','-v','error','-y','-f','f32le','-ar','48000','-ac','2','-i',str(p),'-c:a','libopus',str(work/f'{source}.opus')],check=True)
    subprocess.run(['ffmpeg','-v','error','-y','-i',str(work/f'{source}.opus'),'-f','f32le',str(work/f'{source}.decoded')],check=True)
decoded=[struct.unpack('<'+'f'*(frames*2),(work/f'{i}.decoded').read_bytes()) for i in range(2)]
paths=(C.c_char_p*2)(*[str(work/f'{i}.opus').encode() for i in range(2)])
# instance,start,end,sourceStart,fadeIn,fadeOut,busCount,path0..4. Rate=1 only.
clips=(C.c_int64*24)(1,0,12000,2400,480,960,1,0,-1,-1,-1,-1, 2,6000,18000,4800,0,0,1,1,-1,-1,-1,-1)
gains=(C.c_float*2)(.5,.25)
events=(C.c_int64*4)(0,7200,0,480);eventgains=(C.c_float*1)(.2)
h=lib.sq_android_open(paths,2,clips,2,gains,events,eventgains,1);assert h,'native creation refused valid sources'
maxerr=0.;samples=0
try:
    for start in [0,2048,4096,6144,8192,10240,12288,14336,16384,18000, 7200,0,11900]:
        n=min(2048,20000-start);out=(C.c_float*(n*2))()
        assert lib.sq_android_render(h,start,n,out)==0
        for f in range(n):
            t=start+f
            for ch in range(2):
                expected=0.
                for idx,(s,e,origin,g,fi,fo) in enumerate([(0,12000,2400,.5,480,960),(6000,18000,4800,.25,0,0)]):
                    if s<=t<e:
                        local=t-s;src=origin+local;env=min(local/fi if fi else 1,(e-s-local)/fo if fo else 1,1)
                        env=math.sin(env*math.pi/2)
                        automation=(1 if src<7200 else max(.2,1-.8*(src-7200)/480)) if idx==0 else 1
                        expected+=decoded[idx][src*2+ch]*g*env*automation
                err=abs(out[f*2+ch]-expected);maxerr=max(maxerr,err);samples+=1
                assert err<.00008,(start,f,ch,out[f*2+ch],expected,err)
    # Fifth overlap refuses the complete candidate, never truncates.
    bad=(C.c_int64*60)(*[v for i in range(5) for v in [i+1,0,12000,0,0,0,1,0,-1,-1,-1,-1]])
    assert not lib.sq_android_open(paths,2,bad,5,(C.c_float*5)(*[1]*5),None,None,0)
finally:lib.sq_android_close(h)
print(json.dumps({'oracle':'ffmpeg independent float decoder + every sample trim/overlap/fade/source-ramp/seek','samples':samples,'maxAbsoluteError':maxerr,'rate':48000,'fifthOverlap':'refused'}))
