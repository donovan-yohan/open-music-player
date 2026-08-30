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

# The 5-stem separation runtime. audio-separator is the pinned inference
# provider; htdemucs_ft remains a coherent Demucs-family four-stem model. Its
# mutable UVR registry is preseeded, while the local-only adapter prevents a
# runtime network refresh or model download.
FROM python:3.11-slim-bookworm AS stems-runtime

WORKDIR /app

ARG AUDIO_SEPARATOR_WHEEL_URL="https://files.pythonhosted.org/packages/8c/ba/24b4a5d2147acf35012758c3de7d910399a55a8a4aa74f7a039af530a00d/audio_separator-0.47.0-py3-none-any.whl"
ARG AUDIO_SEPARATOR_WHEEL_SHA256="756f3b620d78e581a117c6b6d96fe4f0eafc3432ab2824cb11532b4868bfd9a8"
ARG DOWNLOAD_CHECKS_SHA256="d3622e1fa19c161d3cf704927711b453d593a3f1eb0f2e0838c3136907935151"
ARG HTDEMUCS_FT_CONFIG_SHA256="69470b8c1bbd674437b51bc9fb491327a10ab0396b702c93389b9cf750016346"
ARG HTDEMUCS_FT_F7E0C4BC_SHA256="ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066"
ARG HTDEMUCS_FT_D12395A8_SHA256="e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6"
ARG HTDEMUCS_FT_92CFC3B6_SHA256="ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2"
ARG HTDEMUCS_FT_04573F0D_SHA256="f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49"

ENV AUDIO_SEPARATOR_MODEL_DIR=/app/models \
    STEMS_MODEL_DIR=/app/models \
    STEMS_DSP_HELPER=/app/stems_dsp.py \
    STEMS_CONCURRENCY=1

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        build-essential \
        ffmpeg \
        libsamplerate0-dev \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# The complete CPython 3.11/Linux x86_64 closure is committed with the exact
# artifact hash selected for this image. diffq is source-only; its sdist and
# Cython/setuptools/wheel build prerequisites are part of the same hash lock.
COPY cmd/stems-worker/requirements-runtime.txt /tmp/stems-runtime-requirements.txt
RUN printf '%s\n' \
        'Cython==3.3.0 --hash=sha256:e6035b5231a9316edc19d6415f4296fd1d0370e2a165a714b3edc167b9ca00e1' \
        'setuptools==79.0.1 --hash=sha256:e147c0549f27767ba362f9da434eab9c5dc0045d5304feb602a0af001089fc51' \
        'wheel==0.46.3 --hash=sha256:4b399d56c9d9338230118d705d9737a2a468ccca63d5e813e2a4fc7815d8bc4d' \
        > /tmp/stems-build-requirements.txt \
    && python -m pip install --no-cache-dir --require-hashes --no-deps \
        --index-url https://download.pytorch.org/whl/cpu \
        --extra-index-url https://pypi.org/simple \
        -r /tmp/stems-build-requirements.txt \
    && python -m pip install --no-cache-dir --require-hashes --no-build-isolation \
        --index-url https://download.pytorch.org/whl/cpu \
        --extra-index-url https://pypi.org/simple \
        -r /tmp/stems-runtime-requirements.txt \
    && python -m pip check

# Bake every local repo member explicitly. audio-separator checks file existence
# before trying its mutable registry; OMP's adapter never calls that loader path
# and runtime checksum verification is a second fail-closed backstop.
RUN set -eu; \
    mkdir -p /app/models /tmp/audio-separator-wheel; \
    curl -fsSL "$AUDIO_SEPARATOR_WHEEL_URL" -o /tmp/audio-separator-wheel/audio_separator-0.47.0-py3-none-any.whl; \
    echo "$AUDIO_SEPARATOR_WHEEL_SHA256  /tmp/audio-separator-wheel/audio_separator-0.47.0-py3-none-any.whl" | sha256sum -c -; \
    python -m pip install --no-cache-dir --no-deps /tmp/audio-separator-wheel/audio_separator-0.47.0-py3-none-any.whl; \
    python -m pip check; \
    curl -fsSL https://raw.githubusercontent.com/TRvlvr/application_data/main/filelists/download_checks.json -o /app/models/download_checks.json; \
    curl -fsSL https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/htdemucs_ft.yaml -o /app/models/htdemucs_ft.yaml; \
    curl -fsSL https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/f7e0c4bc-ba3fe64a.th -o /app/models/f7e0c4bc-ba3fe64a.th; \
    curl -fsSL https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/d12395a8-e57c48e6.th -o /app/models/d12395a8-e57c48e6.th; \
    curl -fsSL https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/92cfc3b6-ef3bcb9c.th -o /app/models/92cfc3b6-ef3bcb9c.th; \
    curl -fsSL https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/04573f0d-f3cf25b2.th -o /app/models/04573f0d-f3cf25b2.th; \
    echo "$DOWNLOAD_CHECKS_SHA256  /app/models/download_checks.json" | sha256sum -c -; \
    echo "$HTDEMUCS_FT_CONFIG_SHA256  /app/models/htdemucs_ft.yaml" | sha256sum -c -; \
    echo "$HTDEMUCS_FT_F7E0C4BC_SHA256  /app/models/f7e0c4bc-ba3fe64a.th" | sha256sum -c -; \
    echo "$HTDEMUCS_FT_D12395A8_SHA256  /app/models/d12395a8-e57c48e6.th" | sha256sum -c -; \
    echo "$HTDEMUCS_FT_92CFC3B6_SHA256  /app/models/92cfc3b6-ef3bcb9c.th" | sha256sum -c -; \
    echo "$HTDEMUCS_FT_04573F0D_SHA256  /app/models/04573f0d-f3cf25b2.th" | sha256sum -c -; \
    rm -rf /tmp/audio-separator-wheel

COPY cmd/stems-worker/stems_dsp.py /app/stems_dsp.py
COPY cmd/stems-worker/stems_dsp_test.py /app/stems_dsp_test.py

RUN python -m unittest stems_dsp_test
RUN python /app/stems_dsp.py --check \
    && python -c "import json,subprocess,sys; payload=json.loads(subprocess.check_output([sys.executable,'/app/stems_dsp.py','--check'])); assert payload['worker']=='stemsep-worker', payload; assert payload['inference_provider']=='audio-separator', payload; assert payload['inference_provider_version']=='0.47.0', payload; assert payload['model_config_sha256']=='$HTDEMUCS_FT_CONFIG_SHA256', payload; assert len(payload['model_weight_sha256']) == 4, payload; assert payload['ffmpeg'], payload; print('stems identity ok', payload['worker_version'])"

# Real end-to-end separation smoke on synthesized audio: four coherent model stems, the
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
assert manifest['provenance']['inference_provider']['name'] == 'audio-separator', manifest['provenance']; \
assert manifest['provenance']['model']['config']['sha256'] == '$HTDEMUCS_FT_CONFIG_SHA256', manifest['provenance']; \
print('stems separation smoke ok', null_sum['residual_db'], 'dB')" \
    && rm -rf /tmp/stems-smoke.wav /tmp/stems-smoke.json /tmp/stems-smoke

COPY --from=builder /stems-worker /app/stems-worker

RUN useradd --system --uid 10001 --create-home appuser \
    && mkdir -p /app/data /app/tmp \
    && chown -R appuser:appuser /app

# Offline at runtime: every model/registry artifact is baked and the adapter
# rejects any provider path that would fetch a replacement.
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    PIP_NO_INDEX=1

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
