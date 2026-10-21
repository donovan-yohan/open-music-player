#!/usr/bin/env python3
"""Real ffmpeg fixture/oracle; library is loaded only in this worker process."""
import argparse
import array
import ctypes as C
import json
import math
from pathlib import Path
import random
import subprocess


def run(argv):
    return subprocess.run([str(x) for x in argv], check=True, capture_output=True,
                          stdin=subprocess.DEVNULL, timeout=90).stdout


def fixtures(directory):
    directory.mkdir(parents=True, exist_ok=True)
    frames = 48000 * 7 + 137
    pcm = array.array('f')
    rng = random.Random(7919)
    for i in range(frames):
        noise = rng.uniform(-0.012, 0.012)
        pcm.extend((0.23*math.sin(2*math.pi*431*i/48000)+noise + (0.4 if i % 17011 == 0 else 0),
                    0.19*math.sin(2*math.pi*997*i/48000)-noise))
    raw = directory / 'input.f32'
    raw.write_bytes(pcm.tobytes())
    stereo = directory / 'stereo.opus'
    run(['ffmpeg', '-v', 'error', '-y', '-f', 'f32le', '-ar', '48000', '-ac', '2',
         '-i', raw, '-c:a', 'libopus', '-b:a', '128k', '-vbr', 'on',
         '-compression_level', '10', '-application', 'audio', '-frame_duration', '20',
         '-ar', '48000', '-ac', '2', stereo])
    reference = run(['ffmpeg', '-v', 'error', '-c:a', 'libopus', '-request_sample_fmt', 'flt', '-i', stereo,
                     '-f', 'f32le', '-c:a', 'pcm_f32le', '-'])
    (directory / 'reference.f32').write_bytes(reference)
    assert len(reference) == frames*8
    packet_info = json.loads(run(['ffprobe', '-v', 'error', '-show_packets',
                                  '-show_streams', '-of', 'json', stereo]))
    packets = packet_info['packets']
    side_data = [item for packet in packets for item in packet.get('side_data_list', [])]
    pre_skip = sum(item.get('skip_samples', 0) for item in side_data)
    end_trim = sum(item.get('discard_padding', 0) for item in side_data)
    encoded_frames = sum(round(float(packet['duration_time'])*48000) for packet in packets)
    assert pre_skip == 312 and end_trim > 0
    # ffprobe's packet durations already shorten the final packet by end trim.
    assert encoded_frames-pre_skip == frames
    (directory / 'expected.json').write_text(json.dumps({'frames': frames, 'pre_skip': pre_skip,
                                                        'end_trim': end_trim}))
    for name, options in [('mono', ['-ac', '1']), ('rate24', ['-ar', '24000'])]:
        run(['ffmpeg', '-v', 'error', '-y', '-i', stereo, *options,
             '-c:a', 'libopus', directory / (name+'.opus')])
    encoded = stereo.read_bytes()
    (directory / 'chained.opus').write_bytes(encoded+encoded)
    (directory / 'junk.opus').write_bytes(b'not an Ogg stream')
    (directory / 'trailing.opus').write_bytes(encoded+b'trailing junk')
    for cut in [1, 30, len(encoded)//2, len(encoded)-50]:
        (directory / ('truncated-'+str(cut)+'.opus')).write_bytes(encoded[:-cut])
    corrupt = bytearray(encoded)
    corrupt[len(corrupt)//2] ^= 0x40
    (directory / 'corrupt.opus').write_bytes(corrupt)
    metadata = directory / 'large.ffmetadata'
    metadata.write_text(';FFMETADATA1\ncomment='+'x'*300000+'\n')
    run(['ffmpeg', '-v', 'error', '-y', '-i', stereo, '-f', 'ffmetadata', '-i', metadata,
         '-map_metadata', '1', '-c:a', 'copy', directory / 'large-tags.opus'])
    link = directory / 'symlink.opus'
    if not link.exists():
        link.symlink_to(stereo)
    return frames


class API:
    def __init__(self, path):
        self.lib = C.CDLL(str(path))
        self.lib.sq_opus_decoder_open.argtypes = [C.c_char_p, C.c_uint64, C.POINTER(C.c_void_p)]
        self.lib.sq_opus_decoder_open.restype = C.c_int
        self.lib.sq_opus_decoder_sample_rate.argtypes = [C.c_void_p]
        self.lib.sq_opus_decoder_sample_rate.restype = C.c_uint32
        self.lib.sq_opus_decoder_channels.argtypes = [C.c_void_p]
        self.lib.sq_opus_decoder_channels.restype = C.c_uint32
        self.lib.sq_opus_decoder_frame_count.argtypes = [C.c_void_p]
        self.lib.sq_opus_decoder_frame_count.restype = C.c_int64
        self.lib.sq_opus_decoder_pre_skip.argtypes = [C.c_void_p]
        self.lib.sq_opus_decoder_pre_skip.restype = C.c_uint32
        self.lib.sq_opus_decoder_read_window.argtypes = [C.c_void_p, C.c_int64, C.c_uint32,
                                                       C.POINTER(C.c_float), C.c_size_t, C.POINTER(C.c_uint32)]
        self.lib.sq_opus_decoder_read_window.restype = C.c_int
        self.lib.sq_opus_decoder_destroy.argtypes = [C.c_void_p]
        self.lib.sq_opus_status_string.argtypes = [C.c_int]
        self.lib.sq_opus_status_string.restype = C.c_char_p

    def open(self, path, limit=1 << 29):
        handle = C.c_void_p(0x1234)
        status = self.lib.sq_opus_decoder_open(str(path).encode(), limit, C.byref(handle))
        return status, handle


def alignment(api, directory):
    expected = json.loads((directory / 'expected.json').read_text())
    frames = expected['frames']
    status, handle = api.open(directory / 'stereo.opus')
    assert status == 0 and handle.value, ('open', status)
    try:
        assert api.lib.sq_opus_decoder_sample_rate(handle) == 48000
        assert api.lib.sq_opus_decoder_channels(handle) == 2
        assert api.lib.sq_opus_decoder_frame_count(handle) == frames
        preskip = api.lib.sq_opus_decoder_pre_skip(handle)
        assert preskip == expected['pre_skip'], preskip
        ref = array.array('f')
        ref.frombytes((directory / 'reference.f32').read_bytes())
        # Out-of-order seeks across pages, codec frames, pre-skip and the trimmed end.
        windows = [(0, 1), (0, 4096), (1, 127), (311, 961), (312, 1000), (959, 1921),
                   (48001, 4096), (frames-200, 4096), (frames, 1024)]
        rng = random.Random(179)
        windows += [(rng.randrange(frames), rng.randrange(1, 8193)) for _ in range(48)]
        worst, square, samples = 0.0, 0.0, 0
        for start, count in windows:
            buffer = (C.c_float * (count*2 + 4))(*([91.0]*(count*2+4)))
            got = C.c_uint32(999)
            result = api.lib.sq_opus_decoder_read_window(handle, start, count, buffer,
                                                        count*8, C.byref(got))
            assert result == 0, ('read', start, count, result)
            assert got.value == min(count, frames-start), (start, count, got.value)
            assert list(buffer[count*2:]) == [91.0]*4
            assert all(buffer[i] == 91.0 for i in range(got.value*2, count*2))
            for i in range(got.value*2):
                delta = abs(buffer[i]-ref[start*2+i])
                worst = max(worst, delta)
                square += delta*delta
                samples += 1
        rms = math.sqrt(square/samples)
        # 80 ms seek preroll restores sample position, not bit-identical infinite history.
        assert worst < 0.003 and rms < 0.0003, (worst, rms)
        print(json.dumps({'alignment_windows': len(windows), 'samples_compared': samples,
                          'frames': frames, 'pre_skip': preskip, 'end_trim': expected['end_trim'],
                          'max_abs_error': worst,
                          'rms_error': rms}))
    finally:
        api.lib.sq_opus_decoder_destroy(handle)


def bounds_and_rejection(api, directory):
    expected = {'mono.opus': -4, 'rate24.opus': -4, 'chained.opus': -4,
                'junk.opus': -3, 'corrupt.opus': -3, 'trailing.opus': -3,
                'large-tags.opus': -5, 'symlink.opus': -2, 'missing.opus': -2}
    expected.update({p.name: -3 for p in directory.glob('truncated-*.opus')})
    for name, status in expected.items():
        got, handle = api.open(directory/name)
        assert got == status and not handle.value, (name, got, status, handle.value)
        assert api.lib.sq_opus_status_string(got) not in (None, b'unknown decoder status')
    for path, limit, code in [('relative.opus', 100, -1), (directory/'stereo.opus', 1, -5),
                              (directory/'stereo.opus', 0, -1),
                              (directory/'stereo.opus', (1 << 29)+1, -1)]:
        status, handle = api.open(path, limit)
        assert status == code and not handle.value, (path, status)
    assert api.lib.sq_opus_decoder_open(None, 100, None) == -1
    assert api.lib.sq_opus_decoder_sample_rate(None) == 0
    assert api.lib.sq_opus_decoder_channels(None) == 0
    assert api.lib.sq_opus_decoder_frame_count(None) == -1
    assert api.lib.sq_opus_decoder_pre_skip(None) == 0
    api.lib.sq_opus_decoder_destroy(None)
    status, handle = api.open(directory/'stereo.opus')
    assert status == 0
    try:
        frames = api.lib.sq_opus_decoder_frame_count(handle)
        buffer = (C.c_float*96004)(*([91.0]*96004))
        for start, count, data, capacity, code in [(-1, 1, buffer, 8, -1),
                (frames+1, 1, buffer, 8, -1), (0, 48001, buffer, 384008, -5),
                (0, 0xffffffff, buffer, 0xffffffffffffffff, -5),
                (0, 1, buffer, 7, -5), (0, 1, None, 8, -1),
                (0, 0, None, 0, 0)]:
            got = C.c_uint32(999)
            result = api.lib.sq_opus_decoder_read_window(handle, start, count, data,
                                                        capacity, C.byref(got))
            assert result == code and got.value == 0, (start, count, result, got.value)
            assert all(x == 91.0 for x in buffer)
        got = C.c_uint32()
        assert api.lib.sq_opus_decoder_read_window(handle, 10, 48000, buffer, 384000,
                                                  C.byref(got)) == 0
        assert got.value == 48000 and list(buffer[96000:]) == [91.0]*4
        assert api.lib.sq_opus_decoder_read_window(None, 0, 1, buffer, 8, C.byref(got)) == -1
        assert api.lib.sq_opus_decoder_read_window(handle, 0, 1, buffer, 8, None) == -1
    finally:
        api.lib.sq_opus_decoder_destroy(handle)
    print(json.dumps({'rejected_files': len(expected), 'bounds': 'passed'}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--generate', action='store_true')
    args = parser.parse_args()
    if args.generate:
        print(json.dumps({'fixture_frames': fixtures(args.fixtures)}))
    else:
        assert args.library and args.library.is_file(), 'native decoder library is not built'
        api = API(args.library)
        alignment(api, args.fixtures)
        bounds_and_rejection(api, args.fixtures)


if __name__ == '__main__':
    main()
