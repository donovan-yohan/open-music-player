# Jam Go producer inputs

These are unchanged synthetic HTTP response bodies from the actual Go
`TestJamAcquisitionHTTPExactSourceDurableRecoveryAndOrdering` journey. It uses
canonical migrations, disposable SQL/Redis and real Jam handlers, with synthetic
provider/storage/host resolver and receipt inputs. No guest capability, writer
proof, real account, or audio payload is included.

The Kotlin consumer reads these exact files. Its fixed producer assertions are
not a claim of native insertion or real-provider acquisition. The separate
legacy-shape test explicitly derives an offered-only compatibility variant.

SHA-256:

- `host-pending.json`: `ad57dc2ded4c56d2e031ae5ea21f859a4be20c3525f60375cf47fd1b5ae35951`
- `host-importing.json`: `8256dd95af3a35bcdf26919b1e930f334ffba05e40ce71a37274a9934dba9c7d`
- `host-ready.json`: `c1ce3acbd1a510eb7a13c311df3677e15892c4d96d091e5ea86d3f1bf1251c17`
- `guest-ready.json`: `3843574ce1fe244d126a1172fc6a82f5bbc7c77aa68b48194c22d6ccbd5f2197`
- `host-receipt-reconciled.json`: `c0eff0173bf1269d2b9d22adee89ef5ec6ec5daed768e78891633cbe92ab6abf`

An admission key is not an insertion receipt. Numeric readiness, actual native
occurrence insertion and actual receipt acknowledgement are separate stages.

`host-sparse-pending.json` is an unchanged additional producer response from
`TestJamSparseSourceHTTPProducerOmitsUnknownPrivateMetadata`. It deliberately
preserves Go Candidate's omitted unknown artist/duration fields, while public
SourceChoice still carries empty artist and zero duration. It is not playable.
SHA-256: `ee80791de21833edf5f2e29d62631827877d71b2dd3c0a3c1fe48f40d4432310`.
