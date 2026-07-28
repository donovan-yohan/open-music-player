# VirtualDJ comparison export

Use a local VirtualDJ desktop install to analyze a copy of the benchmark audio.
Add or drag the benchmark folder into VirtualDJ, then right-click the folder and
choose **Batch Analyze for BPM etc**. Let it finish before copying its
`database.xml`. Set key display to Musical for names such as `Am`/`F#`, or
Harmonic for Camelot values such as `8A`; the exporter accepts both.

The usual database location is `%USERPROFILE%\\Documents\\VirtualDJ\\database.xml`
on Windows (an external writable drive can instead contain
`<drive>:\\VirtualDJ\\database.xml`) and
`~/Library/Application Support/VirtualDJ/database.xml` on macOS. Windows
Documents redirected through OneDrive or a custom library location can move it.

From the repository root, map the path that VirtualDJ recorded to the local
audio copy and then score the result:

```bash
uv run --frozen --project evals/audio_mir \
  python -m audio_mir_eval.vdj_export \
  --database "$HOME/Library/Application Support/VirtualDJ/database.xml" \
  --manifest /path/to/manifest.jsonl \
  --audio-root-map 'C:\Users\you\Music=/path/to/audio' \
  --output /tmp/vdj-predictions.jsonl

scripts/eval audio-mir score \
  --manifest /path/to/manifest.jsonl \
  --predictions /tmp/vdj-predictions.jsonl \
  --output /tmp/vdj-report.json
```

VirtualDJ commonly stores `Scan Bpm` as beat period in seconds. `auto` treats
values below 30 as periods; use `--bpm-encoding period` or `bpm` to force an
interpretation. The selected interpretation is retained per prediction and in
the run metadata included by the score report.

VirtualDJ's XML does not provide an unambiguous bar phase. When it has a beat
anchor and duration, the exporter synthesizes a constant-tempo beat grid; it
does not emit downbeats by default. `--assume-44-bars` emits every fourth beat
and marks that assumption, so treat downbeat scores as best-effort until a real
database export confirms the semantics. Non-WAV duration probing uses `ffprobe`.

This uses your locally licensed VirtualDJ desktop installation to analyze files
you own. VirtualDJ is not part of the OMP ingest or runtime path.
