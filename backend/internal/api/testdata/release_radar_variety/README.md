# Release Radar producer corpus

These are exact response bodies emitted by the production authenticated router and serializer in `TestReleaseRadarVarietyDailyProducerCorpus`. The test compares every body byte-for-byte with this corpus. Provider HTTP is a bounded synthetic MusicBrainz recording response; seed/membership reads, daily admission and snapshot persistence use a freshly migrated, guarded test database. No personal library or production response is included.

- `v2-enriched.json`: explicit `X-SoundQ-Radar-Policy: recording-radar-v2`, cold daily admission. Variety order is first album song, other artist/album, album sibling.
- `v1-enriched.json`: no policy header, warm independent service. Strict recording first-release date/ID order, same optional association metadata.
- `v2-unenriched.json`: same warm raw snapshot with legacy absent association fields. Missing albums use unique recording keys; seed-artist exposure still improves variety. No enrichment request.
- `v1-unenriched.json`: no-header legacy order over that same snapshot.
- `v2-owned.json`: a real current membership addition excludes the first song before computing exposures.
- `v2-removed.json`: removing that membership restores the song without another provider request.

`releaseGroupMbid` and `releaseMbid` are optional distinct canonical association IDs. They are neither artwork availability claims nor playable-source capabilities. The edition date in the controlled provider response intentionally differs from the recording first-release date. Only the latter controls eligibility/order.

Native consumers should preserve explicit v2 order and retain strict original v1 date/ID validation. A reordered v1 body is invalid. The producer integration test also corrupts a private raw snapshot and verifies both request policies refuse it without spending another daily attempt. Old servers may ignore the new header and return valid v1.

Regenerate only by executing this actual integration test with `SOUNDQ_RADAR_VARIETY_WIRE_DIR` pointing to an owned private directory, then review any changed expected bodies. Do not synthesize responses using another serializer or weaken the byte equality check to bless a contract change.
