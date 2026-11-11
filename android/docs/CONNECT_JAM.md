# Private Connect and host-approved Jam

## Intent and boundaries

Port W29/W30 from the actual Flutter Connect/Jam services and Go handlers. Presence is private metadata, not remote transport or synchronized audio. A guest has only a separate bounded Jam capability. No backend change, server publication, account mutation or runtime installation is part of this lane.

Baseline verified before editing: branch feat/android-connect-jam-full-20261029, HEAD f0611826b6c77ed9f99eb97e1e55b11032b0ca28, all 245 manifest hashes and modes match.

## Design

Data shapes are ConnectedDevice, opaque WriterProof, JamSnapshot (public catalog plus host-only track mappings), JamInvite, JamRequest and AdmissionReceipt. AppGraph owns the existing controller projection, presence and host repository. The Media3 service remains the only queue owner. Panels own only visibility/consent epochs. AccountScope already carries the non-reviving account epoch.

Considered panel-owned observers versus an application-owned observer. Use the latter so hiding a route stops polling/approval consent without replacing the writer or stopping host heartbeat. One serialized host lane covers actual HTTP exchanges and canonical admission. Presence has its own serialized lease lane. It coalesces latest metadata and never stores an offline backlog.

The existing enqueue command has no occurrence receipt or session-incarnation fence. Add a narrow internal ticket consumed by the actual Media3 service custom command, not a second queue. The service checks the captured account, host/panel consent and service generation immediately before inserting one independently identified manual occurrence. Empty queue stays paused. Receipt publication follows actual insertion. Attempt tombstones are latched before admission and bounded at 50; no eviction permits replay. Unknown admission and lost decision ACK require explicit reconciliation without reinsertion. This is not crash-safe exactly-once.

Invitation origin must be explicitly entered as an HTTPS origin. The invite stays in the fragment. A link/QR cannot establish outside-tailnet reachability. Guest network traffic uses a separate no-account transport, never canonical bearer refresh.

## Implemented and retained guest boundary

Account and Player actions open the connected-devices sheet. Host Jam creation uses an explicit 1–20-track current-Library selection. Invitation QR is encoded locally with locked `com.google.zxing:core:3.5.3` (Apache-2.0); no claim is made that this is the latest release. QR decoding is host-tested, not native-camera qualified. The Go backend already serves `/join` and `/api/v1/guest/jams/...`; this release reuses that capability-only browser flow rather than injecting account credentials into a WebView or adding another native guest transport. No public guest origin is configured or published by this change.

The exact production Media3 admission callback and resolver are also extracted into the ordinary JVM test gate with existing boundary facades. This directly checks two independent same-track manual occurrences, rejected tickets, paused empty-queue insertion, and no prepare/play calls. Android framework execution is still separate.

## Execution slices

Blocking work is baseline and source contract discovery. Independent presence and Jam models share only the existing scoped API seam. Implement locally in the assigned tree without fan-out or sibling dependencies. First add meaningful failing lease/approval tests, then production transports/state/lifecycle/UI wiring, then trusted synthetic TLS tests and APK/lint/journey compilation. Compiler lane is one worker, 1536 MiB JVM, in-process Kotlin. No native runtime or performance claim.
