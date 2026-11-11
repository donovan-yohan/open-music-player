# Catalog resolution wire evidence

The nine response JSON files were captured from the producer's freshly migrated
PostgreSQL integration matrix. They contain synthetic test identities and rows,
not live-account data or hand-invented response DTOs.

Historical producer source identity (as recorded by the capture owner):
`f9aabbc15c32b24474f38ddaaf686d88e634f7b2ec24cc5d0723399df3857d9f`.
The original operational receipt is retained privately by that owner. It is not
required or represented as a public reproduction artifact. This publication does
not claim to rerun that producer or to certify the current backend by that hash.

`wire-hashes.json` hashes the nine distributed response files, not this provenance
or its private predecessor. `CatalogResolutionTest.allNineProducerCapturesDecodeWithoutSelectingACandidate`
supplies exact resource text to the production Kotlin JSON decoder. Malformed
owner/recording/status/shape cases remain separate negative controls. Repository
ambiguity controls adapt only owner/recording fields to the selected fixture
album; those adaptations are not exact wire captures.

Use `scripts/test android-product` with the documented toolchain and fixtures to
exercise the consumer. Regenerating producer captures requires an isolated test
PostgreSQL matrix and a new source identity, never production credentials or a
rewritten historical receipt.

The producer was not deployed by this capture. HTTP 404/503 is capability failure,
not evidence of a missing recording. Membership/storage is not a playback grant.
