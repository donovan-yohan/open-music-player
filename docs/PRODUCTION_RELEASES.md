# Qualified production releases

## Intent and authority

A reviewed, owner-merged PR to `main` should advance the existing SoundQ VM
without involving a human infrastructure operator on every routine release.
The owner explicitly requested this release cycle. Ebi uses the normal PR/merge
boundary; GitHub Actions receives no SSH, Proxmox or production credentials.
The owner merge is approval, not an independent review claim.

## Publication contract

`.github/workflows/release-image.yml` is triggered only after main CI completes.
`scripts/release_receipt.py` verifies the exact successful push CI run, current
main commit, unique merged PR and owner merger. Direct pushes cannot publish.
Superseded revisions are refused at qualification and immediately before release
creation, but those checks are not atomic with a new main merge. The guest must
recheck current-main identity and forward ancestry immediately before deployment.
All three linux/amd64 images (backend, analyzer, stems) are built from that source.
Analyzer and stems execute Dockerfile acceptance checks; the backend relies on
source CI and subsequent guest rehearsal, not a build-time runtime smoke. The existing
backend-only `Container Image` workflow is not a production release authority.

The final job assembles `release.json` with exact immutable image digests and
source tree/run/PR identity, signs its bytes with GitHub artifact attestations,
and publishes `release.json` plus `release.sigstore.json` under `deploy-<sha>`.
No guest deployment occurs in this workflow. Duplicate release creation refuses;
there is no asset replacement or mutable-image promotion.

## Guest boundary (private infrastructure repository)

A separately reviewed, root-installed guest consumer must verify signature,
repository, exact source/signer workflow identity, successful finished publication,
main/PR authority, forward ancestry and the complete three-image set. It must not
execute scripts downloaded from this public feed. Keep a durable failure hold,
serialize updates, preserve current credentials/network/storage, require disk/RAM
headroom, retain a consistent database backup, rehearse migrations against an
isolated copy with workers/external providers disabled, and verify acceptance
before promotion. Never automatically restore old database state after new writes.

Production OTel configuration and store/Collector/query access belong to the
private infrastructure repo. Public receipt publication is NOT proof that the
VM was updated or that real telemetry arrived. Initial enrollment and genuine
merge-to-guest acceptance remain required before calling the cycle operational.

## Checks and risks

Run `python3 scripts/test_release_receipt.py` and `scripts/lint delivery`.
The former is also in required Delivery Harness CI. Review workflow changes as
security-sensitive: signing identity, exact checkout and permission scope matter.
Heavy model builds run on GitHub-hosted runners, never the homelab hypervisor.
A failed build publishes no release. Model/dependency availability failures are
real blockers, not permission to omit a worker or weaken its smoke checks.
