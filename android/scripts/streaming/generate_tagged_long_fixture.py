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
    p.add_argument('--observed-cold-resume', action='store_true',
                   help='48k stereo/320k tagged Xing at the observed 2018594ms bookmark; stage as tagged-cold-resume-fixture')
    a = p.parse_args()
    out = a.output.resolve()
    repository = pathlib.Path(__file__).resolve().parents[3]
    if out.is_relative_to(repository):
        p.error('Large generated evidence must stay outside source')
    out.mkdir(parents=True, exist_ok=True)
    cold = a.observed_cold_resume
    rate, channels, seconds = (48000, 2, 2100) if cold else (32000, 1, 12600)
    encoded = out / ('tagged-cold-resume.mp3' if cold else 'tagged-long.mp3')
    if encoded.exists():
        p.error('Use a fresh output directory; never replace retained evidence')
    # Time-varying phase makes deep-window oracles distinguish wrong offsets.
    signal = f'aevalsrc=0.17*sin(2*PI*(221*t+0.0003*t*t))+0.09*sin(2*PI*131*t):s={rate}:d={seconds}'
    generate = [a.ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i', signal,
                '-ac', str(channels), '-c:a', 'libmp3lame', *(['-threads', '1'] if cold else []), '-b:a', '320k' if cold else '48k', '-write_xing', '1', str(encoded)]
    subprocess.run(generate, check=True)
    tag_relabel = False
    if cold:
        # Deliberate grammar fixture: LAME CBR writes Info. Keep its genuine
        # gapless fields/counts and every encoded audio byte, but select Xing's
        # exact-header path just like the reported original (never its TOC).
        with encoded.open('r+b') as f:
            head = f.read(10)
            start = 10 + sum(b << (7 * (3-i)) for i,b in enumerate(head[6:10])) if head[:3] == b'ID3' else 0
            f.seek(start + 36)
            assert f.read(4) == b'Info'
            f.seek(start + 36);f.write(b'Xing');tag_relabel = True
    # Include actual overlapped 48000-frame pages, a cold 3h target, start/flush/tail.
    specs = [(0, 2048), (48000, 2048), (345600000, 2048), (403199500, 500)]
    specs += [(179520000 + n * 48000, 48000) for n in range(4)]
    if cold:
        specs = [(0, 2048), (96864000, 2048), (96912000, 2048), (96892512, 2048)]
    windows = {first: bytearray() for first, _ in specs}
    reference = [a.ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-xerror', *(['-threads', '1'] if cold else []), '-i', str(encoded),
                 *([] if channels == 2 else ['-af', 'pan=stereo|c0=c0|c1=c0']),
                 '-f', 'f32le', '-acodec', 'pcm_f32le', '-ar', str(rate), '-ac', '2', 'pipe:1']
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
    assert cursor == seconds * rate * 8, cursor
    records = []
    for first, count in specs:
        data = windows[first]
        assert len(data) == count * 8
        path = out / f'window-{first}.f32'
        path.write_bytes(data)
        records.append(dict(first=first, count=count, file=path.name, sha256=digest(path)))
    receipt = dict(file=encoded.name, sha256=digest(encoded), bytes=encoded.stat().st_size,
                   rate=rate, channels=channels, frames=seconds * rate,
                   generate=generate, reference=reference, fullDecodeExit=0,
                   referencePcmBytesStreamed=cursor, windows=records)
    if cold:
        receipt.update(bookmarkMs=2018594, encodedTag='Xing', tagRelabeledFromInfo=tag_relabel,
                       scope='Synthetic CBR encoded source with genuine encoder trim; only Info label changed to Xing, not user media')
    (out / 'manifest.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2), flush=True)


if __name__ == '__main__':
    main()
