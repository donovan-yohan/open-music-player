# Direct-original streaming checks

`run_host_checks.py --build <private-scratch> --java-home <full-JDK>` runs the
ASan/UBSan native matrix, the real JNI/Host/WorkerDeck/Engine with a generated
source peer, the production platform window loop with declared Android facades,
and typed source custody/version controls. Supply existing serialization and
JUnit jars explicitly to run the actual store/binding regressions. It does not
run Gradle, mutate its caches, open a device or use personal audio.

The JNI fixture substitutes OS output and the encoded portable decoder only.
The generated peer is an explicit PCM source, not evidence of Android codec
speed. The first-audio oracle checks every produced sample at a three-hour
initial cursor, before decoded EOS. A held obsolete seek fails independently
while the successor target remains usable. Failed concrete close retains
identity, decoder admission and the native singleton. The failure case runs in
its own JVM and is expected to refuse close.

`WholePrepareDesiredProbe.kt` is an intentionally RED diagnostic for the
retained `PhoneAudioStage` + `AndroidPlatformAudioStage`. Compile it with the
released diagnostic's original Media/Access facades. It proves first PCM exists
while source admission is still gated by held tail/EOS. Do not include it in a
passing fixture glob. The corresponding GREEN platform probe uses explicit
bounded `read` requests, and never asks for the held tail merely to return PCM.

## Android runtime acceptance

Build the direct codec cohort with
`-POMP_TEST_RUNNER=com.soundq.android.DirectCodecFixtureRunner` and select each
intended `class#method` explicitly, including the tagged bookmark control
below. The runner substitutes plain `android.app.Application`, not
SoundQApplication.
ProductFixtureRunner starts the product graph/controller/service and already
owns the native singleton even in an otherwise separate test invocation. Do not
force-close that healthy service to make a direct JNI test pass. Service
integration stays on CallbackFrontendFixtureRunner in a separate cohort.
Read the assembled test APK manifest to verify the registered runner, preserve
both exact APKs, and obtain explicit build/device authority before execution.

`PhonePlatformWindowTest` is instrumentation, not a host pass. It exercises:

- AAC/M4A, MP3, FLAC, WAV, Opus and Vorbis against independent ffmpeg float
  windows, out of order, with mono duplication preserved.
- A generated sparse 3.5-hour WAV with exact first/deep-seek sample values.
- A real >128MiB, 3.5-hour CBR MP3 made from an independent repeatable frame,
  primed at three hours through the production native callback output.
- Explicit descriptor offsets/lengths and same-path replacement refusal.

Only generated app-private originals are deleted by the fixture. The ordinary
source lease has no unlink capability. Generate the small assets with
`generate_fixtures.py android/app/src/androidTest/assets/streaming-codecs`.
The installed ffmpeg's native experimental Vorbis encoder is used for its
stereo fixture; oracle PCM comes from a separate decode, not invented samples.

## Meaning of the endpoints and budgets

`PcmReader.endFrames() == 0` and ordinary `PagedSource.frames == 0` explicitly
mean unknown/unsealed end. A positive value is exact. Resident page coverage and
MediaStore duration hints never become exact frames. Same-generation EOS seal
replaces the final window and rate atomically without minting a traversal;
only callback consumption crossing that sealed endpoint emits natural end.
Finite arrangement admission stays exact.

One outstanding fill, the existing eight 48k-frame pages, bounded codec carry,
a bounded speed cache and the process-wide four-decoder permit remain in force.
Platform peers are included, including failed concrete closes. Positioned reads
are limited to the asset range, 32MiB and 8192 calls per open/seek/window, with a
15-second operation deadline and at most two seconds of discarded preroll.
MP3 exact indexing additionally has a lexical lease/operation-bound structural
capability: <=16 bytes/request, <=4096 steps between full fd/path/route checks,
and full validation at successful scan return. Revocation/deadline/work are
checked every step. Header bytes/calls/work are separately finite for the existing
24-hour seek range and share the unchanged operation deadline; they are included
in total read counters. Payload/extractor allowances above are unchanged.
These are refusal bounds, not a promise that vendor framework calls are
interruptible. Unindexed/unsupported random seeks fail visibly; there is no
whole-prefix replay, PCM-file fallback or second audible player.

Strict >10-minute bookmark eligibility is established by a decoded sample
witness just beyond the integer-millisecond threshold. This is a bounded
indexed seek, not trust in a duration estimate and not decoding the prefix.
Actual first-audio latency including this probe must be measured on Android.
An out-of-range witness with no decoded output and EOS means eligibility is not
established; it does not seal an endpoint. Open logically seeks to source zero
afterward. The codec flush waits for the first read, where a nonzero seek can
perform the same reset instead of flushing twice without intervening decode.
Ordinary arbitrary-seek unmapped EOS still fails; read errors, revocation and
bounded-decoder failures are not converted to a short-source result.

The SDK/Gradle-free focused regressions use <=512MiB/one-core JVMs. Run from
the repository root with `kotlinc` on `PATH`, `JAVA_HOME` exported as the
absolute path to a full JDK, and `TMPDIR` exported as a writable private
directory with a canonical absolute path (`pwd -P`). Use a fresh output
directory for each invocation:

```sh
python3 android/scripts/streaming/run_eligibility_checks.py --output <new-output> --java-home <full-JDK>
python3 android/scripts/streaming/run_direct_fixture_checks.py --output <new-output> --java-home <full-JDK>
python3 android/scripts/streaming/run_mp3_metadata_checks.py --output <new-output> --java-home <full-JDK>
```

The first compiles the production reader against declared Android
facades: empty witness EOS, exact sample/end recovery, arbitrary seek refusal,
source-read failure, revocation, decode budget and the retained long-source
control. The second extracts the actual MP3 test method and supplies explicitly
failing JNI collaborators to prove cleanup before handle acquisition, primary
failure/suppression and failed-custody retention. It also checks the actual
direct runner's Application substitution against a framework facade. Neither
script is Android codec, service, output or acoustic acceptance.

To also run fresh zero and bookmarked startup through the real JNI worker and
callback publication, pass `--jni-dir <private-jni-build>` to the eligibility
runner. Configure that host build with `SOUNDQ_CALLBACK_TESTS=ON` and
`SOUNDQ_CALLBACK_JNI_TESTS=ON` and build `soundq_streaming_jni` with the same
full JDK. The test holds the fourth page, checks first consumed stereo PCM and
the subsequent backward seek, and counts all startup flushes through first
callback consumption against a synthetic codec that requires a flush before
decoding. This proves work removal, not Android timing.

For the observed cold-resume shape, generate private synthetic input with
`generate_tagged_long_fixture.py --observed-cold-resume --output <new-output>`.
Explicitly stage that directory as `targetContext.cacheDir/tagged-cold-resume-fixture`
and select `TaggedLongMp3WindowTest#fresh48kGaplessXingObservedBookmarkPrimesRealWorkerWithExactSamples`
under `DirectCodecFixtureRunner`. This is a genuine gapless 48k stereo/320k
encoded source: only the encoder's Info label is changed to Xing to require the
exact-header path; all audio and trim/count fields remain intact. Independent
oracles stream a full ffmpeg decode in bounded memory, not input-side seeking.
The test starts a fresh production reader through native `loadReader` at
2018594ms, compares the worker's actual deep page, and checks metadata/payload
counters, readiness and non-silent callbacks with unchanged allowances. No
large fixture is packaged, no old asset/inventory is changed. This registered
instrumentation remains unexecuted until the parent owns SDK/runtime custody.

## Identity policy hold

The candidate admits a captured live-original version and restores its saved
position before decoder priming. It does not establish old whole-file SHA
identity before sound. Durable version changes reset/revoke old progress before
the new observation can be persisted. Source reads and background hashes check
opened-object/path facts; source/access/occurrence predicates fence late reads,
EOF and journal writes. First adoption without an earlier live-version record
necessarily assumes the current original belongs to the catalog row. Neither
this adoption nor stat equality is cryptographic equality. Undetected external
in-place writes remain a platform limitation. Product approval of this policy
is required before merge; no late hash auto-jump is implemented.
