#!/usr/bin/env python3
"""Measure test-only callback MP3 extrema and FFT bands, never product fallback data."""
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np

root = Path(__file__).resolve().parents[1]
asset = root/'app/src/androidTest/assets/callback/frontend.mp3'
rate = 48000
raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(asset), '-f', 'f32le', '-ar', str(rate), '-ac', '1', '-'])
pcm = np.frombuffer(raw, dtype='<f4').astype(np.float64)
count = len(pcm)
columns = 2400
edges = np.linspace(0, count, columns + 1, dtype=np.int64)
minima, maxima = [], []
for start, end in zip(edges[:-1], edges[1:]):
    values = pcm[start:end]
    minima.append(float(np.clip(values.min(), -1, 1)))
    maxima.append(float(np.clip(values.max(), -1, 1)))
# Windowed spectral measurement on the same decoded recording. Three broad
# analysis bands, not stems or a claim of the production MIR model's accuracy.
frequencies = np.fft.rfftfreq(2048, 1 / rate)
bands = [[], [], []]
window = np.hanning(2048)
for start, end in zip(edges[:-1], edges[1:]):
    center = (int(start) + int(end)) // 2
    frame = np.zeros(2048)
    lo, hi = max(0, center - 1024), min(count, center + 1024)
    frame[lo - (center - 1024):hi - (center - 1024)] = pcm[lo:hi]
    spectrum = np.abs(np.fft.rfft(frame * window)) ** 2
    for output, mask in zip(bands, [frequencies < 200, (frequencies >= 200) & (frequencies < 2000), frequencies >= 2000]):
        output.append(float(np.sqrt(spectrum[mask].sum())))
scalar = max(max(b) for b in bands)
assert scalar > 0 and count > 0
bands = [[round(v / scalar, 6) for v in band] for band in bands]
body = {
    'track_id': 1, 'schema_version': 1, 'status': 'analyzed',
    'summary': {},
    'artifacts': {
        'source': {'duration_ms': round(count * 1000 / rate), 'fingerprint': 'fixture-mp3-' + hashlib.sha256(asset.read_bytes()).hexdigest()},
        'waveforms': {'detail': {'minima': [round(v, 6) for v in minima], 'maxima': [round(v, 6) for v in maxima]}},
        'channels': {'channel_set': 'bands3-v1', 'audio_ref': None,
                     'normalization': {'kind': 'shared_peak', 'scalar': scalar},
                     'weights': {'low': 1.0, 'mid': 1.0, 'high': 1.0},
                     'crossovers_hz': {'low_mid': 200, 'mid_high': 2000},
                     'provenance': 'fixture:decoded-mp3-fft-rms-v1',
                     'detail': dict(zip(['low', 'mid', 'high'], bands))}
    }
}
output = asset.with_name('frontend-analysis.json')
output.write_text(json.dumps(body, separators=(',', ':')) + '\n')
print(json.dumps({'sourceSha256': hashlib.sha256(asset.read_bytes()).hexdigest(), 'sourceFrames': count, 'sampleRate': rate, 'columns': columns, 'durationMs': body['artifacts']['source']['duration_ms'], 'analysisSha256': hashlib.sha256(output.read_bytes()).hexdigest()}))
