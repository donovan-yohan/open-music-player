package jam

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
)

// Repository owns SQL transaction ordering: users row -> jams row. Every
// capability operation checks current users.connect_auth_generation under lock.
type Repository struct {
	DB  *sql.DB
	Now func() time.Time
}

func NewRepository(db *sql.DB) *Repository { return &Repository{DB: db, Now: time.Now} }

type catalogRecord struct {
	CatalogItem
	TrackID int64 `json:"trackId"`
}
type memberRecord struct {
	ID       uuid.UUID `json:"id"`
	JoinID   uuid.UUID `json:"joinId"`
	Hash     string    `json:"hash"`
	Digest   string    `json:"digest"`
	Name     string    `json:"name"`
	Expires  time.Time `json:"expires"`
	Sequence int64     `json:"sequence"`
	Revoked  bool      `json:"revoked"`
}
type requestRecord struct {
	Request
	MemberHash string            `json:"memberHash"`
	Digest     string            `json:"digest"`
	Receipt    *AdmissionReceipt `json:"receipt,omitempty"`
}
type state struct {
	DeviceID      uuid.UUID       `json:"deviceId"`
	LeaseID       uuid.UUID       `json:"leaseId"`
	WriterHash    string          `json:"writerHash"`
	CreateDigest  string          `json:"createDigest"`
	HostSequence  int64           `json:"hostSequence"`
	HostDigest    string          `json:"hostDigest"`
	HostSeen      time.Time       `json:"hostSeen"`
	InviteHash    string          `json:"inviteHash"`
	InviteExpires time.Time       `json:"inviteExpires"`
	NowPlaying    *NowPlaying     `json:"nowPlaying"`
	Catalog       []catalogRecord `json:"catalog"`
	Members       []memberRecord  `json:"members"`
	Requests      []requestRecord `json:"requests"`
}
type row struct {
	ID         uuid.UUID
	Owner      uuid.UUID
	Generation int64
	Created    time.Time
	Expires    time.Time
	Closed     sql.NullTime
	Version    int64
	State      state
}

func (r *Repository) Create(ctx context.Context, o Owner, in CreateInput) (Snapshot, error) {
	if o.UserID == uuid.Nil || o.Generation < 0 || in.JamID == uuid.Nil || !validProof(in.Proof) || len(in.TrackIDs) < 1 || len(in.TrackIDs) > MaxCatalog {
		return Snapshot{}, ErrInvalid
	}
	seen := map[int64]bool{}
	for _, id := range in.TrackIDs {
		if id <= 0 || seen[id] {
			return Snapshot{}, ErrInvalid
		}
		seen[id] = true
	}
	tx, e := r.DB.BeginTx(ctx, nil)
	if e != nil {
		return Snapshot{}, e
	}
	defer tx.Rollback()
	var gen int64
	if e = tx.QueryRowContext(ctx, `SELECT connect_auth_generation FROM users WHERE id=$1 FOR UPDATE`, o.UserID).Scan(&gen); e != nil {
		return Snapshot{}, deniedMissing(e)
	}
	if gen != o.Generation {
		return Snapshot{}, ErrDenied
	}
	existing, e := loadRow(ctx, tx, in.JamID)
	if e == nil {
		if existing.Owner != o.UserID || existing.Generation != gen || existing.State.CreateDigest != digest(in) || !live(existing, r.Now()) {
			return Snapshot{}, ErrConflict
		}
		return snapshot(existing, r.Now()), tx.Commit()
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return Snapshot{}, e
	}
	now := r.Now().UTC()
	var n int
	if e = tx.QueryRowContext(ctx, `SELECT count(*) FROM jams WHERE owner_user_id=$1 AND owner_auth_generation=$2 AND closed_at IS NULL AND expires_at>$3`, o.UserID, gen, now).Scan(&n); e != nil {
		return Snapshot{}, e
	}
	if n > 0 {
		return Snapshot{}, ErrConflict
	}
	j := &row{ID: in.JamID, Owner: o.UserID, Generation: gen, Created: now, Expires: now.Add(4 * time.Hour), Version: 1, State: state{DeviceID: in.HostDeviceID, LeaseID: in.LeaseID, WriterHash: hash(in.WriterSecret), CreateDigest: digest(in), HostSeen: now, Catalog: []catalogRecord{}, Members: []memberRecord{}, Requests: []requestRecord{}}}
	for _, id := range in.TrackIDs {
		var c catalogRecord
		c.TrackID = id
		c.CatalogItemID = uuid.New()
		if e = tx.QueryRowContext(ctx, `SELECT t.title,COALESCE(t.artist,''),COALESCE(t.duration_ms,0) FROM tracks t JOIN user_library l ON l.track_id=t.id WHERE l.user_id=$1 AND t.id=$2 FOR SHARE OF t,l`, o.UserID, id).Scan(&c.Title, &c.Artist, &c.DurationMS); e != nil {
			return Snapshot{}, deniedMissing(e)
		}
		if !text(c.Title, 200) || !text(c.Artist, 200) || c.DurationMS < 0 || c.DurationMS > 86400000 {
			return Snapshot{}, ErrInvalid
		}
		j.State.Catalog = append(j.State.Catalog, c)
	}
	b, e := marshalState(j.State)
	if e != nil {
		return Snapshot{}, e
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO jams(id,owner_user_id,owner_auth_generation,created_at,expires_at,version,state) VALUES($1,$2,$3,$4,$5,$6,$7)`, j.ID, j.Owner, j.Generation, j.Created, j.Expires, j.Version, b)
	if e != nil {
		return Snapshot{}, e
	}
	if e = tx.Commit(); e != nil {
		return Snapshot{}, e
	}
	return snapshot(j, now), nil
}
func deniedMissing(e error) error {
	if errors.Is(e, sql.ErrNoRows) {
		return ErrDenied
	}
	return e
}
func loadRow(ctx context.Context, tx *sql.Tx, id uuid.UUID) (*row, error) {
	j := new(row)
	var b []byte
	e := tx.QueryRowContext(ctx, `SELECT id,owner_user_id,owner_auth_generation,created_at,expires_at,closed_at,version,state FROM jams WHERE id=$1 FOR UPDATE`, id).Scan(&j.ID, &j.Owner, &j.Generation, &j.Created, &j.Expires, &j.Closed, &j.Version, &b)
	if e != nil {
		return nil, e
	}
	e = json.Unmarshal(b, &j.State)
	return j, e
}
func live(j *row, now time.Time) bool { return !j.Closed.Valid && now.Before(j.Expires) }
func online(j *row, now time.Time) bool {
	return live(j, now) && now.Sub(j.State.HostSeen) < 30*time.Second
}
func proofMatches(j *row, p Proof) bool {
	return validProof(p) && j.State.DeviceID == p.HostDeviceID && j.State.LeaseID == p.LeaseID && equalHash(j.State.WriterHash, hash(p.WriterSecret))
}
func snapshot(j *row, now time.Time) Snapshot {
	s := "open"
	if j.Closed.Valid {
		s = "closed"
	} else if !now.Before(j.Expires) {
		s = "expired"
	} else if !online(j, now) {
		s = "hostOffline"
	}
	v := Snapshot{JamID: j.ID, Version: j.Version, State: s, ServerTime: now, ExpiresAt: j.Expires, HostSeenAt: j.State.HostSeen, NowPlaying: j.State.NowPlaying, Catalog: []CatalogItem{}, Requests: []Request{}}
	for _, c := range j.State.Catalog {
		v.Catalog = append(v.Catalog, c.CatalogItem)
	}
	for _, q := range j.State.Requests {
		v.Requests = append(v.Requests, q.Request)
	}
	return v
}
func marshalState(s state) ([]byte, error) {
	b, e := json.Marshal(s)
	if e == nil && len(b) > MaxStateBytes {
		e = ErrCapacity
	}
	return b, e
}

// locked checks the current owner generation even for public reads. Unknown
// Jam identifiers never create SQL rows or per-identifier process state.
func (r *Repository) locked(ctx context.Context, id uuid.UUID, o *Owner, fn func(*sql.Tx, *row, time.Time) error) error {
	if id == uuid.Nil {
		return ErrDenied
	}
	tx, e := r.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var owner uuid.UUID
	if e = tx.QueryRowContext(ctx, `SELECT owner_user_id FROM jams WHERE id=$1`, id).Scan(&owner); e != nil {
		return deniedMissing(e)
	}
	if o != nil && o.UserID != owner {
		return ErrDenied
	}
	var gen int64
	if e = tx.QueryRowContext(ctx, `SELECT connect_auth_generation FROM users WHERE id=$1 FOR UPDATE`, owner).Scan(&gen); e != nil {
		return deniedMissing(e)
	}
	j, e := loadRow(ctx, tx, id)
	if e != nil {
		return deniedMissing(e)
	}
	if j.Generation != gen || (o != nil && o.Generation != gen) {
		return ErrDenied
	}
	now := r.Now().UTC()
	if e = fn(tx, j, now); e != nil {
		return e
	}
	return tx.Commit()
}
func save(ctx context.Context, tx *sql.Tx, j *row) error {
	b, e := marshalState(j.State)
	if e != nil {
		return e
	}
	_, e = tx.ExecContext(ctx, `UPDATE jams SET state=$2,version=$3,closed_at=$4 WHERE id=$1`, j.ID, b, j.Version, j.Closed)
	return e
}
func hostView(j *row, now time.Time) HostView {
	v := HostView{Snapshot: snapshot(j, now), HostRequests: []HostRequest{}}
	for _, m := range j.State.Members {
		if !m.Revoked && now.Before(m.Expires) {
			v.MemberCount++
		}
	}
	for _, q := range j.State.Requests {
		h := HostRequest{Request: q.Request, Receipt: q.Receipt}
		for _, c := range j.State.Catalog {
			if c.CatalogItemID == q.CatalogItemID {
				h.TrackID = c.TrackID
			}
		}
		v.HostRequests = append(v.HostRequests, h)
	}
	return v
}
func (r *Repository) HostSnapshot(ctx context.Context, o Owner, id uuid.UUID) (HostView, error) {
	var out HostView
	e := r.locked(ctx, id, &o, func(_ *sql.Tx, j *row, now time.Time) error { out = hostView(j, now); return nil })
	return out, e
}
