# Exact producer sizing regression

`producer-six-minute.json.gz` is lossless gzip of the retained
`queue-waveform-defects/producer-360.json` private probe output. Uncompressed:
2,400,029 bytes; SHA-256
`e4bd539faf7a9ad933d7b900764d7ca6f3ccd392dc3f7281e56fced83af4cfba`.

The probe extracted the integrated HEAD Go `analyzeSamples`, `applyMIR`,
`buildResponse` and helpers. Inputs were deterministic synthetic PCM plus
six-decimal spectral inputs admitted by real `applyMIR`. It substitutes MIR
computation, not the producer's size/tier rules or envelope serialization.
This is not recorded user audio and is not the native visual/RGB acceptance
fixture. Retained probe and provenance are described in
`queue-waveform-defects.md` in the active profile reports.

Run `android/scripts/test-waveform-wire.py --output <private-scratch-dir>
--okhttp-jar <okhttp-jvm-5.5.1.jar>` from the frontend root. It compiles the exact
canonical wire/client block with actual OkHttp/Okio, supplies only a synthetic
session facade, serves these unchanged bytes over loopback, and sends them
through the real production waveform parser. It also checks generic 2MB and
analysis 16MiB boundaries, route/method scope, auth, retirement and redirects.
No Gradle, backend or account access is involved. Dependencies are read from
the local Gradle cache; the standalone OkHttp JVM variant is explicit because
the app's Android platform variant requires Android runtime logging/TLS.
