# SoundQ component studio tools

Source-only recovery of the local component-catalog and visual-baseline tools.
Python 3.10+ standard library only. Run commands from the repository root.
This is a developer workbench over Compose source, not another app or design
system. No captured pixels, environment snapshots, accounts or review verdicts
are included.

## Offline checks

```sh
scripts/test design-studio
scripts/lint design-studio
```

The test target runs the unit suite, the synthetic CLI harness and the lint
target. Lint parses the Python sources, generates a temporary catalog from the
current Android source and checks it for drift. Neither target calls Gradle,
ADB, a browser or a network service. Set `TMPDIR` to an owned scratch directory
to control their temporary files. The shell targets remove their temporary
outputs on exit. Unit-test scratch directories are also removed.

For inspectable synthetic results, choose a new empty output directory:

```sh
python3 -B design-studio/harness.py --output "$TMPDIR/studio-harness-results"
```

The harness executes the real CLI against labeled synthetic Kotlin and PNG
fixtures. Its fixture-only canonical verifier deliberately returns success or
failure to exercise propagation. This is not canonical token verification.
The real catalog commands run the existing `android/scripts/check-design.py`
without import flags, so the sealed Android design inputs remain authoritative.
Mocked capture-transport tests never execute ADB. The snapshot-orchestration
check runs the real canonical verifier and catalog in a private source copy,
then deliberately stops before Gradle. Synthetic test output is not evidence
that native components rendered or that an Android build passed.

## Component catalog

```sh
python3 -B design-studio/studio.py catalog generate
python3 -B design-studio/studio.py catalog check
# Or write both catalog.json and index.html outside the source checkout:
python3 -B design-studio/studio.py catalog generate --output "$TMPDIR/studio-catalog"
python3 -B design-studio/studio.py catalog check --output "$TMPDIR/studio-catalog"
```

The default output is ignored `design-studio/generated/`. The JSON contains
public named `@Composable fun` declarations in the design system, balanced
signatures, source files/lines/hashes, direct and locally aliased SoundQ token
roles, and lexical caller/test/preview references. Overloads stay separate.
The searchable HTML is a source index, not an HTML rendering of components.
It does not import local capture folders or embed absolute host paths.
Receiver extensions and full Kotlin symbol resolution are outside this scanner.

`catalog check` is read-only and rejects stale JSON or HTML. Source identities
are a map from repository-relative input paths to SHA-256 values. They cover
Android source/build/design inputs and the capture producers, excluding caches,
build outputs, local properties and common credential files. The catalog is
local generated state, not a snapshot to commit or a privacy scrubber.

## Bounded adoption checks

```sh
python3 -B design-studio/studio.py check adoption \
  --catalog "$TMPDIR/studio-catalog/catalog.json" \
  --source android/app/src/main/kotlin/path/to/NewFeature.kt
```

Supply actual repository-relative Kotlin files, repeating `--source` as needed.
The example file must be replaced with the file under review. The checker
requires current catalog identities and actual known SoundQ component calls.
It rejects stock buttons/fields and their import aliases, raw color literals,
missing files and escaping paths. Nested comments and strings are masked.
Layout dimensions and ordinary text are allowed.

This is an opt-in lexical guard for a selected new feature. It is not a global
legacy migration or a compiler. The historical trial's mandatory
`HistoryFilterControls.kt` and Gradle `verifyStudioAdoption` hook are deliberately
not restored. Current Home owns its own history search and tabs, including an
intentional native editor. No production file needs changing to use the tools.

## Visual contracts and explicit baseline selection

The retained pipeline uses these JSON contracts:

- A request has `schema`, `sources`, `environment` and exact case IDs.
- A receipt has the same sources/environment, image filenames and SHA-256 values,
  plus its evidence `kind`. Native receipts also require embedded build binding
  and installed/local APK byte equality.
- A baseline records an exact image hash, environment, source identities,
  reviewer name/kind and rationale. Selection is not independent human approval.

```sh
python3 -B design-studio/studio.py visual request \
  --environment "$TMPDIR/studio-environment.json" \
  --request "$TMPDIR/studio-request.json"
python3 -B design-studio/studio.py visual verify \
  --request "$TMPDIR/studio-request.json" --captures "$TMPDIR/studio-captures" \
  --baselines "$TMPDIR/studio-baselines" --output "$TMPDIR/studio-report"
```

The environment input must come from an actual, separately authorized capture
session. No example environment is supplied as native evidence. `visual report`
has the same verification and exit behavior as `visual verify`. Both compare
strictly, with zero channel tolerance and zero permitted changed pixels. The
stdlib decoder handles noninterlaced 8-bit RGB/RGBA PNGs and all five row filters.
Reports contain actual current/baseline/difference images. Verification never
creates or updates a baseline.

Exit 0 means every case matched an existing baseline. Exit 1 means valid input
with differences or unaccepted cases. Exit 2 means invalid, missing or stale
input. A rejected invocation may leave a previous report in place, so check its
exit code. These tools consume trusted local artifacts, not arbitrary hostile
uploads or a cryptographic remote attestation.

After reviewing one real rendered case, use `visual accept` with all of
`--case`, `--sha256`, `--reviewer`, `--reviewer-kind human|agent` and a nonblank
`--rationale`, plus the explicit request/captures/baselines paths. There is no
accept-all action. Agents must identify themselves as `agent`. Unit tests use
an explicit `harness=True` API boundary for synthetic pixels; the public visual
CLI does not offer that bypass.

## Native component capture

The active host is:

```
android/designsystem/src/androidTest/kotlin/com/soundq/designsystem/StudioNativeComponentTest.kt
```

It requests focus, asserts disabled semantics and captures eight mounted
360x600dp component layers at density 2. The matrix is light/dark crossed with
default/disabled/focused/large-text. Large text uses local font scale 2. The host
checks the packaged source binding and actual SDK, fingerprint, model and locale.
Density and font scale are explicit Compose locals, not changed OS settings.
The recovered `pending/StudioNativeComponentTest.kt` remains a historical source
copy, not the consuming test path. The normal Android test source set owns the
active host. No Gradle change or production Activity change is needed.

Building requires explicit `JAVA_HOME`, `ANDROID_HOME` and owned `TMPDIR`.
The builder copies source bytes into a private snapshot, uses a fresh private
`GRADLE_USER_HOME`, runs the canonical design/catalog checks and builds only
`:designsystem:assembleDebugAndroidTest`. It writes `studio-build.json` into
that snapshot's standard Android test assets directory before compilation.
The exported APK and build receipt are validated against current source hashes.
A first build may download dependencies. This is not an offline promise.

The root Gradle configuration also configures `:app`, so supply explicit inert
fixture markers even though no production app is built:

```sh
export OMP_API_BASE_URL=https://fixture.invalid
export OMP_SOURCE_REF=component-studio-fixture
export OMP_BUILD_ID=component-studio-fixture
python3 -B design-studio/build_capture.py
```

Device access requires a separate grant. Set `ADB`, `SERIAL`, `LOCALE` and
`OUT` to an authorized ADB executable, rediscovered device serial, actual locale
and owned output directory. Do not guess a serial or use a connected personal
device. For an agent AVD, verify its AVD name, qemu property and model first.
Preserve an already-installed test APK and check signer continuity before any
replacement. Use the approved Android user home when continuity requires it.
Never uninstall or clear existing data to work around a signer mismatch.

```sh
python3 -B design-studio/native_capture.py environment \
  --adb "$ADB" --serial "$SERIAL" --locale "$LOCALE" --output "$OUT/environment.json"
python3 -B design-studio/studio.py visual request \
  --environment "$OUT/environment.json" --request "$OUT/request.json"
python3 -B design-studio/native_capture.py run \
  --adb "$ADB" --serial "$SERIAL" \
  --apk design-studio/build/designsystem-debug-androidTest.apk \
  --request "$OUT/request.json" --output "$OUT/run"
python3 -B design-studio/native_capture.py collect \
  --adb "$ADB" --serial "$SERIAL" \
  --apk design-studio/build/designsystem-debug-androidTest.apk \
  --request "$OUT/request.json" --output "$OUT/captures"
```

The runner uses `install -r` for only the isolated test package, reads back
installed APK bytes, streams the request into private files with hash readback
and invokes the one capture test. Collection validates the complete archive,
case hashes, current source identities and packaged binding before replacing
an existing collection. The helpers still refuse if the active host is absent.
Run the visual commands above against these actual captures. Select each case
explicitly with an agent or human attribution, then make a second mounted run
and collect it into another directory for strict comparison. Never silently
update baselines. Agent baseline selection is not independent human approval
or a verdict on known product layout gaps.

This path has been compiled, mounted, collected and strictly compared on an
agent-owned Android emulator. `captureToImage` proves a component layer, not an
OS screenshot, physical-phone capture or whole-product journey. Large-text tab
clipping and media-row ellipses remain visible in the retained fixture; the
tool does not change or certify those production layouts. Restore preserved
test APK bytes/signers with `install -r` after collection and release owned
emulator/build resources. Keep all receipts and pixels private and outside the
source publication allowlist.

## Provenance and publication boundary

Recovered from the same project's studio trial commit
`49c052e60d0b28b4f37be64ba96361a3da01c4ed`, adapted to product base
`89fe9cd0d74b9904676ca77c7a3bb543b615b619`. Original Python modules/test methods
and the native host are retained rather than replacing old Android production
source. No third-party asset is added; tiny test images/archives are generated
in owned temporary directories. Existing source notices are preserved. The
trial has no separate tool license header; this recovery adds no new license
grant.

The local allowlist in `.gitignore` keeps generated catalogs, requests,
environments, baselines, captures, HTML reports, APKs, logs and profile/browser
state out of ordinary staging. It does not sanitize files forcibly staged by an
operator. Review exact source paths before publication, not the old trial's
whole directory. Historical screenshots, audio, run logs, local operational
handoffs and agent acceptance claims do not belong in this source contribution.
