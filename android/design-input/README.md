# Provisional frozen design input

Read-only snapshot of `design/mobile-2026-10-28/hotate`; see `manifest.json` for exact hashes and capture time. No symlinks or dependency on the moving authoring directory. Only this source bundle authors numerical values. Font choices remain proposed, not user-approved.

`python3 -B scripts/check-design.py` verifies the bundle, licensed font/logo copies, unchanged exporter and native generated output. `--import-output` regenerates that output from this bundle only. Updating the bundle is an explicit review operation: copy the new source/exporter/output/assets together, verify font provenance and replace manifest hashes. Do not tune generated Kotlin independently.

The corrected canonical exporter maps `.letterSpacing.` to `TextUnit` via `sp`. See the frozen `evidence/compose-input-binding.json`. Typography sizes, tracking and line heights use native TextUnit and remain scalable. The earlier dp mapping was superseded before the foundation source freeze.
