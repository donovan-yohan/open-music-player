#!/usr/bin/env python3
"""Independent stdlib WAV PCM decoder + deterministic sample oracle."""
import array
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import wave


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def expected(frame, channel):
    total = 0.0
    for deck in range(4):
        start = (0, 2400, 4800, 9600)[deck]
        end = (48000, 36000, 52800, 55200)[deck]
        if not start <= frame < end:
            continue
        source = frame - start
        if deck == 2 and frame >= 18000:
            source = 3000 + frame - 18000
        for bus in range(5):
            period = 160 + deck * 31 + bus * 13
            phase = source % period
            triangle = 1.0 - 4.0 * abs(phase / period - 0.5)
            sample = f32(triangle * (0.02 * (bus + 1)) * (1.0 if channel == 0 else -0.75))
            gain = 1.0
            if deck == 0 and bus == 0 and frame >= 12000:
                gain = max(0.0, 1.0 - (frame - 12000 + 1) / 240)
            if deck == 3 and bus == 4 and frame >= 24000:
                gain = max(0.5, 1.0 - 0.5 * (frame - 24000 + 1) / 480)
            total += sample * gain
    value = f32(max(-1.0, min(1.0, total * f32(0.1))))
    scaled = value * 32767
    return math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)


def validate(path):
    with wave.open(str(path), 'rb') as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()) == (2, 2, 48000, 60000)
        raw = wav.readframes(60001)
    samples = array.array('h')
    samples.frombytes(raw)
    if sys.byteorder != 'little':
        samples.byteswap()
    assert len(samples) == 120000
    maximum_error = 0
    for i, actual in enumerate(samples):
        want = expected(i // 2, i % 2)
        error = abs(actual - want)
        maximum_error = max(maximum_error, error)
        assert error <= 1, (i // 2, i % 2, actual, want, error)
    assert any(samples)
    assert all(x == 0 for x in samples[55200 * 2:])
    print(json.dumps({'frames': 60000, 'samples_checked': len(samples), 'max_error_pcm16_lsb': maximum_error,
                      'peak_pcm16': max(abs(x) for x in samples), 'tail_silent_from': 55200, 'path': str(path)}))


if __name__ == '__main__':
    if len(sys.argv) == 3:
        result = subprocess.run([sys.argv[1], sys.argv[2]], stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        sys.stdout.write(result.stdout.decode())
        sys.stderr.write(result.stderr.decode())
        assert result.returncode == 0, result.returncode
        validate(Path(sys.argv[2]))
    elif len(sys.argv) == 2:
        validate(Path(sys.argv[1]))
    else:
        raise SystemExit('usage: verify_wav.py [offline_renderer] output.wav')
