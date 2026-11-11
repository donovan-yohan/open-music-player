# Native source publication boundaries

## Public source and private execution records

Publish the `android/` product and its required shared `client/native/` source,
not private execution reports, dependency caches, generated builds, local SDK
settings, signing material or account data. `scripts/check-native-payload.py`
checks Git's tracked and nonignored native source inventory for workstation and
agent-storage paths. Accidentally tracked local config, signing/key files,
generated outputs and symlinks fail without reading their contents. Ignored
operational files are not inputs. The checker is a bounded path/portability guard,
not a comprehensive credential detector or a certificate for the whole repository.
The existing delivery harness also scans source for credential-like literals.

Root launchers and optional historical probes take explicit toolchain/cache/temp
roots. See `../README.md`; do not substitute a developer's home directory or a
private report location into public reproduction instructions. Optional probes
retain their actual assertions and historical dependency pins; their failure to
find an old cache is not a passing test.

The appearance input `appearance-w9/INPUTS.json` replaces one workstation prefix
with its logical design identifier. `provenance.json` records the predecessor
hash and the transformed file hash separately. The historical `MANIFEST.json`,
release digest, canonical tokens and generated token bytes are not rewritten.
The nine Catalog response fixtures have their own `wire-hashes.json`; their
producer's historical identity is preserved, not presented as a new producer run.
Exact original provenance and operational receipts remain private with the owner.

## Distributed assets and notices

`app/src/main/assets/licenses/` accompanies the application's native binaries:

| Dependency | Source identity | Distributed notice |
| --- | --- | --- |
| libogg | 1.3.6, archive digest in `client/native/opus_decoder/CMakeLists.txt` | `ogg-COPYING.txt` |
| Opus | 1.6.1, archive digest in the same CMake file | `opus-COPYING.txt` |
| opusfile | 0.12, archive digest in the same CMake file | `opusfile-COPYING.txt` |
| dr_mp3 | Exact vendored header at commit `a9b46d4d91117636015e75e09761299aa1f4283f` | `dr_mp3-NOTICE.txt`, MIT-0/Unlicense alternatives and embedded minimp3 CC0 notice |
| Signalsmith Stretch | Commit `88061fd4eda56a2353c5d65c74aa3f4ccf76f9da`, pinned local archive | `Signalsmith-Stretch-LICENSE.txt`, MIT |
| Signalsmith Linear | 0.6.6, pinned local archive | `Signalsmith-Linear-LICENSE.txt`, MIT |
| Oboe | 1.11.0, pinned archive in `app/src/main/cpp/nativeengine/CMakeLists.txt` | `oboe-LICENSE.txt`, Apache-2.0 |

Signalsmith archive pins and notices are also retained alongside their shared
source. dr_mp3's complete upstream header and notices stay byte-identical; the
app notice is an extracted copy, not a relicensing. The Oboe archive inspected
for this import contains `LICENSE`, not a separate `NOTICE`. Preserve any future
upstream attribution changes when changing the pinned dependency.
Font license files accompany their design input assets; keep those originals
with the distributed fonts. These notices do not replace a transitive dependency
or store-distribution review for a release.

`test-assets.json` enumerates every current file under
`app/src/androidTest/assets/` by exact hash and size. These controlled fixtures
belong to the instrumentation APK, not the ordinary application's media library.
The sine/analysis payloads contain synthetic test content. Their metadata has
been inspected, but metadata inspection is **not audio-runtime qualification**,
nor proof that a generator was rerun. No live-account/provider recording is
introduced by this publication delta. Developer-generated recordings from
optional decoder experiments are not included or licensed by this inventory.

## Validation and remaining release gates

Run `scripts/lint delivery` with an explicit canonical `TMPDIR` for portable
launcher, privacy, inventory and provenance checks. The Delivery Harness CI job
supplies its runner-owned temporary root. `python3 scripts/android-product check`
then performs the separately documented host JNI fixture, unit, assembly and
Android lint gates. A Gradle dry run only validates configuration/task selection;
`BUILD SUCCESSFUL` with `SKIPPED` tasks does not mean compilation or tests passed.

Native Clients CI uploads only named debug/test APKs and bounded test/lint
reports. It does not upload dependency caches or private reports, install apps,
use saved accounts or modify the protected three-image backend/analyzer/stems
release path. Full-source integrated compilation, mounted native journeys,
real-provider behavior, device/audio acceptance, independent final publication
review and any authorized release remain separate gates. Known Jam work in
progress must not be relabeled passing by this tooling-only repair.
