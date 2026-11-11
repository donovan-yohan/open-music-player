package jam

import (
	"context"
	"database/sql"
	"time"

	"github.com/google/uuid"
)

// VersionInput binds a destructive action to the content the caller inspected.
// Exact successful retries are acknowledged before checking the old version.
type VersionInput struct {
	ExpectedVersion int64 `json:"expectedVersion"`
}

func (r *Repository) Withdraw(ctx context.Context, id uuid.UUID, secret string, requestID uuid.UUID, in VersionInput) error {
	if requestID == uuid.Nil || in.ExpectedVersion < 1 {
		return ErrInvalid
	}
	return r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		m := member(j, secret, now)
		if m == nil {
			return ErrDenied
		}
		for i := range j.State.Requests {
			q := &j.State.Requests[i]
			if q.RequestID != requestID {
				continue
			}
			if q.MemberHash != m.Hash {
				return ErrDenied
			}
			if q.Status == "withdrawn" {
				return nil
			}
			if j.Version != in.ExpectedVersion || !unadmitted(q.Status) {
				return ErrConflict
			}
			q.Status = "withdrawn"
			j.Version++
			return save(ctx, tx, j)
		}
		return ErrDenied
	})
}

func (r *Repository) RevokeMember(ctx context.Context, owner Owner, id uuid.UUID, proof Proof, memberID uuid.UUID, in VersionInput) error {
	if memberID == uuid.Nil || in.ExpectedVersion < 1 {
		return ErrInvalid
	}
	return r.locked(ctx, id, &owner, func(tx *sql.Tx, j *row, now time.Time) error {
		if !live(j, now) || !proofMatches(j, proof) {
			return ErrDenied
		}
		for i := range j.State.Members {
			m := &j.State.Members[i]
			if m.ID != memberID {
				continue
			}
			if m.Revoked {
				return nil
			}
			if j.Version != in.ExpectedVersion {
				return ErrConflict
			}
			m.Revoked = true
			retireRequests(j, m.Hash)
			j.Version++
			return save(ctx, tx, j)
		}
		return ErrDenied
	})
}

func unadmitted(status string) bool {
	switch status {
	case "pending", "uncertain", "approved", "importing", "ready":
		return true
	default:
		return false
	}
}
