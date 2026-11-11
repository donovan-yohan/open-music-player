# Jam HTTP producer fixtures

These files are unchanged response bodies emitted by
`TestJamAcquisitionHTTPExactSourceDurableRecoveryAndOrdering` through actual Go
Jam handlers, canonical startup migrations, disposable PostgreSQL and Redis.
The provider, completed storage metadata and host authorization in that test are
synthetic. These are wire-contract fixtures, not evidence of real-provider audio
or native playback insertion. No guest capability, writer proof or owner token
is included.

The JavaScript consumer reads these bytes directly. Tests that need the expired
search capture use an explicitly fixed fixture clock. Other focused transport
fault tests derive clearly synthetic variants; they do not replace the unchanged
producer-consumer assertion.

SHA-256:

- `search.json`: `28b65bfa1cf815ce06c11de0780d0d703d0ad2d709c071797ac5bfcde2034dd5`
- `guest-ready.json`: `3843574ce1fe244d126a1172fc6a82f5bbc7c77aa68b48194c22d6ccbd5f2197`
- `source-request.json`: `eb5c4706951f3d219043fd42e3c19b9459d520b0e125fc9ec5c1d125b3d2fb86`

A `ready` request has an acquired numeric track on the host projection. It is
not `queued` and cannot establish an actual canonical playback occurrence.
