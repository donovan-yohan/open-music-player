#!/usr/bin/env python3
"""Exact production clock body on real Compose runtime; UI nodes only are boundary recorders.
Not mounted Android/Material/gesture/native proof. Compile with the app's pinned Compose plugin.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--generate', type=Path, required=True)
p.add_argument('--source', type=Path, default=ROOT)
a = p.parse_args()
source = a.source / 'app/src/main/kotlin/com/soundq/android/product/FullPlayerClock.kt'
text = source.read_text()
body = text[text.index('/** Presentation only.'):]
# Keep all production declarations/bodies unchanged; replace imports/UI collaborators only.
header = '''package com.soundq.android.clockconsumer
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import com.soundq.android.playback.*
import com.soundq.designsystem.formatSongTime
'''
a.generate.mkdir(parents=True, exist_ok=True)
(a.generate / 'FullPlayerClockExact.kt').write_text(header + body)
(a.generate / 'extraction.json').write_text(json.dumps({'source': str(source), 'sha256': hashlib.sha256(text.encode()).hexdigest(), 'body_sha256': hashlib.sha256(body.encode()).hexdigest(), 'boundary': 'exact production declarations; real Compose runtime/remember/saveable/disposal and real clock projection; recording UI primitives, no Android nodes'}, indent=2))
