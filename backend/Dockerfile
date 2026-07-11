# Build stage
FROM golang:1.25-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git ca-certificates

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /server ./cmd/server
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /audio-analyzer ./cmd/audio-analyzer

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
