#!/usr/bin/env python3
"""Private long tagged fixture + bounded-memory, full-decode sample oracles.

No input-side seeking, fitted offsets, whole PCM file, SDK or Android access.
Run on the host, then explicitly stage output in an isolated app cache directory
for TaggedLongMp3WindowTest (DirectCodecFixtureRunner). Never package the MP3.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--ffmpeg', default='ffmpeg')
    a = p.parse_args()
    out = a.output.resolve()
    repository = pathlib.Path(__file__).resolve().parents[3]
    if out.is_relative_to(repository):
        p.error('Large generated evidence must stay outside source')
    out.mkdir(parents=True, exist_ok=True)
    encoded = out / 'tagged-long.mp3'
    if encoded.exists():
        p.error('Use a fresh output directory; never replace retained evidence')
    # Time-varying phase makes deep-window oracles distinguish wrong offsets.
    signal = 'aevalsrc=0.17*sin(2*PI*(221*t+0.0003*t*t))+0.09*sin(2*PI*131*t):s=32000:d=12600'
    generate = [a.ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', signal,
                '-ac', '1', '-c:a', 'libmp3lame', '-b:a', '48k', '-write_xing', '1', str(encoded)]
    subprocess.run(generate, check=True)
    # Include actual overlapped 48000-frame pages, a cold 3h target, start/flush/tail.
    specs = [(0, 2048), (48000, 2048), (345600000, 2048), (403199500, 500)]
    specs += [(179520000 + n * 48000, 48000) for n in range(4)]
    windows = {first: bytearray() for first, _ in specs}
    reference = [a.ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-xerror', '-i', str(encoded),
                 '-af', 'pan=stereo|c0=c0|c1=c0',
                 '-f', 'f32le', '-acodec', 'pcm_f32le', '-ar', '32000', '-ac', '2', 'pipe:1']
    with (out / 'reference-decode.log').open('wb') as err:
        child = subprocess.Popen(reference, stdout=subprocess.PIPE, stderr=err)
        cursor = 0
        try:
            while True:
                chunk = child.stdout.read(1024 * 1024)
                if not chunk:
                    break
                for first, count in specs:
                    start, end = max(cursor, first * 8), min(cursor + len(chunk), (first + count) * 8)
                    if start < end:
                        windows[first].extend(chunk[start - cursor:end - cursor])
                cursor += len(chunk)
        finally:
            child.stdout.close()
        assert child.wait() == 0, 'Full independent reference decode failed'
    assert cursor == 12600 * 32000 * 8, cursor
    records = []
    for first, count in specs:
        data = windows[first]
        assert len(data) == count * 8
        path = out / f'window-{first}.f32'
        path.write_bytes(data)
        records.append(dict(first=first, count=count, file=path.name, sha256=digest(path)))
    receipt = dict(file=encoded.name, sha256=digest(encoded), bytes=encoded.stat().st_size,
                   rate=32000, channels=1, frames=12600 * 32000,
                   generate=generate, reference=reference, fullDecodeExit=0,
                   referencePcmBytesStreamed=cursor, windows=records)
    (out / 'manifest.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2), flush=True)


if __name__ == '__main__':
    main()
