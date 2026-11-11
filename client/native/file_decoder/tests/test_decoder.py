#!/usr/bin/env python3
"""Real byte fixtures and independent ffmpeg oracle (no runtime dependencies)."""
import argparse, array, ctypes as C, json, math, random, struct, subprocess
from pathlib import Path

def run(args):
    return subprocess.run(list(map(str,args)),check=True,capture_output=True,stdin=subprocess.DEVNULL,timeout=90).stdout

def make(directory):
    directory.mkdir(parents=True,exist_ok=True)
    records=[]
    for rate in (44100,48000):
        for channels in (1,2):
            frames=rate*4+137
            rng=random.Random(rate+channels)
            pcm=array.array('f')
            for i in range(frames):
                for c in range(channels):
                    pcm.append(.24*math.sin(2*math.pi*(431+566*c)*i/rate)+rng.uniform(-.01,.01)+(.3 if i%17011==0 else 0))
            name=f'{rate}-{channels}'; raw=directory/(name+'.f32'); raw.write_bytes(pcm.tobytes())
            for codec,opts in [('mp3',['-c:a','libmp3lame','-q:a','2']),('wav',['-c:a','pcm_s16le']),('float.wav',['-c:a','pcm_f32le'])]:
                path=directory/(name+'.'+codec)
                run(['ffmpeg','-v','error','-y','-f','f32le','-ar',rate,'-ac',channels,'-i',raw,*opts,path])
                records.append({'path':str(path),'frames':frames,'rate':rate,'channels':channels})
    opus=directory/'stereo.opus'
    run(['ffmpeg','-v','error','-y','-i',directory/'48000-2.wav','-c:a','libopus',opus])
    records.append({'path':str(opus),'frames':48000*4+137,'rate':48000,'channels':2})
    extra=[]
    for name,opts in [('cbr-info',['-b:a','192k']),('cbr-no-xing',['-b:a','192k','-write_xing','0'])]:
        path=directory/(name+'.mp3')
        run(['ffmpeg','-v','error','-y','-i',directory/'48000-2.wav','-c:a','libmp3lame',*opts,path])
        extent=len(run(['ffmpeg','-v','error','-i',path,'-f','f32le','-']))//8
        extra.append(dict(path=str(path),frames=extent,rate=48000,channels=2))
    records.extend(extra)
    (directory/'records.json').write_text(json.dumps(records))
    return records

def music(directory,oboe):
    records=json.loads((directory/'records.json').read_text())
    provenance=[]
    import hashlib
    for i in range(1,4):
        src=oboe/'samples/shared/src/main/assets'/f'song{i}.wav'
        info=json.loads(run(['ffprobe','-v','error','-show_streams','-of','json',src]))['streams'][0]
        rate=min(int(info['sample_rate']),48000); channels=int(info['channels'])
        input_frames=len(run(['ffmpeg','-v','error','-i',src,'-ar',rate,'-f','f32le','-c:a','pcm_f32le','-']))//(4*channels)
        path=directory/f'oboe-song{i}.mp3'
        run(['ffmpeg','-v','error','-y','-i',src,'-ar',rate,'-c:a','libmp3lame','-q:a','2',path])
        # Some ffmpeg resampling/encoder inputs gain a small resampler flush tail;
        # preserve the actual MP3 oracle extent rather than asserting input length.
        frames=len(run(['ffmpeg','-v','error','-i',path,'-f','f32le','-c:a','pcm_f32le','-']))//(4*channels)
        records.append(dict(path=str(path),frames=frames,rate=rate,channels=channels))
        provenance.append(dict(source=str(src),input_pcm_frames=input_frames,encoded_decoded_frames=frames,source_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),mp3_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
    (directory/'records.json').write_text(json.dumps(records))
    (directory/'music-provenance.json').write_text(json.dumps(provenance,indent=2))
    return records

def malformed(api,directory):
    base=(directory/'44100-2.wav').read_bytes(); mp3=(directory/'44100-2.mp3').read_bytes()
    cases={'junk':(b'not audio',-3),'wav-truncated':(base[:-1],-3),'wav-junk':(base+b'x',-3),
           'mp3-truncated':(mp3[:-1],-3),'mp3-trailing':(mp3+b'junk',-3),'bad-id3':(b'ID3'+b'\xff'*20,-3)}
    def wave(chunks):
        b=b'WAVE'+chunks; return b'RIFF'+struct.pack('<I',len(b))+b
    def chunk(k,b): return k+struct.pack('<I',len(b))+b+(b'\0' if len(b)%2 else b'')
    fmt=struct.pack('<HHIIHH',1,2,44100,176400,4,16)
    cases.update({'wav-overflow':(wave(b'JUNK'+b'\xff'*4),-3),
        'wav-missing-fmt':(wave(chunk(b'data',b'\0'*4)),-3),
        'wav-duplicate-data':(wave(chunk(b'fmt ',fmt)+chunk(b'data',b'\0'*4)*2),-3),
        'wav-duplicate-fmt':(wave(chunk(b'fmt ',fmt)*2+chunk(b'data',b'\0'*4)),-3),
        'wav-misaligned':(wave(chunk(b'fmt ',fmt)+chunk(b'data',b'\0'*3)),-3),
        'wav-too-many-chunks':(wave(chunk(b'JUNK',b'')*65537),-5),
        'wav-three-channel':(wave(chunk(b'fmt ',struct.pack('<HHIIHH',1,3,44100,264600,6,16))+chunk(b'data',b'\0'*6)),-4)})
    checked=0
    for name,(data,want) in cases.items():
        p=directory/name; p.write_bytes(data); status,d=api.load(p)
        assert status==want and not d.value,(name,status,want); checked+=1
    link=directory/'symlink'; link.unlink(missing_ok=True); link.symlink_to(directory/'44100-2.wav')
    fifo=directory/'fifo'
    import os
    if not fifo.exists(): os.mkfifo(fifo)
    for path,limit,want in [(link,1<<27,-2),(fifo,1<<27,-2),(directory,1<<27,-2),('relative',1<<27,-1),(directory/'44100-2.wav',0,-1),(directory/'44100-2.wav',(1<<34)+33,-1),(directory/'44100-2.wav',1,-5)]:
        status,d=api.load(path,limit); assert status==want and not d.value,(path,status,want); checked+=1
    big=directory/'oversized';
    with big.open('wb') as f: f.truncate((1<<27)+1)
    status,d=api.load(big); assert status==-5 and not d.value; checked+=1
    # Unknown odd RIFF chunk and data-before-fmt are allowed, fact ignored.
    good=directory/'odd-chunks.bin'; good.write_bytes(wave(chunk(b'JUNK',b'x')+chunk(b'data',b'\0'*4)+chunk(b'fact',b'\xff'*4)+chunk(b'fmt ',fmt)))
    status,d=api.load(good); assert status==0; assert api.lib.sq_file_decoder_frame_count(d)==1; api.destroy(d)
    # Header-only extent survives bogus Xing frame counts; no-Xing CBR has no
    # recoverable encoder trim and exposes the complete encoded frame extent.
    xing=bytearray(mp3); marker=xing.find(b'Xing'); assert marker>=0
    xing[marker+8:marker+12]=struct.pack('>I',1)
    changed=directory/'wrong-xing-duration.bin'; changed.write_bytes(xing)
    status,d=api.load(changed); assert status==0; assert api.lib.sq_file_decoder_frame_count(d)==44100*4+137; api.destroy(d)
    tagged=directory/'extension-is-wrong.wav'; tagged.write_bytes(mp3)
    status,d=api.load(tagged); assert status==0; assert api.lib.sq_file_decoder_sample_rate(d)==44100; api.destroy(d)
    for kind,opts in [('mono',['-ac','1']),('rate24',['-ar','24000'])]:
        dest=directory/(kind+'.opus'); run(['ffmpeg','-v','error','-y','-i',directory/'stereo.opus',*opts,'-c:a','libopus',dest]); status,d=api.load(dest); assert status==-4 and not d.value; checked+=1
    nonfinite=directory/'nonfinite.wav'; nonfinite.write_bytes(wave(chunk(b'fmt ',struct.pack('<HHIIHH',3,1,44100,176400,4,32))+chunk(b'data',struct.pack('<f',float('nan')))))
    status,d=api.load(nonfinite); assert status==0
    try:
        n=C.c_uint32(999); b=(C.c_float*2)(); assert api.read(d,0,1,b,8,C.byref(n))==-6 and n.value==0
    finally: api.destroy(d)
    for name in ('44100-2.wav','44100-2.mp3','stereo.opus'):
        status,d=api.load(directory/name); assert status==0
        try:
            frames=api.lib.sq_file_decoder_frame_count(d); b=(C.c_float*96004)(*([91.]*96004))
            for start,count,out,cap,want in [(-1,1,b,8,-1),(frames+1,1,b,8,-1),(0,48001,b,384008,-5),(0,0xffffffff,b,2**64-1,-5),(0,1,b,7,-5),(frames,48000,b,0,-5),(0,1,None,8,-1),(0,0,None,0,0)]:
                n=C.c_uint32(999); status=api.read(d,start,count,out,cap,C.byref(n)); assert status==want and n.value==0,(name,start,count,status,want); assert all(x==91. for x in b); checked+=1
        finally: api.destroy(d)
    api.destroy(None); assert api.lib.sq_file_decoder_frame_count(None)==-1
    print(json.dumps({'malformed_and_bound_checks':checked}))

class API:
    def __init__(self,path):
        self.lib=C.CDLL(str(path)); self.open=self.lib.sq_file_decoder_open
        self.open.argtypes=[C.c_char_p,C.c_uint64,C.POINTER(C.c_void_p)]; self.open.restype=C.c_int
        for name,result in [('sample_rate',C.c_uint32),('channels',C.c_uint32),('frame_count',C.c_int64)]:
            fn=getattr(self.lib,'sq_file_decoder_'+name); fn.argtypes=[C.c_void_p]; fn.restype=result
        self.read=self.lib.sq_file_decoder_read_window
        self.read.argtypes=[C.c_void_p,C.c_int64,C.c_uint32,C.POINTER(C.c_float),C.c_size_t,C.POINTER(C.c_uint32)]
        self.destroy=self.lib.sq_file_decoder_destroy; self.destroy.argtypes=[C.c_void_p]
    def load(self,path,limit=1<<27):
        d=C.c_void_p(123); status=self.open(str(path).encode(),limit,C.byref(d)); return status,d
    def window(self,d,start,count):
        b=(C.c_float*(count*2+4))(*([91.]*(count*2+4))); got=C.c_uint32(999)
        code=self.read(d,start,count,b,count*8,C.byref(got))
        assert code==0,(start,count,code)
        assert all(x==91. for x in b[got.value*2:]),('tail',start,count,got.value)
        return list(b[:got.value*2])

def qualification(api,records,directory):
    metrics=[]
    for item in records:
        path=Path(item['path']); status,d=api.load(path); assert status==0,(path,status)
        try:
            frames=api.lib.sq_file_decoder_frame_count(d)
            assert frames==item['frames'],(path,frames,item['frames'])
            assert api.lib.sq_file_decoder_sample_rate(d)==item['rate']
            assert api.lib.sq_file_decoder_channels(d)==2
            native=[]
            for start in range(0,frames,4093):
                part=api.window(d,start,min(4093,frames-start)); assert len(part)==min(4093,frames-start)*2
                native.extend(part)
            rng=random.Random(179)
            windows=[(0,1),(1,4096),(575,1153),(1105,48000),(frames-1,48000),(frames,48000)]
            windows += [(rng.randrange(frames),rng.randrange(1,48001)) for _ in range(30)]
            worst=0
            for start,count in windows:
                b=api.window(d,start,count); assert len(b)==min(count,frames-start)*2
                expected=native[start*2:start*2+len(b)]
                error=max((abs(a-b) for a,b in zip(b,expected)),default=0); worst=max(worst,error)
            # MP3's finite decoder history must restore exactly; Opus has long tonal convergence.
            assert worst <= (0.003 if path.suffix=='.opus' else 0),('seek-continuous',path,worst)
            # Decode at native channel count; duplicate mono ourselves (ffmpeg -ac 2 attenuates).
            data=run(['ffmpeg','-v','error','-i',path,'-f','f32le','-c:a','pcm_f32le','-'])
            ref=array.array('f'); ref.frombytes(data)
            if item['channels']==1: ref=array.array('f',(x for v in ref for x in (v,v)))
            assert len(ref)==len(native),('ffmpeg-extent',path,len(ref),len(native))
            delta=[a-b for a,b in zip(native,ref)]
            peak=max(map(abs,delta)); rms=math.sqrt(sum(x*x for x in delta)/len(delta))
            # Explicit acceptance ceilings are intentionally looser than measured
            # error; report actual values rather than presenting the ceiling as data.
            assert peak < 0.001 and rms < 0.0001, ('independent-fidelity',path,peak,rms)
            shifts={s:sum((native[i*2]-ref[(i+s)*2])**2 for i in range(1000,min(frames-1000,20000),13)) for s in range(-3,4)}
            metrics.append(dict(file=path.name,frames=frames,rate=item['rate'],windows=len(windows),seek_continuous_max_abs=worst,ffmpeg_max_abs=peak,ffmpeg_rms=rms,best_alignment_shift=min(shifts,key=lambda s: shifts[s])))
        finally: api.destroy(d)
    (directory/'metrics.json').write_text(json.dumps(metrics,indent=2)); print(json.dumps(metrics,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--library'); p.add_argument('--directory',required=True); p.add_argument('--generate',action='store_true'); p.add_argument('--oboe',type=Path); a=p.parse_args()
    directory=Path(a.directory).resolve(); records=make(directory) if a.generate else json.loads((directory/'records.json').read_text())
    if a.oboe: records=music(directory,a.oboe)
    if a.library:
        api=API(Path(a.library).resolve()); qualification(api,records,directory); malformed(api,directory)
