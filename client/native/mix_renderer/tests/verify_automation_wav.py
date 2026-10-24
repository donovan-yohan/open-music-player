"""Execute real native render, decode IEEE-float WAV, every-sample oracle."""
import math
import pathlib
import struct
import subprocess
import sys

executable, output = sys.argv[1:]
subprocess.run([executable, output], check=True)
data = pathlib.Path(output).read_bytes()
assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
assert struct.unpack_from('<HHI', data, 20) == (3, 2, 48000)
assert data[36:40] == b'data'
size, = struct.unpack_from('<I', data, 40)
assert size == 140 * 8 and len(data) == 44 + size
samples = struct.unpack_from('<280f', data, 44)
f32 = lambda n: struct.unpack('<f', struct.pack('<f', n))[0]
expected = []
for t in range(140):
    frame = [0., 0.]
    for deck in range(4):
        start = 3 + deck
        if not start <= t < 123 + deck:
            continue
        local = t - start
        source = 8 + deck + local
        fade = local / 16 if local < 16 else (120-local)/24 if local >= 96 else 1
        if deck % 2:
            fade = math.sin(fade * math.pi / 2)
        stem = (1 if source < 12 else 1-.75*(source-12)/24 if source < 20
                else .75-.25*(source-20)/16 if source < 36 else .5)
        for bus in range(5):
            left = f32((((source + 3*deck + 7*bus) % 31)-15) * (bus+1)/2048)
            live = 1-.5*min(t-7,16)/16 if deck == 0 and bus == 0 and t >= 8 else 1
            for channel, pcm in enumerate([left, f32(-left*.5)]):
                frame[channel] += pcm * live * .5 * fade * stem * .25
    expected.extend(map(f32, frame))
for i, (actual, oracle) in enumerate(zip(samples, expected)):
    assert abs(actual-oracle) < 1e-9, (i, actual, oracle)
print(f'automation WAV: {len(samples)} decoded samples match independent 20-bus oracle')
