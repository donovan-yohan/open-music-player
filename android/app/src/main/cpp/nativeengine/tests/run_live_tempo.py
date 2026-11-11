#!/usr/bin/env python3
"""Pinned production Host/Engine live-tempo checks, no Gradle/device/real codec."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--build',type=Path,required=True)
    p.add_argument('--logs',type=Path,required=True)
    args=p.parse_args()
    host=Path(__file__).resolve().parents[1]
    root=host.parents[5]
    build=args.build.resolve();build.mkdir(parents=True,exist_ok=True)
    logs=args.logs.resolve();logs.mkdir(parents=True,exist_ok=True)
    includes=[]
    for name,digest,directory,include in (
        ('stretch','4dc468e46f208415ca66567cacfd8fb22b01d321fcdb4c2452278fee2426b09d','signalsmith-stretch-88061fd4eda56a2353c5d65c74aa3f4ccf76f9da',''),
        ('linear','e6d6a914189894fd728111b2a3209445ecd065aa9a5c1958f41b64ac3cef8b32','linear-0.6.6','include')):
        archive=root/'client/native/third_party/signalsmith'/f'{name}.tar.gz'
        assert hashlib.sha256(archive.read_bytes()).hexdigest()==digest
        destination=(build/'deps').resolve()
        if not (destination/directory).is_dir():
            with tarfile.open(archive) as tar:
                for member in tar.getmembers():
                    target=(destination/member.name).resolve()
                    assert target==destination or destination in target.parents
                    assert member.isfile() or member.isdir()
                tar.extractall(destination)
        includes+=['-isystem',str(destination/directory/include)]
    def run(command,label,timeout=90):
        result=subprocess.run([str(x) for x in command],capture_output=True,text=True,timeout=timeout)
        (logs/f'{label}.log').write_text(result.stdout+result.stderr)
        print(label,result.returncode,result.stdout,result.stderr)
        assert result.returncode==0,label
    sources=[host/'tests/live_tempo_host_tests.cpp',host/'callback_host.cpp',host/'worker_deck.cpp',host/'tempo_processor.cpp',root/'client/native/transport/src/soundq_transport.cpp']
    command=['clang++','-std=c++17','-O2','-Wall','-Wextra','-Wpedantic','-Werror','-pthread','-I'+str(host),'-I'+str(root/'client/native/transport/include'),'-I'+str(root/'client/native/file_decoder/include'),*includes,*sources]
    for sanitized in (False,True):
        label='sanitized' if sanitized else 'normal'
        executable=build/f'live-host-{label}'
        flags=['-fsanitize=address,undefined','-fno-omit-frame-pointer'] if sanitized else []
        run([*command,*flags,'-o',executable],f'{label}-build')
        for case in ('--blocks','--four','--fractional','--eof'):
            run([executable,case],label+case[1:])
        pcm=logs/f'{label}.pcm'
        run([executable,pcm],label+'-main')
        run(['python3',host/'tests/live_tempo_oracle.py',pcm],label+'-acoustic')
    print('PASS real production workers/DSP/Host continuously rendered. Encoded IO/output are deterministic boundaries; no device deadlines claimed.')


if __name__=='__main__':
    main()
