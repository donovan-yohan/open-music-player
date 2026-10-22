# CI dependency sources

The analyzer and local storage service must be buildable without credentials.
Do not fix an upstream outage by removing checksums, skipping smoke checks,
switching model precision/identity, or pulling an unattributed image mirror.

## Beat This! final0

- Upstream: [CPJKU/beat_this](https://github.com/CPJKU/beat_this), `beat-this==1.1.0`.
- Original checkpoint URL:
  `https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt`.
  It returned HTTP 503 on 2026-10-21, including the manual-download route.
  [Upstream outage report](https://github.com/CPJKU/beat_this/issues/19).
- Available transport: [AEmotionStudio/muscriptor-models checkpoint mirror](https://huggingface.co/AEmotionStudio/muscriptor-models/commit/57db6b00a7c50052b15b0487545b04f22ce2e699),
  immutable revision `57db6b00a7c50052b15b0487545b04f22ce2e699`,
  **only** `shared/beat_this_final0.ckpt`. This is a third-party mirror, not an
  official CPJKU endpoint. A full download was verified byte-for-byte against
  OMP's pre-existing SHA-256, not merely the mirror's metadata.
- Size: `81058141` bytes.
- Unchanged SHA-256:
  `8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331`.
- [Upstream license statement](https://github.com/CPJKU/beat_this/blob/b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c/README.md#license):
  code **and published model weights** are MIT; training-file caveat remains.
  [MIT attribution/license](https://github.com/CPJKU/beat_this/blob/b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c/LICENSE).
  No training audio or other checkpoint is fetched.

`backend/Dockerfile` still verifies SHA-256 before loading the checkpoint and
runs the real model check, synthetic tempo smoke, and spectral smoke. The
runtime still loads its baked local checkpoint. There is no runtime fallback
or new model registry. The mirror cannot substitute a different checkpoint
without failing the existing digest gate.

## MinIO Community Edition

The official `quay.io/minio/minio` and `quay.io/minio/mc` repositories returned
HTTP 401 for anonymous pulls on 2026-10-21, including explicit release tags;
Docker Hub's `minio/minio` also denied pulls. Retagging `latest` does not repair
this. The official CE server is now source-only and archived, not an actively
maintained vendor image. This patch uses upstream's documented **source-build**
path, not a new storage implementation or a third-party binary publisher.

- Server: [RELEASE.2025-10-15T17-29-55Z](https://github.com/minio/minio/releases/tag/RELEASE.2025-10-15T17-29-55Z),
  official commit `9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a`.
  This fixes [GHSA-jjjj-jwhf-8rgr / CVE-2025-62506](https://github.com/minio/minio/security/advisories/GHSA-jjjj-jwhf-8rgr);
  do **not** restore the older September 2025 container.
- Server source archive:
  `https://codeload.github.com/minio/minio/tar.gz/9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a`.
  SHA-256 `45521908307306e925c98d629e1c17d78c8b72b6ee242b1bfb1409f7d8ee5841`.
- Client: [RELEASE.2025-08-13T08-35-41Z](https://github.com/minio/mc/releases/tag/RELEASE.2025-08-13T08-35-41Z),
  official signed tag resolves to commit `7394ce0dd2a80935aded936b09fa12cbb3cb8096`.
- Client source archive:
  `https://codeload.github.com/minio/mc/tar.gz/7394ce0dd2a80935aded936b09fa12cbb3cb8096`.
  SHA-256 `95cd293c7119f16921a6dc515a1fb74a2227f19fd994b9c8b770a154e802ac44`.
- Both components retain their upstream AGPL-3.0-or-later license in the image.
  Source and revision are recorded as OCI labels. The source URLs above provide
  the exact corresponding unmodified application sources; distributors remain
  responsible for [AGPL compliance](https://github.com/minio/minio/blob/9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a/COMPLIANCE.md).
- Builder: official `golang:1.27-alpine` index digest
  `sha256:f2c872bcee949b7be9c490efd02b48a8a2fbf947cdf533f1c58525ec9d8170fd`
  (Go 1.27.3 / Alpine 3.24, verified for amd64 and arm64).
- Runtime: official `alpine:3.24` index digest
  `sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873`.

The `minio-client` and `minio-runtime` Docker targets verify archives **before
extracting/building**, preserve upstream Go module checksums (`go mod verify`,
`-mod=readonly`), build static binaries, and use upstream's entrypoint. Both
Compose files build those targets; no registry login is needed. Data paths,
ports, health checks, init commands, credentials, and bucket policies are
unchanged. Initial source compilation is slower than pulling a prebuilt image;
Docker caches it. Existing persistent volumes are never migrated by this patch.

The archived CE code is not a promise of future security support. Moving to a
maintained fork, AIStor, or a different S3 service is a separate product and
license decision, not a hidden CI workaround.

## Gates

```sh
scripts/lint analyzer            # Includes offline dependency-source regressions
scripts/test analyzer
scripts/build analyzer          # Real checkpoint download/checksum/model/DSP gates
python3 scripts/ci-storage-smoke.py
```

The storage smoke derives only `minio`/`minio-init` from the low-memory Compose
file, ignores `.env`, generates disposable credentials/project identity,
binds a random loopback port, replaces `/data` with tmpfs, and tears down only
its own containers/network. It reads back the initialized bucket's privacy,
then checks authenticated S3 PUT/HEAD/GET/DELETE, exact byte Range/206,
CORS GET/preflight, and anonymous 403. No named production volume, PostgreSQL,
Redis, worker, deploy file, or existing service is used.
