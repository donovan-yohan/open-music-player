# 5-Stem Separation — Implementation Spec (overnight exploration)

## Architecture
# OMP 5-Stem DJ Feature — Architecture Spec (decision-complete)

Authority: docs/stem-architecture.md (#305, epic #302) and docs/adr/0006-stem-edit-events-and-playback-ladder.md are the contract source. This spec implements them; the one deliberate extension (stems5-hybrid-v1) requires an ADR 0006 addendum (see tickets).

## 1. Separation ladder (models, stages, licenses)

**Stage 1 — base 4-stem: htdemucs (DECIDED).**
- Package: `demucs==4.0.1` from PyPI (this IS the adefossez continuation; upstream facebookresearch repo archived). Pin in the worker image; torch CPU `2.8.0` to match the analyzer image pin (backend/Dockerfile:40-48).
- Checkpoint: `htdemucs` 4-stem, file `955717e8-8726e21a.th` from dl.fbaipublicfiles.com, baked at build time with pinned URL + SHA256 assert, exactly like the beat_this bake (backend/Dockerfile:29-30,50-54). MIT code; weights de facto redistributable (universally mirrored, no objection from Meta) — the only residual formal ambiguity, noted in risks. `htdemucs_ft` is NOT the default (4x CPU); it may become an opt-in "final quality" tier later.
- Output channels: vocals, drums, bass, other. Mapping to DJ vocabulary: vocals→**vocal**, other→**melody/instruments**, bass→**bass**.
- Rejected: Spleeter (obsolete, ~5.4 dB), Open-Unmix (~3 dB behind, umxl is NC), BS-RoFormer/SCNet-XL community checkpoints (no explicit weight licenses, minutes-per-track-minute CPU — personal experiment tier only, never bundled).

**Stage 2 — kick/hihat: deterministic DSP crossover on the drums stem (Tier 0, DECIDED for v1).**
- There is no license-clean, quality-passing learned 5-stem or hi-hat model in 2026 (LarsNet CC BY-NC + no code license; jarredou MDX23C CC-BY-NC-SA and source repo 404; MVSep models site-only). The stem-architecture.md verdict stands: learned hi-hat is banned as an audio stem.
- Instead: **kick = LR4 low-pass at 180 Hz of the drums stem (zero-phase, filtfilt of 2nd-order Butterworth); perc ("hihat") = drums − kick, computed sample-exact.** Null-sum reconstruction is guaranteed by construction (kick+perc == drums to numerical precision). This is exactly VirtualDJ's own ModernEQ fallback semantics, and VDJ's "hihat" stem is really "all non-kick percussion" anyway.
- Because this is deterministic DSP (no weights), it sidesteps the license gate entirely, and the quality gate is reframed honestly: kick/perc are "EQ-grade percussion split" — UX labels "Kick (low drums)" and "Hats & Percussion", copy says "mostly removed", never "isolated". Known bounded failures: kick beater click (2-4 kHz) stays in perc; 808/low-tom bodies thump into kick.
- Upgrade path (non-blocking): Tier 1 = inagoy DrumSep HTDemucs fine-tune (MIT repo; weights rehosted in ZFTurbo MSST release v1.0.5, kick 10.52 dB SDR) as `stems5-hybrid-v2`, only after StemGMD-style validation; Tier 2 jarredou MDX23C (kick 16.66 dB) is CC-BY-NC — personal A/B eval only, never shipped or auto-fetched.
- ADR consequence: ADR 0006 says only audio-addressable channel sets accept edits and hi-hat energy overlays never do. The crossover kick/perc ARE real audio artifacts that null-sum to drums, so we define a NEW audio-addressable channel set `stems5-hybrid-v1` = {vocal, melody, bass, kick, perc}, provenance-tagged `derivation: dsp-crossover-lr4-180` for the two derived channels. This needs a short ADR 0006 addendum (ticket below) — it does not violate the "no learned hi-hat stem" verdict, it routes around it.

## 2. Where it runs

- **New worker image** `stems-runtime` stage in backend/Dockerfile (sibling of `analyzer-runtime`, lines 25-95 pattern): python:3.11-slim-bookworm + ffmpeg + torch-cpu 2.8.0 + demucs 4.0.1 + scipy/soundfile; checkpoint baked with SHA256 assert; build-time gates = unit tests + a synthesized-audio separation smoke asserting 4 stems emitted, kick+perc null-sum ≤ −80 dB vs drums, and Opus encode uniformity.
- **New Redis-backed queue class** `stems` copying backend/internal/download/queue.go:14-33 + worker.go:41-67 — NOT the in-process analysis channel (processor.go:60) and NOT the synchronous 90 s analyzer HTTP path (service_client.go:16-19). Env: `STEMS_ENABLED`, `STEMS_BASE_URL`, `STEMS_AUTH_TOKEN`, `STEMS_CONCURRENCY` (default 1), `STEMS_TIMEOUT_MS` (default 1800000). Concurrency 1 on the low-memory host guarantees Beat This / downloads cannot be starved (distinct worker pool, distinct Redis list, bounded depth with reject-when-full backpressure).
- Worker container exposes `POST /separate` + `GET /health` with versioned identity (`stemsep-worker`, version const, channel_set `stems5-hybrid-v1`), bearer auth — cloned from cmd/audio-analyzer/main.go:30-35,186-196. It pulls source audio itself from MinIO by storage_key (main.go:293-316 pattern), writes stem objects + energy curves, returns artifact manifest. Postgres row is the durable status authority (recover-on-restart, same as analysis rows).
- **Trigger: opt-in, on-demand.** `POST /api/v1/tracks/{id}/stems` (idempotent) is called on the user's first stem-edit attempt; plus a maintenance batch-prep endpoint mirroring RequestAnalysisRepair (maintenance.go:87) for explicit "prepare stems" on a crate/playlist — the Serato Stems-crate equivalent. NEVER a library-wide startup sweep (#304, stem-architecture.md:297-299).
- server-mac MLX (35-73x realtime, unvalidated) is a later pure-infra swap: point `STEMS_BASE_URL` at a tailnet worker. Not in scope tonight; x86 container at ~1.5-2x realtime, concurrency 1, is the trickle default.

## 3. Storage layout (MinIO, bucket `audio-files`)

- Base stems: `stems/{track_id}/htdemucs-4s-v1/{vocals,drums,bass,other}.opus` (per #304's decided layout).
- Split pair: `stems/{track_id}/stems5-hybrid-v1/{kick,perc}.opus`. The 5-channel set references the base objects for vocal/melody/bass — vocals/other/bass are NOT duplicated. drums.opus is retained (needed for stems4 edits, null-sum verification, and future re-split with a better kick model without re-running demucs).
- **Codec: Opus 128 kbps VBR, 48 kHz, all six files encoded by the same libopus build with identical settings in the same worker run** — codec uniformity gives identical priming delay, hence sample alignment across the set. FLAC rejected as default (200+ GB tier per #305). Lossy stems are acceptable because Rung A subtracts stems only inside edited ranges (artifacts confined to edited material) and Rung B mixes all stems of one clip so codec error largely cancels perceptually. Footprint: ~3.4 MB/stem for 3.5 min → ~20 MB/track for 6 files (within #305's 4-6x multiplier); opt-in on-demand keeps library totals demand-proportional.
- Per-stem energy curves emitted on the shared 80 Hz frame grid via the slice-1 channel-energy contract (channel sets `stems4-demucs-v1` energies + kick/hihat color channels), filling `channels.audio_ref` — the null-reserved seam at cmd/audio-analyzer/main.go:695,897.
- Derived pre-renders: `derived/{content_hash}.opus`, hash = sha256(sorted events + channelSet + stemModelVersion + sourceFileHash + renderPipelineVersion); deduped; GC'd by bounded sweep when unreferenced by any mix_plan.

## 4. Schema / contract

- **New table `track_stems`** (do NOT overload track_analysis — different lifecycle, model identity, and artifact class): `track_id` FK, `channel_set`, `stem_model_version`, `status` CHECK (pending/separating/ready/failed/stale), `source_file_hash`, `artifacts_json` (object keys, durations, codec+encoder settings, null-sum residual dB), `provenance_json` (worker identity/version, demucs version, checkpoint sha256, crossover params), `error`, requested/started/completed timestamps. Guarded upsert clones StoreResult's expected-identity pattern (audio_analysis_repository.go:286-375); stale-marking by stem model identity clones MarkStaleByAnalyzerVersion. Added via the idempotent Go startup schema in backend/internal/db/db.go per CLAUDE.md.
- **Contract names**: `stems4-demucs-v1` (4 audio channels, per #304) and `stems5-hybrid-v1` (5 audio channels, kick/perc provenance `dsp-crossover`), mirroring `bands3-v1`. Client name→color registry gains the five entries.
- **stemEdits**: exactly the ADR 0006 shape, nested in mix_plans.payload JSONB — schemaVersion 1, channelSet `stems5-hybrid-v1`, stemModelVersion, sourceFileHash, beatGridRef{analysisRef, analysisVersion}; gain-only events (cut = click-safe ramp to −96 dB), half-open source-ms ranges (authoritative), beat indices advisory; solo/"isolate" = gain events on the other four channels (no new event type). Server validation: reject unknown schemaVersion, non-audio-addressable channel sets, hash mismatches; server-side merge preservation so old clients cannot erase unknown stemEdits on read-modify-write. HARD GATE: rejected entirely until #196/#290 single-clip authority lands (ADR 0006 enforcement section).

## 5. Client playback

- **v1 = Rung A, prescribed by the ladder: server-side subtractive pre-render.** output(t) = original(t) − Σ((1−gain_c(t))·stem_c(t)) computed on decoded PCM; preserves the original bit-identically outside edited ranges. Rendered by an ffmpeg-based job in the same worker/queue family; content-addressed derived mixdown; resolved through the existing signed playback descriptor (POST /api/v1/playback/urls, backend/internal/api/playback.go:39,183; docs/SIGNED_AUDIO_URLS.md) so today's mobile engine plays ONE ordinary signed file. Web is covered by this path too.
- **Five synchronized just_audio players: REJECTED** (already decided in #305 — the 150 ms tolerance / 2 s check / 500 ms hard-seek drift model in voice_pool.dart:39-46 is cross-deck machinery and cannot hold <5 ms sibling-stem coherence; one-Voice-per-stem also burns the locked 4-deck cap, timeline_model.dart:269-285).
- **Rung B (later phase): StemGroupVoice** implementing the existing Voice contract (voice.dart:6-51) — all 5 stems of one clip decoded and summed inside ONE flutter_soloud/miniaudio native render callback (zero inter-stem offset by construction), consuming ONE deck slot; per-stem gains are atomics read in the callback, giving <1 audio buffer mute/solo response (the VDJ/Serato fader contract). Rate fixed at 1.0; signalsmith-stretch (MIT) deferred. Ships only with physical-device profiling evidence (Pixel 10 Pro over server-mac ADB). Web excluded from live mixing.
- **Rung C always: honest fallback** — stems pending/failed/absent → play the unmodified original with an "edits not applied" badge derived from the artifact actually resolved; NEVER approximate a stem cut with EQ or volume dips. Client also shows per-track stems state (none/preparing/ready, with queue position) — the VDJ prepared-stems / Serato Stems-crate affordance — and one-touch Acapella (solo vocal) / Instrumental (cut vocal) shortcuts that compile to plain gain events.

## Phased tickets
### Single-clip authority lands before any stemEdits
Pre-existing hard gate, not new work in this feature: verify the unified MixSessionClip/MixPlanClip authority is merged and the lossy toPlaybackJson bridge is retired. Acceptance: ADR 0006 enforcement holds — server rejects any stemEdits payload until this is verified; the stemEdits validation ticket below is blocked-by this issue in GitHub.
(existing: #196 / #290)
### Phase B: stems separation worker + queue class + track_stems + MinIO layout
stems-runtime Docker stage (demucs==4.0.1, torch-cpu 2.8.0, htdemucs checkpoint baked with SHA256 assert, build-time separation smoke); Redis-backed 'stems' queue class cloned from download queue/worker with STEMS_* env, concurrency 1, bounded depth; new track_stems table in db.go with guarded identity upsert + stale-marking; objects at stems/{track_id}/htdemucs-4s-v1/{vocals,drums,bass,other}.opus, uniform libopus 128k/48k; per-stem energy curves emitted as stems4-demucs-v1 channels filling channels.audio_ref; opt-in POST /api/v1/tracks/{id}/stems + maintenance batch-prep endpoint; NO automatic library sweep. Acceptance: queue-isolation test proves Beat This analysis throughput is unchanged while a stems job runs; identity-mismatch results rejected; restart recovers in-flight rows; artifacts_json records codec settings + checkpoint sha; scripts/test backend green.
(existing: #304 (extend, stays within its declared scope))
### stems5-hybrid-v1: crossover kick/perc split + ADR 0006 addendum
In the stems worker, after demucs: kick = zero-phase LR4 low-pass 180 Hz of drums, perc = drums − kick (sample-exact); objects at stems/{track_id}/stems5-hybrid-v1/{kick,perc}.opus; channel set stems5-hybrid-v1 = {vocal, melody, bass, kick, perc} with vocal/melody/bass referencing base objects; kick/hihat energy color channels added to the client name→color registry; ADR 0006 addendum declaring this DSP-derived channel set audio-addressable (learned hi-hat stems remain banned) with the honesty copy ('Kick (low drums)', 'Hats & Percussion', 'mostly removed'). Acceptance: unit test asserts kick+perc null-sums to drums ≤ −80 dB; band-leakage bounds from the bench encoded as worker tests; ADR merged; registry renders five lanes.
(existing: -)
### stemEdits v1 server contract in mix_plans.payload
Validate the ADR 0006 shape on write: schemaVersion=1, channelSet stems5-hybrid-v1 (or stems4-demucs-v1), stemModelVersion, sourceFileHash, beatGridRef; gain-only events, half-open source-ms ranges, cut = ramp to −96 dB; reject non-audio-addressable channel sets, unknown versions, hash mismatches; server-side merge preservation so old clients never erase unknown stemEdits on read-modify-write; solo compiles client-side to gain events on the other channels (no new event type). Blocked-by the single-clip-authority ticket. Acceptance: contract round-trip tests incl. old-client preservation; rejection tests for each guard; docs/MIX_PLAN_TIMING_CONTRACT.md updated via its documented JSONB-first extension path.
(existing: -)
### Rung A: subtractive pre-render worker + content-addressed derived artifacts + signed-URL resolution
Render job in the stems queue family: output = original − Σ((1−gain_c(t))·stem_c(t)) on decoded PCM via ffmpeg from the worker image; derived/{sha256(sorted events + channelSet + stemModelVersion + sourceFileHash + renderPipelineVersion)}.opus; dedupe + bounded GC sweep of unreferenced objects; extend POST /api/v1/playback/urls descriptor to resolve the derived object only when source/model hashes match, else the original + editsApplied=false flag. Acceptance (ADR 0006's required backpressure): golden test — null-edit render is sample-close to the original; deterministic-key test; render failure/retry coverage; descriptor hash-mismatch falls back to original; GC never deletes a referenced object.
(existing: -)
### Client v1: stem lanes, prep state, pre-rendered playback, honest fallback
Desktop-first authoring UI: five stem-colored lanes over the existing waveform stack (stacked_waveform_timeline.dart), gain/cut range editing writing stemEdits; per-track stems state chip (none/preparing with queue ETA/ready) wired to track_stems status — triggering separation on first edit attempt; one-touch Acapella and Instrumental shortcuts; playback swaps in the derived signed file through the existing engine (no engine changes); 'edits not applied' badge driven by the descriptor's editsApplied flag, never inferred. Stems status follows the artifacts refetch-don't-persist rule (queue_persistence.dart:258 precedent). Acceptance: widget tests for badge honesty and state chip; edit round-trip produces a schema-valid stemEdits block; mobile shows merged colored waveform + status without authoring; web plays pre-rendered output.
(existing: -)
### Rung B spike: StemGroupVoice native mixer (flutter_soloud), device-gated
Prototype behind the Voice seam (voice.dart:6-51): one clip's five stems decoded and summed in one flutter_soloud/miniaudio render callback; per-stem gains as atomics for <1-buffer mute/solo with short ramps; consumes ONE slot of the locked 4-deck cap; rate fixed at 1.0 (signalsmith-stretch deferred); deck-to-deck sync stays on the existing drift model. Ship-gate: physical-device profiling on Pixel 10 Pro via server-mac ADB — CPU, memory, battery, audio-focus, seek behavior evidence attached to the PR; web excluded. Acceptance: measured toggle latency < one audio buffer; inter-stem offset zero by construction (verified by null test against Rung A render of the same edits); no regression in 4-deck non-stem playback.
(existing: -)
### Quality/scale follow-ups: server-mac MLX validation + Tier 1 kick model eval
Non-blocking. (a) Validate demucs-mlx htdemucs on server-mac (claimed 35-73x realtime) with PyTorch output-parity checks before pointing STEMS_BASE_URL at the tailnet worker; (b) evaluate inagoy DrumSep (MIT, kick 10.52 dB SDR) against the crossover on the bench tracks + MUSDB18 7-second excerpts for plumbing smoke only (per docs/AUDIO_MIR_EVALS.md line 43) — if it wins audibly, ship as stems5-hybrid-v2 with stale-marking migration; (c) htdemucs_ft as opt-in final-quality tier if MLX validates. Acceptance: parity report; A/B artifacts; no NC-licensed weights (jarredou/LarsNet) ever bundled, mirrored, or auto-fetched.
(existing: -)

## Risks
- License: htdemucs weights have no formal license statement from Meta (issue #327 unanswered) — de facto MIT via universal redistribution, but pin URL+SHA and download at build time rather than mirroring in-repo; jarredou MDX23C (CC-BY-NC-SA, source repo now 404), LarsNet (CC BY-NC weights, NO code license), and all MVSep/RoFormer community checkpoints must never be bundled, mirrored, auto-fetched, or made a default — CI should grep the worker image build for non-allowlisted checkpoint URLs.
- CPU on the low-memory dogfood host: htdemucs ~1.5-2x realtime per track at concurrency 1 means a 4-minute track takes 6-8 minutes and a 20-track batch ties the queue up for hours; swap is already fully used (2.0 GiB) and demucs peaks at several GB RSS — mitigations are STEMS_CONCURRENCY=1 hard default, --segment 7 if the bench shows >6 GB RSS, bounded queue depth with visible reject, and the separate Redis queue class so Beat This and downloads are provably unstarved (the queue-isolation test is acceptance, not optional). Tonight's bench decides go/marginal/no-go for this host.
- Storage growth: ~20 MB/track for the 6-file Opus set (13.5 MB base + kick/perc) plus unbounded derived pre-renders if GC slips — mitigations: strictly opt-in on-demand separation (never library sweep), content-addressed dedupe, bounded GC sweep with a never-delete-referenced test, and a user-visible per-track stems deletion path (the Serato cmd+delete equivalent). Budget honesty: 2,000 fully-separated tracks ≈ 40 GB, but demand-driven reality should be a small fraction.
- Sync drift: five parallel just_audio players CANNOT ship — the drift model (150 ms tolerance / 2 s checks / 500 ms hard-seek) is two orders of magnitude off the <5 ms sibling-stem requirement; Rung A has zero drift by construction (one file) and Rung B gets zero inter-stem offset only if all five stems share one native render callback AND identical codec/encoder settings (mixed encoders' priming delays create fixed offsets — hence the uniform-libopus rule and the null test of Rung B against a Rung A render as acceptance). SoLoud maturity (game-grade resampler, no pitch-preserving stretch, web untested) is hedged by the rate-1.0 MVP and the custom miniaudio/FFI fallback named in #305.
- Kick/hihat split quality: the v1 crossover is EQ-grade, not isolation — kick beater click (2-4 kHz) leaks into perc so a kick-kill can leave a click, and 808/tom bodies leak into kick; learned hi-hat models top out at 3.4-5.1 dB SDR everywhere, so no upgrade path fixes hi-hat solo — UX copy must say 'mostly removed', never 'isolated', and the ADR addendum must keep learned hi-hat stems banned while allowing the DSP-derived pair. If the bench leakage gates fail on 2/3 tracks, pull the Tier 1 inagoy DrumSep (MIT) evaluation forward before shipping the kick/perc lanes.
- Sequencing/contract risk: shipping stemEdits before #196/#290 single-clip authority recreates the lossy-bridge P0 in a third store — the server-side rejection until that gate is verified is load-bearing; likewise the stems5-hybrid-v1 audio-addressability decision extends ADR 0006 and must land as an explicit addendum, not silently in code, or the 'visual channels never accept edits' guard becomes ambiguous.
- Operational: server-mac is a single point of failure and its 35-73x MLX claim is unvalidated (x86 fallback is ~70x slower, ~117 h for a full library — trickle only); demucs upstream is archived with the adefossez fork accepting only bug fixes, so the pinned demucs==4.0.1 + checkpoint sha must be treated as frozen and any bump goes through the stale-marking re-separation path.

## CRITIC CORRECTIONS (authoritative — apply over spec text where they conflict)
- BLOCKING: Checkpoint SHA assertion is wrong: bench step 3 asserts the sha256 'must start with 955717e8', but 955717e8 is the demucs model signature; the verified SHA256 of dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th (downloaded and hashed today) is 8726e21a993978c7ba086d3872e7608d7d5bfca646ca4aca459ffda844faa8b4. As written the bench identity check fails, and copy-pasting the wrong expected hash into the stems-runtime Dockerfile ARG would break the build. Use the full verified hash.
- BLOCKING: demucs pin claim is factually stale: PyPI shows demucs 4.1.0 uploaded 2026-07-11 by the adefossez continuation (requires torch>=2.1 unbounded on Linux, drops torchaudio for sphn, adds huggingface-hub+safetensors), while 4.0.1 is the 2023-09-07 release whose PyPI metadata declares no dependencies and whose torch/torchaudio 2.8 compatibility is unverified. The spec must explicitly re-decide 4.0.1 vs 4.1.0; if 4.1.0, the checkpoint sourcing/bake plan must be re-derived (its HF-hub/safetensors deps suggest the .th URL path may not be how that version loads weights); either way the bench needs a fast import + one-track CLI smoke before the timed runs so a compat failure surfaces in minutes, not after env build.
- BLOCKING: Bench is not runnable tonight as written: /usr/bin/time does not exist on this host (verified), so every '/usr/bin/time -v demucs ...' invocation in step 3 fails and the load-bearing Max RSS gate has no data source. Substitute a Python resource.getrusage/ru_maxrss wrapper or /proc/<pid> VmHWM polling (or install the 'time' package, which needs sudo).
- BLOCKING: Derived-render resolution contract is undefined: POST /api/v1/playback/urls takes only {trackIds, ttlSeconds} (verified in docs/SIGNED_AUDIO_URLS.md and backend/internal/api/playback.go), i.e. it is track-scoped, but a track can carry different stemEdits in different mix plans or none at all. The spec says the descriptor resolves the derived object 'when hashes match' but never defines how the request identifies WHICH edit state/derived content hash to resolve (mixPlanId+clipId ref? explicit content hash?) nor how plain library playback of the same track keeps resolving the original. This must be specified before the Rung A ticket is implementable.
- BLOCKING: Rung A correctness claims need fixing: (a) 'preserves the original bit-identically outside edited ranges' is impossible as specced — the derived artifact is a 48 kHz Opus re-encode of a (typically 44.1 kHz mp3) original; ADR 0006 says 'sample-close', the spec must not overstate it; (b) the spec never states the sample-rate/alignment policy for subtracting 48 kHz Opus stems (with 312-sample pre-skip) from the 44.1 kHz decoded original — this resample/priming alignment is where cancellation quality is actually decided; (c) the null-edit golden test is alignment-blind (null edit degenerates to passthrough), so acceptance needs an alignment-sensitive gate such as an all-stems-full-cut render residual bound or a decoded-stem-sum vs original alignment check.
- BLOCKING: Stems energy-curve delivery path is unspecified: channels.audio_ref lives in the analyzer-written track_analysis payload (verified nil at backend/cmd/audio-analyzer/main.go:~695,~897), but the stems worker is a separate service writing track_stems. The spec never says where the stems4-demucs-v1 energy matrices are stored (track_stems.artifacts_json? a MinIO artifact? a track_analysis update?), which endpoint the client fetches them from, or how audio_ref gets populated without re-running the analyzer. Client stem-lane rendering depends on this seam being defined.
- refinement: Bench step 1 listing will show mostly/only 16 KiB test fixtures: 'mc ls -r omp/audio-files/tracks/ | head -30' lists fixture/*.wav alphabetically before youtube/; real 3.6-4.9 MB mp3s live under tracks/youtube/ (verified live on localhost:9000 with the .env minioadmin creds). List tracks/youtube/ directly or sort by size when picking the 3 bench tracks.
- refinement: Disk headroom risk: root filesystem is 97% full with 7.6 GB free; the bench needs roughly 3-5 GB (torch-cpu install + uv cache + ~1.5 GB of stem/derived wavs + 80 MB checkpoint). Point UV_CACHE_DIR at the scratchpad, prune docker build cache, and re-check df before the timed runs.
- refinement: Section 2 states '~1.5-2x realtime x86' as fact, but it is exactly what tonight's bench exists to measure; the repo's own citation (demucs.cpp ~1x realtime on a Ryzen 5950X, docs/stem-architecture.md:52-54) suggests this 8-vCPU Proxmox host may land MARGINAL. Reword as hypothesis-with-gates, which the bench pass/fail table already handles.
- refinement: STEMS_TIMEOUT_MS=1800000 implies a 30-minute synchronous HTTP POST /separate; that mirrors the analyzer's 90 s pattern at 20x the fragility (connection resets, future tailnet proxies). Either document idempotent-retry semantics backed by the Postgres row authority, or switch to submit/poll before pointing STEMS_BASE_URL at server-mac.
- refinement: track_stems schema: define the uniqueness key (track_id, channel_set, stem_model_version) and the staleness trigger when the source object changes (source_file_hash / storage_key version mismatch after a re-download), mirroring how playback.go already tracks storageKeyVersion.
- refinement: Channel-name registry inconsistency: stems4-demucs-v1 uses demucs names (vocals/drums/bass/other — matching the ADR 0006 example event 'channel: vocals'), while stems5-hybrid-v1 uses DJ names (vocal/melody/bass/kick/perc), and the spec alternates between 'hihat' and 'perc' for the same channel. Define the canonical wire names per channel set and the alias map in one place so edit events, energy channels, and the client color registry cannot diverge.
- refinement: Rung B decode gap to verify before locking Opus everywhere: flutter_soloud/miniaudio has no built-in Opus decoder (wav/flac/mp3/ogg-vorbis only), so 'five stems decoded in one soloud callback' is not implementable as written without an FFI libopus decode stage or on-device transcode. Doesn't change storage today, but record it in the Rung B spike ticket since codec-uniformity-for-priming is partly Rung-B-motivated.
- refinement: Derived .opus playability: just_audio on iOS (AVPlayer) does not play Ogg/Opus natively; Android and web are fine. If iOS is in the client's shipped matrix, verify or choose an AAC/m4a container for derived pre-renders; otherwise state that derived-artifact playback is Android/web-scoped for now.
- refinement: Tier 1 DrumSep license: 'MIT repo; weights rehosted in ZFTurbo MSST release' does not license the weights — the same code-license-is-not-weights-license trap the spec itself flags for RoFormer. The follow-up ticket should require primary verification of the DrumSep checkpoint's own terms before any stems5-hybrid-v2 work.
- refinement: The CI grep for non-allowlisted checkpoint URLs appears only in the risks prose; move it into the Phase B ticket acceptance so it becomes enforced backpressure per the repo's doctrine-is-not-backpressure rule.
- refinement: htdemucs weights license remains formally unresolved (facebookresearch/demucs issue #327 posture is asserted, not re-verified here); the mitigation (build-time download, pinned URL+SHA, never mirrored in-repo) is sound and consistent with docs/stem-architecture.md — keep it, and record the verified full SHA256 in the ADR addendum for provenance.

## Bench results
(inserted before implementation starts — see bench_results.json)
### Bench results (this host, 2026-08-03, demucs 4.1.0 + torch-cpu 2.8.0, 8 cores)
- 3 real library tracks (incl. a 136.8s EDM remix): wall 0.65-0.94x realtime CPU, Max RSS 1.7-2.3 GB, rc=0 all.
- Kick/perc LR4-180Hz crossover null-sum vs drums: -120 dB (numerically exact) on all 3.
- Opus 128k 48kHz, 6 stems/track: ~19 MB/track.
- Checkpoint: huggingface adefossez/HTDemucs 955717e8.safetensors sha256=d9fa14133cfcc034a6758923bb3a8ca9f8dfd0b582134643bbf83f72c17576dd (demucs 4.1.0 fetches via huggingface-hub — Dockerfile must bake the HF cache dir, NOT a torch-hub .th).
- VERDICT: x86 trickle path viable at concurrency 1; spec's CPU assumptions were conservative.

## 2026-08-30 implementation addendum — audio-separator runtime

This addendum is the current implementation authority for the separation
provider, model identity, object layout, and operational performance claim. It
preserves the preceding exploration, decisions, tickets, risks, critic
corrections, and 2026-08-03 benchmark as research history.

The dedicated `stems-runtime` image now uses `audio-separator==0.47.0` as the
inference provider with the SHA-verified `htdemucs_ft` bag. `htdemucs_ft` is
still a Demucs-family four-stem model; it maps exactly `vocals`, `drums`,
`bass`, and `other` (the UI calls `other` `melody`). The provider wheel, mutable
UVR registry, model configuration, and four weights are fetched only during
the image build and checked by SHA-256. The adapter rechecks the local bundle
at readiness and before inference, and rejects provider download/refresh
paths. Health and manifest provenance record provider/version, exact
wheel/registry/config/weight hashes, output mapping, CPU device, and worker
version; the API validates that identity before handlers or queue consumers
start.

The channel-set IDs and their edit vocabulary are unchanged, but their current
immutable model identities are `audio-separator-htdemucs-ft-4s-v1` for
`stems4-demucs-v1` and `audio-separator-htdemucs-ft-4s-v1+lr4-180` for
`stems5-hybrid-v1`. Every new object uses the complete requested model identity:

```text
stems/{track_id}/audio-separator-htdemucs-ft-4s-v1/
  {vocals,drums,bass,other}.opus
stems/{track_id}/audio-separator-htdemucs-ft-4s-v1+lr4-180/
  {vocals,other,bass,drums,kick,perc}.opus
```

The v5 set therefore no longer references an older base prefix; all six keys
are disjoint from legacy `htdemucs-4s-v1`/`stems5-hybrid-v1` objects. Existing
ready rows keep their stored version and are model-changed/stale rather than
rewritten. The worker retains the LR4 split, its -80 dB null-sum guard, one
uniform libopus encode configuration, energy curves, and manifest contract.
The provider has a WAV file boundary; its least-mutating normalization and
amplification options are used before OMP-owned DSP/encoding.

The historical 2026-08-03 Demucs performance numbers above do not describe
this provider/model bag and must not set its capacity. Runtime concurrency is
hard-fixed at `1` pending representative three-track CPU RSS and realtime
factor evidence. Offline readiness was manually verified with
`docker run --rm --network none --entrypoint python omp-stems-runtime-audio-separator:verify /app/stems_dsp.py --check`; this is evidence, not CI backpressure.

Modern specialist vocal, instrumental, and drum-component routes remain
future evaluation work only. They are neither bundled nor fetched by this
runtime and require independent license, quality, immutable-identity, and
stale-transition review.
