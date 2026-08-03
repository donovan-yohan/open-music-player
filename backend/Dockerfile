# Build stage
FROM golang:1.25-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git ca-certificates

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /server ./cmd/server
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /audio-analyzer ./cmd/audio-analyzer
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /stems-worker ./cmd/stems-worker

# Fast synthetic MIR tests do not need ffmpeg, PyTorch, or the model.
FROM python:3.11-slim-bookworm AS analyzer-test

WORKDIR /app
RUN python -m pip install --no-cache-dir "numpy==2.4.6"
COPY cmd/audio-analyzer/audio_mir.py /app/audio_mir.py
COPY cmd/audio-analyzer/audio_mir_test.py /app/audio_mir_test.py
RUN python -m unittest audio_mir_test.py

# The analyzer owns its heavier MIR runtime independently of the API image.
FROM python:3.11-slim-bookworm AS analyzer-runtime

WORKDIR /app

ARG BEAT_THIS_MODEL_URL="https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt"
ARG BEAT_THIS_MODEL_SHA256="8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ffmpeg \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        "torch==2.8.0" \
        "torchaudio==2.8.0" \
    && python -m pip install --no-cache-dir --no-deps "beat-this==1.1.0" \
    && python -m pip install --no-cache-dir \
        "einops==0.8.2" \
        "librosa==0.11.0" \
        "rotary-embedding-torch==0.9.1"

RUN mkdir -p /app/models \
    && curl -fsSL --retry 3 --retry-delay 2 \
        "$BEAT_THIS_MODEL_URL" \
        -o /app/models/beat_this-final0.ckpt \
    && echo "$BEAT_THIS_MODEL_SHA256  /app/models/beat_this-final0.ckpt" | sha256sum -c -

COPY cmd/audio-analyzer/audio_mir.py /app/audio_mir.py
COPY cmd/audio-analyzer/audio_mir_test.py /app/audio_mir_test.py
RUN python -m unittest audio_mir_test.py
RUN python /app/audio_mir.py --check --model /app/models/beat_this-final0.ckpt
RUN ffmpeg -hide_banner -loglevel error -f lavfi \
        -i "aevalsrc=sin(2*PI*80*t)*exp(-24*mod(t\\,0.5)):s=22050:d=16" \
        -ac 1 /tmp/mir-smoke.wav \
    && python /app/audio_mir.py \
        --model /app/models/beat_this-final0.ckpt \
        /tmp/mir-smoke.wav > /tmp/mir-smoke.json \
    && python -c 'import json; r=json.load(open("/tmp/mir-smoke.json")); assert 118 <= r["bpm"] <= 122 and len(r["beats_ms"]) >= 20, r' \
    && rm -f /tmp/mir-smoke.wav /tmp/mir-smoke.json
RUN ffmpeg -hide_banner -loglevel error -f lavfi \
        -i "aevalsrc=if(lt(t\\,2)\\,0.6*sin(2*PI*100*t)\\,0.2*sin(2*PI*8000*t)):s=22050:d=4" \
        -ac 1 -codec:a libmp3lame -q:a 4 /tmp/spectral-smoke.mp3 \
    && PCM_SAMPLES="$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 /tmp/spectral-smoke.mp3 \
        | awk '{printf "%.0f", $1 * 22050}')" \
    && python /app/audio_mir.py \
        --model /app/models/beat_this-final0.ckpt \
        --waveform-frames 320 \
        --pcm-samples "$PCM_SAMPLES" \
        /tmp/spectral-smoke.mp3 > /tmp/spectral-smoke.json \
    && python -c 'import json,statistics,sys; sys.path.insert(0,"/app"); import audio_mir; pcm=int(sys.argv[1]); decoded=audio_mir.load_beat_this_signal(audio_mir.Path("/tmp/spectral-smoke.mp3")).size; r=json.load(open("/tmp/spectral-smoke.json")); b=r["spectral_bands"]; low=statistics.median(b["low"][20:140]); mid_early=statistics.median(b["mid"][20:140]); high_early=statistics.median(b["high"][20:140]); high=statistics.median(b["high"][180:300]); low_late=statistics.median(b["low"][180:300]); mid_late=statistics.median(b["mid"][180:300]); peaks={name:max(values) for name,values in b.items()}; assert pcm != decoded,(pcm,decoded); assert low > 3*max(mid_early,high_early),(low,mid_early,high_early); assert high > 3*max(low_late,mid_late),(high,low_late,mid_late); assert sum(peak >= 0.99 for peak in peaks.values()) == 1,peaks; assert min(peaks.values()) < 0.8,peaks; print(f"spectral smoke ok pcm={pcm} decoded={decoded} low={low:.4f} high={high:.4f} peaks={peaks}")' "$PCM_SAMPLES" \
    && rm -f /tmp/spectral-smoke.mp3 /tmp/spectral-smoke.json

COPY --from=builder /audio-analyzer /app/audio-analyzer

RUN useradd --system --uid 10001 --create-home appuser \
    && mkdir -p /app/data /app/tmp \
    && chown -R appuser:appuser /app

ENV ANALYZER_MIR_HELPER=/app/audio_mir.py \
    ANALYZER_BEAT_MODEL=/app/models/beat_this-final0.ckpt

USER appuser
EXPOSE 18190
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:18190/health || exit 1
ENTRYPOINT ["/app/audio-analyzer"]

# Fast stem DSP tests: numpy + scipy + ffmpeg only. The crossover math, the
# null-sum guarantee, the opus encoder-uniformity rule, and the artifact
# manifest shape are all provable here, with the separator dependency-injected,
# so a contract regression fails in ~1 minute instead of after a torch build.
FROM python:3.11-slim-bookworm AS stems-test

WORKDIR /app

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir \
        "numpy==2.4.6" \
        "scipy==1.16.3"

COPY cmd/stems-worker/stems_dsp.py /app/stems_dsp.py
COPY cmd/stems-worker/stems_dsp_test.py /app/stems_dsp_test.py

# Enforced license backpressure, not prose: the worker sources must never name
# a checkpoint host outside the allowlist. NC-licensed community checkpoints
# (jarredou MDX23C, LarsNet, MVSep/RoFormer mirrors) must never be bundled,
# mirrored, or auto-fetched. Adding one fails this build.
RUN set -eu; \
    if grep -rniE 'mvsep|larsnet|jarredou|mdx23c|roformer|drumsep' /app/stems_dsp.py /app/stems_dsp_test.py; then \
        echo "non-allowlisted checkpoint source referenced by the stems worker" >&2; \
        exit 1; \
    fi; \
    if grep -roiE 'https?://[a-z0-9.-]+' /app/stems_dsp.py /app/stems_dsp_test.py \
        | grep -viE '(huggingface\.co|dl\.fbaipublicfiles\.com)$'; then \
        echo "non-allowlisted model host referenced by the stems worker" >&2; \
        exit 1; \
    fi; \
    echo "checkpoint source allowlist ok"

RUN python -m unittest stems_dsp_test

# The 5-stem separation runtime. Sibling of analyzer-runtime: same python base,
# same torch-cpu pin, same "bake the model at build time behind a pinned hash"
# rule. demucs 4.1.0 resolves htdemucs through huggingface-hub as safetensors,
# so the bake targets the HF cache rather than a torch-hub .th URL.
FROM python:3.11-slim-bookworm AS stems-runtime

WORKDIR /app

# Verified sha256 of the htdemucs checkpoint demucs 4.1.0 resolves. NOTE: the
# familiar "955717e8" string is the demucs model SIGNATURE, not a hash; using it
# as an expected sha256 would fail this build.
ARG DEMUCS_CHECKPOINT_REPO="adefossez/HTDemucs"
ARG DEMUCS_CHECKPOINT_FILE="955717e8.safetensors"
ARG DEMUCS_CHECKPOINT_SHA256="d9fa14133cfcc034a6758923bb3a8ca9f8dfd0b582134643bbf83f72c17576dd"

ENV HF_HOME=/app/hf-cache \
    STEMS_DSP_HELPER=/app/stems_dsp.py \
    STEMS_CONCURRENCY=1

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ffmpeg \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --no-cache-dir \
        --index-url https://download.pytorch.org/whl/cpu \
        "torch==2.8.0" \
    && python -m pip install --no-cache-dir \
        "demucs==4.1.0" \
        "numpy==2.4.6" \
        "scipy==1.16.3" \
        "soundfile==0.13.1"

# Bake the checkpoint into the image behind an explicit sha256 assert, then pin
# the runtime offline so a running container can never fetch weights.
RUN mkdir -p /app/hf-cache \
    && python -c "from demucs.pretrained import get_model; model = get_model('htdemucs'); assert sorted(model.sources) == ['bass', 'drums', 'other', 'vocals'], model.sources; print('baked htdemucs sources', model.sources)" \
    && CKPT="$(find /app/hf-cache -name "$DEMUCS_CHECKPOINT_FILE" -print -quit)" \
    && test -n "$CKPT" \
    && echo "$DEMUCS_CHECKPOINT_SHA256  $CKPT" | sha256sum -c - \
    && echo "$CKPT" > /app/models-checkpoint.path

COPY cmd/stems-worker/stems_dsp.py /app/stems_dsp.py
COPY cmd/stems-worker/stems_dsp_test.py /app/stems_dsp_test.py

RUN python -m unittest stems_dsp_test
RUN python /app/stems_dsp.py --check \
    && python -c "import json,subprocess,sys; payload=json.loads(subprocess.check_output([sys.executable,'/app/stems_dsp.py','--check'])); assert payload['worker']=='stemsep-worker', payload; assert payload['checkpoint_sha256']=='$DEMUCS_CHECKPOINT_SHA256', payload; assert payload['demucs_version']=='4.1.0', payload; assert payload['ffmpeg'], payload; print('stems identity ok', payload['worker_version'])"

# Real end-to-end separation smoke on synthesized audio: four demucs stems, the
# crossover null-sum bound, and one uniform libopus configuration across every
# emitted file. These are the gates the spec makes acceptance, run at build time
# so a checkpoint or encoder-flag drift cannot ship.
RUN ffmpeg -hide_banner -loglevel error -f lavfi \
        -i "aevalsrc=0.5*sin(2*PI*55*t)*exp(-14*mod(t\\,0.5))+0.2*sin(2*PI*440*t)+0.1*sin(2*PI*6000*t)*exp(-40*mod(t\\,0.25)):s=44100:d=8" \
        -ac 2 /tmp/stems-smoke.wav \
    && STEMS_SEGMENT_SECONDS=7 python /app/stems_dsp.py \
        --out-dir /tmp/stems-smoke --track-id 1 --channel-set stems5-hybrid-v1 \
        /tmp/stems-smoke.wav > /tmp/stems-smoke.json \
    && python -c "\
import json, sys; \
sys.path.insert(0, '/app'); \
import stems_dsp; \
manifest = json.load(open('/tmp/stems-smoke.json')); \
objects = manifest['artifacts']['objects']; \
channels = [obj['channel'] for obj in objects]; \
assert channels == ['vocals', 'melody', 'bass', 'kick', 'perc', 'drums'], channels; \
assert len({obj['key'] for obj in objects}) == 6, channels; \
assert all(obj['bytes'] > 0 for obj in objects), objects; \
null_sum = manifest['artifacts']['null_sum']; \
assert null_sum['residual_db'] <= -80.0, null_sum; \
assert null_sum['passed'], null_sum; \
signatures = {stems_dsp.encoder_flag_signature(stems_dsp.opus_encode_argv(obj['path'] or obj['key'], 44100)) for obj in objects}; \
assert len(signatures) == 1, signatures; \
assert manifest['artifacts']['codec']['sample_rate_hz'] == 48000, manifest['artifacts']['codec']; \
assert manifest['artifacts']['energy']['frame_hz'] == 80, manifest['artifacts']['energy']; \
assert manifest['provenance']['checkpoint']['sha256'] == '$DEMUCS_CHECKPOINT_SHA256', manifest['provenance']; \
print('stems separation smoke ok', null_sum['residual_db'], 'dB')" \
    && rm -rf /tmp/stems-smoke.wav /tmp/stems-smoke.json /tmp/stems-smoke

COPY --from=builder /stems-worker /app/stems-worker

RUN useradd --system --uid 10001 --create-home appuser \
    && mkdir -p /app/data /app/tmp \
    && chown -R appuser:appuser /app

# Offline at runtime: the checkpoint is already baked, and a container that can
# reach huggingface.co could silently drift off the pinned hash.
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

USER appuser
EXPOSE 18290
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -f http://localhost:18290/health || exit 1
ENTRYPOINT ["/app/stems-worker"]

# Keep this final so an unqualified Docker build still produces the API image.
FROM alpine:3.19 AS server-runtime

WORKDIR /app

RUN apk add --no-cache \
        ca-certificates \
        curl \
        ffmpeg \
        py3-pip \
        python3 \
        tzdata \
    && pip3 install --no-cache-dir --break-system-packages yt-dlp \
    && rm -rf /var/cache/apk/*

RUN adduser -D -u 10001 -g '' appuser \
    && mkdir -p /app/data /app/tmp \
    && chown -R appuser:appuser /app

COPY --from=builder /server /app/server

USER appuser
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1
ENTRYPOINT ["/app/server"]
