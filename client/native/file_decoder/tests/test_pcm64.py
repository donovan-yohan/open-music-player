#!/usr/bin/env python3
"""Exercise the actual file decoder with sparse >4GiB SQP1 stages and malformed controls."""
import argparse
import ctypes as C
import json
import struct
import tempfile
from pathlib import Path


def run(library, directory):
    lib = C.CDLL(str(library))
    lib.sq_file_decoder_open.argtypes = [C.c_char_p, C.c_uint64, C.POINTER(C.c_void_p)]
    lib.sq_file_decoder_read_window.argtypes = [C.c_void_p, C.c_int64, C.c_uint32, C.POINTER(C.c_float), C.c_size_t, C.POINTER(C.c_uint32)]
    lib.sq_file_decoder_frame_count.argtypes = [C.c_void_p]
    lib.sq_file_decoder_frame_count.restype = C.c_int64
    lib.sq_file_decoder_destroy.argtypes = [C.c_void_p]
    cases = []
    with tempfile.TemporaryDirectory(prefix='pcm64-', dir=directory) as tmp:
        path = Path(tmp) / 'long.sqpcm'
        frames = 600_000_003  # Exact extent >4GiB, within 24h at 48kHz.
        with path.open('wb') as f:
            f.write(struct.pack('<4sIIIQQ', b'SQP1', 32, 48000, 2, frames, 0))
            f.truncate(32 + frames * 8)
            f.seek(32 + (frames - 2) * 8)
            f.write(struct.pack('<ffff', .25, -.5, -.75, 1.0))
        handle = C.c_void_p()
        assert lib.sq_file_decoder_open(bytes(path), 17_179_869_216, C.byref(handle)) == 0
        try:
            assert lib.sq_file_decoder_frame_count(handle) == frames
            out = (C.c_float * 8)(*([91.] * 8)); got = C.c_uint32()
            assert lib.sq_file_decoder_read_window(handle, frames - 2, 4, out, C.sizeof(out), C.byref(got)) == 0
            assert got.value == 2 and list(out) == [.25, -.5, -.75, 1., 91., 91., 91., 91.]
            cases.append('exact extent and samples beyond signed32-bit byte offset')
            assert lib.sq_file_decoder_read_window(handle, frames, 4, out, C.sizeof(out), C.byref(got)) == 0 and got.value == 0
            cases.append('exact EOF does not overread')
            assert lib.sq_file_decoder_read_window(handle, frames + 1, 1, out, C.sizeof(out), C.byref(got)) == -1
            cases.append('past EOF rejected')
        finally:
            lib.sq_file_decoder_destroy(handle)
        with path.open('r+b') as f:
            f.seek(32 + (frames - 1) * 8); f.write(struct.pack('<ff', float('nan'), 0.))
        assert lib.sq_file_decoder_open(bytes(path), 17_179_869_216, C.byref(handle)) == 0
        try:
            assert lib.sq_file_decoder_read_window(handle, frames - 1, 1, out, C.sizeof(out), C.byref(got)) == -6 and got.value == 0
            cases.append('nonfinite PCM rejected with zero published frames')
        finally:
            lib.sq_file_decoder_destroy(handle)
        for label, header, length in [
            ('truncated exact extent', (b'SQP1', 32, 48000, 2, frames, 0), 32 + frames * 8 - 1),
            ('reserved header rejected', (b'SQP1', 32, 48000, 2, 1, 1), 40),
            ('multichannel rejected', (b'SQP1', 32, 48000, 3, 1, 0), 40),
            ('24h ceiling rejected', (b'SQP1', 32, 8000, 2, 8000 * 86400 + 1, 0), 40),
        ]:
            with path.open('wb') as f:
                f.write(struct.pack('<4sIIIQQ', *header)); f.truncate(length)
            assert lib.sq_file_decoder_open(bytes(path), 17_179_869_216, C.byref(handle)) == -3 and not handle.value
            cases.append(label)
        with path.open('wb') as f:
            f.write(b'RIFF'); f.truncate(134_217_729)
        assert lib.sq_file_decoder_open(bytes(path), 17_179_869_216, C.byref(handle)) == -5 and not handle.value
        cases.append('portable encoded limit preserved')
    return {'cases': cases, 'count': len(cases), 'result': 'PASS', 'boundary': 'actual native file decoder, not platform codec or audible playback'}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.library.resolve(), args.directory), indent=2))
