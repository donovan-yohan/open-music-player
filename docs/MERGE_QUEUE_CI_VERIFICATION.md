# Merge Queue CI Verification

This document describes the CI verification process implemented in the Gas Town refinery for openmusicplayer.

## Overview

All merge requests must pass CI verification before being merged to main. This prevents broken code from landing on the main branch.

## CI Verification Flow

```
queue-scan → ci-verify → process-branch → merge
              ↓
    Check: gh run list --branch <branch> --workflow=CI
              ↓
    [CI passed] → Continue to process-branch
    [CI failed] → Notify polecat, skip branch
    [CI pending] → Skip, retry next cycle
    [No CI runs] → Reject, require push to trigger CI
```

## Configuration

The merge queue is configured in `settings/config.json`:

```json
{
  "merge_queue": {
    "enabled": true,
    "target_branch": "main",
    "run_tests": true,
    "require_ci": true,
    "ci_workflow": "CI",
    "ci_timeout_minutes": 30,
    "local_verification_fallback": true
  }
}
```

### Configuration Options

| Option | Description |
|--------|-------------|
| `require_ci` | Enforce CI verification before merge |
| `ci_workflow` | Name of the GitHub Actions workflow to check |
| `ci_timeout_minutes` | Maximum time to wait for CI to complete |
| `local_verification_fallback` | Run local builds if CI unavailable |

## CI Status Checking

The refinery uses the `gh` CLI to check CI status:

```bash
gh run list --branch <branch> --workflow=CI --limit=1 --json status,conclusion
```

### Status Interpretation

| Status | Conclusion | Action |
|--------|------------|--------|
| completed | success | Proceed with merge |
| completed | failure | Reject, notify polecat |
| in_progress | - | Skip, retry later |
| queued | - | Skip, retry later |
| (no runs) | - | Reject, branch not pushed |

## Local Verification Fallback

When CI is unavailable, local verification commands run:

```bash
# Backend (Go)
cd backend && go build ./... && go test ./...

# Extension (TypeScript)
cd extension && npm ci && npm run type-check && npm run build
```

## Refinery Patrol Formula

The CI verification is implemented in the `mol-refinery-patrol` formula, which includes a `ci-verify` step between `queue-scan` and `process-branch`.

## Emergency Bypass

In emergencies, an MR can include `ci_bypass: true` in its bead fields. This should only be used when:
- CI infrastructure is down
- The fix is itself a CI fix
- Explicit human approval was given

All bypasses must be documented in the merge commit message.

## Related Files

- `.beads/formulas/mol-refinery-patrol.formula.toml` - Patrol formula with CI step
- `settings/config.json` - Merge queue configuration
- `refinery/rig/CLAUDE.md` - Refinery agent instructions
