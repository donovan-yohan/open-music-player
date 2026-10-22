package jam

import (
	"context"
	"database/sql"
	"time"

	"github.com/google/uuid"
)

// Heartbeat sequences do not change content version. Exact retries never keep
// a dead host alive. The designated same lease may resume before session expiry.
func (r *Repository) Heartbeat(ctx context.Context, o Owner, id uuid.UUID, in HeartbeatInput) (Snapshot, error) {
	var out Snapshot
	if in.HostSequence < 1 || !validPlaying(in.NowPlaying) {
		return out, ErrInvalid
	}
	e := r.locked(ctx, id, &o, func(tx *sql.Tx, j *row, now time.Time) error {
		if !live(j, now) || !proofMatches(j, in.Proof) {
			return ErrDenied
		}
		d := digest(in)
		if in.HostSequence <= j.State.HostSequence {
			if in.HostSequence == j.State.HostSequence && d == j.State.HostDigest {
				out = snapshot(j, now)
				return nil
			}
			return ErrConflict
		}
		j.State.HostSequence = in.HostSequence
		j.State.HostDigest = d
		j.State.HostSeen = now
		j.State.NowPlaying = in.NowPlaying
		if e := save(ctx, tx, j); e != nil {
			return e
		}
		out = snapshot(j, now)
		return nil
	})
	return out, e
}
func (r *Repository) MemberHeartbeat(ctx context.Context, id uuid.UUID, secret string, sequence int64) (time.Time, error) {
	var out time.Time
	if sequence < 1 {
		return out, ErrInvalid
	}
	e := r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		m := member(j, secret, now)
		if m == nil || !online(j, now) {
			return ErrDenied
		}
		if sequence < m.Sequence {
			return ErrConflict
		}
		if sequence == m.Sequence {
			out = m.Expires
			return nil
		}
		m.Sequence = sequence
		m.Expires = now.Add(time.Minute)
		out = m.Expires
		return save(ctx, tx, j)
	})
	return out, e
}
func (r *Repository) Leave(ctx context.Context, id uuid.UUID, secret string) error {
	return r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		if !ValidSecret(secret) || !live(j, now) {
			return ErrDenied
		}
		for i := range j.State.Members {
			m := &j.State.Members[i]
			if equalHash(m.Hash, hash(secret)) {
				if m.Revoked {
					return nil
				}
				m.Revoked = true
				return save(ctx, tx, j)
			}
		}
		return ErrDenied
	})
}
