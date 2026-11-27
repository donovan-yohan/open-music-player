#!/usr/bin/env python3
"""Compare a >30-second encoded audition on the spare native deck with FFmpeg PCM."""
import argparse
from array import array
import math
from pathlib import Path
import subprocess
import sys

from file_oracle_build import build_file_oracle

RATE = 48_000
FRAMES = RATE * 34 + 137  # Not aligned to either a callback block or an MP3 packet.
SILENT_TAIL = 2048


def run(*args, timeout=120):
    subprocess.run([str(arg) for arg in args], check=True, timeout=timeout)


def samples(path):
    pcm = array('f')
    pcm.frombytes(path.read_bytes())
    if sys.byteorder != 'little' and path.suffix == '.decoded':
        pcm.byteswap()
    return pcm


def compare(reference, capture):
    if len(capture) != len(reference) + SILENT_TAIL * 2:
        raise AssertionError(f'wrong capture length: {len(capture)}, reference {len(reference)}')
    maximum = 0.0
    for index, expected in enumerate(reference):
        error = abs(capture[index] - expected)
        if not math.isfinite(error) or error >= 2e-4:
            raise AssertionError(f'PCM mismatch at frame {index // 2}, channel {index % 2}: '
                                 f'{capture[index]} != {expected} (error {error})')
        maximum = max(maximum, error)
    if any(capture[len(reference):]):
        raise AssertionError('non-silent output after exact decoded EOF')
    return maximum


def check_negative_controls(reference, capture):
    previous, cutoff, next_page = (second * RATE * 2 for second in (29, 30, 31))
    for name, replacement in (
        ('replayed 48,000-frame page', capture[previous:cutoff]),
        ('30-second truncation', array('f', [0.0]) * (next_page - cutoff)),
    ):
        bad = array('f', capture)
        bad[cutoff:next_page] = replacement
        try:
            compare(reference, bad)
        except AssertionError as failure:
            if not str(failure).startswith('PCM mismatch at frame '):
                raise
            print(f'PASS negative control ({name}): {failure}')
        else:
            raise AssertionError(f'oracle accepted {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--decoder', type=Path, required=True)
    parser.add_argument('--codec', choices=('wav', 'mp3'), required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    build.mkdir(parents=True, exist_ok=True)
    executable = build_file_oracle(build, args.decoder, 'audition')
    ordinary = build / 'ordinary.wav'
    source = build / f'audition.{args.codec}'
    reference = build / 'audition.decoded'
    capture = build / 'audition.f32'
    ffmpeg = ('ffmpeg', '-nostdin', '-threads', '1', '-v', 'error', '-y')
    run(*ffmpeg, '-f', 'lavfi', '-i', f'sine=frequency=113:sample_rate={RATE}:duration=2',
        '-ac', '2', ordinary)
    # Independent stereo chirps: unlike fixed integer-Hz tones, a page cannot
    # be repeated or swapped without changing the reference after a refill.
    signal = f'aevalsrc=0.10*sin(2*PI*(503*t+1.731*t*t))|0.082*cos(2*PI*(719*t+2.919*t*t)):s={RATE}'
    run(*ffmpeg, '-f', 'lavfi', '-i', signal,
        '-af', f'atrim=end_sample={FRAMES}', '-c:a', 'libmp3lame' if args.codec == 'mp3' else 'pcm_s16le', source)
    run(*ffmpeg, '-i', source, '-f', 'f32le', '-c:a', 'pcm_f32le', reference)
    expected = samples(reference)
    if len(expected) != FRAMES * 2:
        raise AssertionError(f'independent decoder extent does not match fixture: {len(expected) // 2}')
    run(executable, ordinary, source, len(expected) // 2, capture, timeout=240)
    output = samples(capture)
    maximum = compare(expected, output)
    check_negative_controls(expected, output)
    print(f'PASS {args.codec}: {FRAMES} source frames, {SILENT_TAIL} silent post-EOF frames, '
          f'every stereo sample compared, max absolute error={maximum:.8g}')


if __name__ == '__main__':
    main()
