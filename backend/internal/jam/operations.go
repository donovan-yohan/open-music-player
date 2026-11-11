package jam

import (
	"context"
	"database/sql"
	"time"

	"github.com/google/uuid"
)

func (r *Repository) RotateInvite(ctx context.Context, o Owner, id uuid.UUID, p Proof) (Invite, error) {
	var out Invite
	e := r.locked(ctx, id, &o, func(tx *sql.Tx, j *row, now time.Time) error {
		if !proofMatches(j, p) || !online(j, now) {
			return ErrDenied
		}
		out = Invite{JoinToken: NewSecret(), InviteExpiresAt: now.Add(10 * time.Minute)}
		j.State.InviteHash = hash(out.JoinToken)
		j.State.InviteExpires = out.InviteExpiresAt
		return save(ctx, tx, j)
	})
	return out, e
}
func (r *Repository) Join(ctx context.Context, id uuid.UUID, in JoinInput) (JoinResult, error) {
	var out JoinResult
	if !ValidSecret(in.JoinToken) || !ValidSecret(in.MemberSecret) || in.RequestID == uuid.Nil || !text(in.DisplayName, 32) || len(in.DisplayName) == 0 {
		return out, ErrDenied
	}
	e := r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		if !online(j, now) {
			return ErrDenied
		}
		// Retain bounded join tombstones until Jam expiry; rotating an invite does not
		// break an exact already-admitted lost-response retry, nor renew its lease.
		for _, m := range j.State.Members {
			if m.JoinID == in.RequestID {
				if m.Digest != digest(in) {
					return ErrConflict
				}
				if m.Revoked || !now.Before(m.Expires) {
					return ErrDenied
				}
				out = JoinResult{m.ID, m.Expires, snapshot(j, now)}
				return nil
			}
		}
		if !now.Before(j.State.InviteExpires) || !equalHash(j.State.InviteHash, hash(in.JoinToken)) {
			return ErrDenied
		}
		active := 0
		for _, m := range j.State.Members {
			if m.Hash == hash(in.MemberSecret) {
				return ErrConflict
			}
			if !m.Revoked && now.Before(m.Expires) {
				active++
			}
		}
		if active >= MaxMembers || len(j.State.Members) >= MaxJoins {
			return ErrCapacity
		}
		m := memberRecord{ID: uuid.New(), JoinID: in.RequestID, Hash: hash(in.MemberSecret), Digest: digest(in), Name: in.DisplayName, Expires: now.Add(time.Minute)}
		j.State.Members = append(j.State.Members, m)
		if e := saveAdmission(ctx, tx, j); e != nil {
			return e
		}
		out = JoinResult{m.ID, m.Expires, snapshot(j, now)}
		return nil
	})
	return out, e
}
func member(j *row, secret string, now time.Time) *memberRecord {
	if !ValidSecret(secret) || !live(j, now) {
		return nil
	}
	h := hash(secret)
	for i := range j.State.Members {
		m := &j.State.Members[i]
		if equalHash(m.Hash, h) && !m.Revoked && now.Before(m.Expires) {
			return m
		}
	}
	return nil
}
func (r *Repository) GuestSnapshot(ctx context.Context, id uuid.UUID, secret string) (Snapshot, error) {
	var out Snapshot
	e := r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		if member(j, secret, now) == nil {
			return ErrDenied
		}
		if e := reconcile(ctx, tx, j, now); e != nil {
			return e
		}
		out = snapshot(j, now)
		return nil
	})
	return out, e
}
func (r *Repository) AddRequest(ctx context.Context, id uuid.UUID, secret string, in RequestInput) (Request, error) {
	var out Request
	if in.RequestID == uuid.Nil || in.CatalogItemID == uuid.Nil || in.ExpectedVersion < 1 {
		return out, ErrInvalid
	}
	e := r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		m := member(j, secret, now)
		if m == nil || !online(j, now) {
			return ErrDenied
		}
		for _, q := range j.State.Requests {
			if q.RequestID == in.RequestID {
				if q.MemberHash != m.Hash || q.Digest != digest(in) {
					return ErrConflict
				}
				out = q.Request
				return nil
			}
		}
		if requestBlocked(j, m.Hash, in.CatalogItemID, nil, now) {
			return ErrConflict
		}
		if in.ExpectedVersion != j.Version {
			return ErrConflict
		}
		if len(j.State.Requests) >= MaxRequests {
			return ErrCapacity
		}
		found := false
		for _, c := range j.State.Catalog {
			if c.CatalogItemID == in.CatalogItemID {
				found = true
			}
		}
		if !found {
			return ErrDenied
		}
		out = Request{RequestID: in.RequestID, CatalogItemID: in.CatalogItemID, DisplayName: m.Name, Status: "pending"}
		j.State.Requests = append(j.State.Requests, requestRecord{Request: out, MemberHash: m.Hash, Digest: digest(in)})
		j.Version++
		return saveAdmission(ctx, tx, j)
	})
	return out, e
}
func (r *Repository) Decide(ctx context.Context, o Owner, id uuid.UUID, p Proof, requestID uuid.UUID, in DecisionInput) (Request, error) {
	var out Request
	if in.ExpectedVersion < 1 || (in.Status != "queued" && in.Status != "declined" && in.Status != "uncertain") {
		return out, ErrInvalid
	}
	if in.Status == "queued" {
		a := in.Receipt
		if a == nil || a.RequestID != requestID || a.SessionID == "" || a.OccurrenceID == "" || !text(a.SessionID, 128) || !text(a.OccurrenceID, 128) {
			return out, ErrInvalid
		}
	} else if in.Receipt != nil {
		return out, ErrInvalid
	}
	e := r.locked(ctx, id, &o, func(tx *sql.Tx, j *row, now time.Time) error {
		if !proofMatches(j, p) || !online(j, now) {
			return ErrDenied
		}
		for i := range j.State.Requests {
			q := &j.State.Requests[i]
			if q.RequestID != requestID {
				continue
			}
			if q.Status == in.Status && digest(q.Receipt) == digest(in.Receipt) {
				out = q.Request
				return nil
			}
			if j.Version != in.ExpectedVersion {
				return ErrConflict
			}
			if !unadmitted(q.Status) {
				return ErrConflict
			}
			if !requestMemberLive(j, q, now) {
				return ErrDenied
			}
			if q.Source != nil && q.ApprovalOrder == 0 && in.Status != "declined" {
				return ErrConflict
			}
			if in.Status == "queued" && q.ApprovalOrder == 0 {
				for _, earlier := range j.State.Requests {
					if earlier.ApprovalOrder > 0 && unadmitted(earlier.Status) {
						return ErrConflict
					}
				}
			}
			if q.Source != nil && q.Status != "ready" && q.Status != "uncertain" && in.Status == "queued" {
				return ErrConflict
			}
			admission := *q
			if admission.Status == "uncertain" {
				admission.Status = "ready"
			}
			if q.ApprovalOrder > 0 && in.Status == "queued" && (!admissible(j, &admission, now) || in.Receipt.SessionID != q.HostSessionID) {
				return ErrConflict
			}
			if q.Status != "pending" && q.Status != "uncertain" && q.Status != "ready" && !(in.Status == "declined" && unadmitted(q.Status)) {
				return ErrConflict
			}
			if in.Status == "queued" {
				if q.Source != nil || q.ApprovalOrder > 0 {
					if e := ownedPlayable(ctx, tx, o.UserID, q.TrackID); e != nil {
						return e
					}
				}
				track := q.TrackID
				for _, c := range j.State.Catalog {
					if c.CatalogItemID == q.CatalogItemID {
						track = c.TrackID
					}
				}
				var n int64
				if e := tx.QueryRowContext(ctx, `SELECT track_id FROM user_library WHERE user_id=$1 AND track_id=$2 FOR SHARE`, o.UserID, track).Scan(&n); e != nil {
					return deniedMissing(e)
				}
			}
			q.Status = in.Status
			q.Receipt = in.Receipt
			j.Version++
			out = q.Request
			return save(ctx, tx, j)
		}
		return ErrDenied
	})
	return out, e
}
func (r *Repository) Close(ctx context.Context, o Owner, id uuid.UUID) error {
	return r.locked(ctx, id, &o, func(tx *sql.Tx, j *row, now time.Time) error {
		if j.Closed.Valid {
			return nil
		}
		j.Closed = sql.NullTime{Time: now, Valid: true}
		for i := range j.State.Members {
			j.State.Members[i].Revoked = true
		}
		retireRequests(j, "")
		j.Version++
		return save(ctx, tx, j)
	})
}

// Retirement cancels only future party intent. A published occurrence receipt
// stays host-owned; leaving or ending never removes playback or Library rows.
func retireRequests(j *row, memberHash string) {
	for i := range j.State.Requests {
		q := &j.State.Requests[i]
		if memberHash != "" && q.MemberHash != memberHash {
			continue
		}
		if unadmitted(q.Status) {
			q.Status = "withdrawn"
		}
	}
}
