#!/usr/bin/env python3
"""Generate synthetic direct-original Android codec fixtures and independent windows.
No personal audio, Gradle, SDK or device operation. ffmpeg must be on PATH.
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
codecs = [('wav', ['-c:a', 'pcm_s16le']), ('mp3', ['-c:a', 'libmp3lame', '-b:a', '128k', '-reservoir', '0', '-write_xing', '0', '-id3v2_version', '0']), ('m4a', ['-c:a', 'aac', '-b:a', '128k']), ('flac', ['-c:a', 'flac']), ('ogg', ['-c:a', 'vorbis', '-strict', '-2', '-ac', '2', '-q:a', '5']), ('opus', ['-c:a', 'libopus', '-b:a', '96k'])]
records = []
for suffix, options in codecs:
    file = root / ('tone.' + suffix)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=500:sample_rate=32000:duration=2', '-ac', '1', *options, str(file)], check=True)
    facts = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=sample_rate,channels', '-of', 'json', str(file)]))
    rate = int(facts['streams'][0]['sample_rate'])
    channels = int(facts['streams'][0]['channels'])
    raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(file), '-ac', str(channels), '-ar', str(rate), '-f', 'f32le', '-'])
    # Android's MP3 decoder exposes zero decoder delay: C2SoftMP3 trims the
    # ISO/PV decoder's 529 leading samples and appends 529 zeros at decoded EOS.
    # FFmpeg's headerless reference includes that decoder delay. Normalize this
    # documented decoder convention, not measured output alignment; all source
    # windows, frame counts and PCM error thresholds remain unchanged.
    if suffix == 'mp3':
        delay_bytes = 529 * channels * 4
        raw = raw[delay_bytes:] + bytes(delay_bytes)
    frames = len(raw) // (4 * channels)
    windows = [2048, frames - 4096]
    for first in windows:
        samples = struct.unpack_from('<' + str(1024 * channels) + 'f', raw, first * 4 * channels)
        stereo = [v for sample in samples for v in (sample, sample)] if channels == 1 else samples
        (root / f'{suffix}-{first}.f32').write_bytes(struct.pack('<2048f', *stereo))
    records.append(dict(file=file.name, rate=rate, frames=frames, windows=windows))
# One independent MPEG frame, no Xing/ID3 or reservoir dependency. Repeat at
# runtime to construct a real >128MiB, 3.5h original without a giant test APK.
raw = (root / 'tone.mp3').read_bytes()
assert raw[:2] == b'\xff\xfb', raw[:4]
frame_bytes = 576  # MPEG1 Layer III, 128kbps, 32kHz, no padding
frame = raw[20 * frame_bytes:21 * frame_bytes]
assert len(frame) == frame_bytes and frame[:2] == b'\xff\xfb'
(root / 'repeatable-mp3-frame.bin').write_bytes(frame)
(root / 'manifest.json').write_text(json.dumps(records, indent=2) + '\n')
print(f'Generated {len(records)} codecs, sample windows, and one repeatable MP3 frame in {root}')
