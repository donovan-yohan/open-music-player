package jam

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
)

type HostMember struct {
	MemberID    uuid.UUID `json:"memberId"`
	DisplayName string    `json:"displayName"`
	ExpiresAt   time.Time `json:"expiresAt"`
	Revoked     bool      `json:"revoked"`
}

type SourceSearcher interface {
	Search(context.Context, string, []string, int) discovery.SearchResponse
}
type DownloadPublisher interface {
	EnsureSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error)
}

type SearchInput struct {
	SearchID uuid.UUID `json:"searchId"`
	Query    string    `json:"query"`
}
type SourceChoice struct {
	SelectionSessionID uuid.UUID `json:"selectionSessionId"`
	CandidateID        string    `json:"candidateId"`
	Provider           string    `json:"provider"`
	SourceID           string    `json:"sourceId"`
	Title              string    `json:"title"`
	Artist             string    `json:"artist"`
	DurationMS         int       `json:"durationMs"`
	ExpiresAt          time.Time `json:"expiresAt"`
}
type SearchResult struct {
	SearchID  uuid.UUID      `json:"searchId"`
	ExpiresAt time.Time      `json:"expiresAt"`
	Results   []SourceChoice `json:"results"`
}
type SourceRequestInput struct {
	RequestID          uuid.UUID `json:"requestId"`
	SelectionSessionID uuid.UUID `json:"selectionSessionId"`
	CandidateID        string    `json:"candidateId"`
	ExpectedVersion    int64     `json:"expectedVersion"`
}
type ApprovalInput struct {
	ExpectedVersion int64  `json:"expectedVersion"`
	HostSessionID   string `json:"hostSessionId"`
}

func validCandidate(c discovery.Candidate) bool {
	u, e := url.Parse(c.SourceURL)
	if e != nil || u.Scheme != "https" || u.User != nil || len(c.SourceURL) > 2048 || !c.Downloadable || c.SourceID == "" || !text(c.SourceID, 128) || !text(c.CandidateID, 256) || c.CandidateID == "" || !text(c.Title, 200) || c.Title == "" || !text(c.Artist, 200) || c.DurationMs < 0 || c.DurationMs > 86400000 {
		return false
	}
	host := u.Hostname()
	return (c.Provider == "youtube" && (host == "www.youtube.com" || host == "youtube.com" || host == "music.youtube.com" || host == "youtu.be")) || (c.Provider == "soundcloud" && (host == "soundcloud.com" || host == "www.soundcloud.com"))
}
func choice(c discovery.Candidate, id uuid.UUID, expiry time.Time) *SourceChoice {
	return &SourceChoice{SelectionSessionID: id, CandidateID: c.CandidateID, Provider: c.Provider, SourceID: c.SourceID, Title: c.Title, Artist: c.Artist, DurationMS: c.DurationMs, ExpiresAt: expiry}
}

// Each member gets six searches for the whole party and one retained search
// session. Exact search-ID retries read SQL; they never call providers again.
func (r *Repository) Search(ctx context.Context, id uuid.UUID, secret string, in SearchInput) (SearchResult, error) {
	out := SearchResult{SearchID: in.SearchID, Results: []SourceChoice{}}
	if in.SearchID == uuid.Nil || strings.TrimSpace(in.Query) == "" || !text(in.Query, 160) {
		return out, ErrInvalid
	}
	if r.Searcher == nil || r.Downloads == nil {
		return out, ErrUnavailable
	}
	// Reserve before provider work; a failed/lost provider exchange consumes a
	// bounded attempt, never silently reruns expensive work on a retry.
	fresh := false
	err := r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		m := member(j, secret, now)
		if m == nil || !online(j, now) || !j.State.AllowOutsideDiscovery {
			return ErrDenied
		}
		if m.SearchID == in.SearchID {
			if m.SearchDigest != digest(in) {
				return ErrConflict
			}
			return nil
		}
		for _, other := range j.State.Members {
			if other.ID != m.ID && other.SearchID == in.SearchID {
				return ErrConflict
			}
		}
		if m.SearchCount >= 6 {
			return ErrCapacity
		}
		for _, q := range j.State.Requests {
			if q.MemberHash == m.Hash && unadmitted(q.Status) {
				return ErrConflict
			}
		}
		// No search UUID may be reused by another member/party or an owner session.
		var exists bool
		if e := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM source_selection_sessions WHERE id=$1)`, in.SearchID).Scan(&exists); e != nil {
			return e
		}
		if exists {
			return ErrConflict
		}
		m.SearchCount++
		m.SearchID = in.SearchID
		m.SearchDigest = digest(in)
		fresh = true
		return save(ctx, tx, j)
	})
	if err != nil {
		return out, err
	}
	var candidates []discovery.Candidate
	if fresh {
		searchCtx, cancel := context.WithTimeout(ctx, 17*time.Second)
		result := r.Searcher.Search(searchCtx, in.Query, []string{"youtube", "soundcloud"}, 5)
		cancel()
		seen := map[string]bool{}
		for _, c := range result.Results {
			if !validCandidate(c) || seen[c.CandidateID] {
				continue
			}
			seen[c.CandidateID] = true
			// Drop provider internals, errors, URLs/artwork/metadata that are not needed
			// for acquisition. The private capture retains only the exact source URL.
			c = discovery.Candidate{CandidateID: c.CandidateID, Provider: c.Provider, SourceID: c.SourceID, SourceURL: c.SourceURL, Title: c.Title, Artist: c.Artist, DurationMs: c.DurationMs, Downloadable: true}
			candidates = append(candidates, c)
			if len(candidates) == 5 {
				break
			}
		}
	}
	err = r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		m := member(j, secret, now)
		if m == nil || !online(j, now) || !j.State.AllowOutsideDiscovery {
			return ErrDenied
		}
		if m.SearchID != in.SearchID || m.SearchDigest != digest(in) {
			return ErrConflict
		}
		if fresh {
			if len(candidates) == 0 {
				return ErrUnavailable
			}
			snapshot, _ := json.Marshal(candidates)
			session := &db.SourceSelectionSession{ID: in.SearchID, UserID: j.Owner, Query: in.Query, Context: "jam:" + id.String() + ":" + m.ID.String(), Candidates: snapshot, ExpiresAt: now.Add(3 * time.Minute)}
			if e := db.CreateSourceSessionTx(ctx, tx, session); e != nil {
				return e
			}
		}
		var raw json.RawMessage
		if e := tx.QueryRowContext(ctx, `SELECT candidates,expires_at FROM source_selection_sessions WHERE id=$1 AND user_id=$2 AND expires_at>$3 AND context=$4`, in.SearchID, j.Owner, now, "jam:"+id.String()+":"+m.ID.String()).Scan(&raw, &out.ExpiresAt); e != nil {
			return ErrConflict
		}
		var saved []discovery.Candidate
		if e := json.Unmarshal(raw, &saved); e != nil {
			return e
		}
		for _, c := range saved {
			out.Results = append(out.Results, *choice(c, in.SearchID, out.ExpiresAt))
		}
		return nil
	})
	return out, err
}

func requestBlocked(j *row, memberHash string, catalogID uuid.UUID, source *SourceChoice) bool {
	for _, q := range j.State.Requests {
		active := unadmitted(q.Status) || q.Status == "queued"
		if unadmitted(q.Status) && q.MemberHash == memberHash {
			return true
		}
		if !active {
			continue
		}
		if source == nil && q.CatalogItemID == catalogID && catalogID != uuid.Nil {
			return true
		}
		if source != nil && q.Source != nil && source.Provider == q.Source.Provider && source.SourceID == q.Source.SourceID {
			return true
		}
	}
	return false
}
func (r *Repository) AddSourceRequest(ctx context.Context, id uuid.UUID, secret string, in SourceRequestInput) (Request, error) {
	var out Request
	if in.RequestID == uuid.Nil || in.SelectionSessionID == uuid.Nil || in.CandidateID == "" || !text(in.CandidateID, 256) || in.ExpectedVersion < 1 {
		return out, ErrInvalid
	}
	err := r.locked(ctx, id, nil, func(tx *sql.Tx, j *row, now time.Time) error {
		m := member(j, secret, now)
		if m == nil || !online(j, now) || !j.State.AllowOutsideDiscovery {
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
		if in.ExpectedVersion != j.Version {
			return ErrConflict
		}
		if len(j.State.Requests) >= MaxRequests {
			return ErrCapacity
		}
		if m.SearchID != in.SelectionSessionID {
			return ErrDenied
		}
		var consumed bool
		if e := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM source_selection_decisions WHERE session_id=$1)`, in.SelectionSessionID).Scan(&consumed); e != nil {
			return e
		}
		if consumed {
			return ErrConflict
		}
		var binding string
		if e := tx.QueryRowContext(ctx, `SELECT context FROM source_selection_sessions WHERE id=$1 AND user_id=$2`, in.SelectionSessionID, j.Owner).Scan(&binding); e != nil || binding != "jam:"+id.String()+":"+m.ID.String() {
			return ErrDenied
		}
		selected, expiry, e := db.CapturedSourceTx(ctx, tx, j.Owner, in.SelectionSessionID, in.CandidateID, now)
		if e != nil {
			return ErrConflict
		}
		var c discovery.Candidate
		if json.Unmarshal(selected, &c) != nil || !validCandidate(c) {
			return ErrInvalid
		}
		src := choice(c, in.SelectionSessionID, expiry)
		if requestBlocked(j, m.Hash, uuid.Nil, src) {
			return ErrConflict
		}
		out = Request{RequestID: in.RequestID, DisplayName: m.Name, Status: "pending", Source: src}
		j.State.Requests = append(j.State.Requests, requestRecord{Request: out, MemberHash: m.Hash, Digest: digest(in), Selected: selected})
		j.Version++
		return save(ctx, tx, j)
	})
	return out, err
}

// Approval is a durable host consent, NOT canonical listening-queue insertion.
func (r *Repository) Approve(ctx context.Context, o Owner, id uuid.UUID, p Proof, requestID uuid.UUID, in ApprovalInput) (HostView, error) {
	var out HostView
	var publish *requestRecord
	if in.ExpectedVersion < 1 || in.HostSessionID == "" || !text(in.HostSessionID, 128) || requestID == uuid.Nil {
		return out, ErrInvalid
	}
	err := r.locked(ctx, id, &o, func(tx *sql.Tx, j *row, now time.Time) error {
		if !proofMatches(j, p) || !online(j, now) {
			return ErrDenied
		}
		if e := reconcile(ctx, tx, j, now); e != nil {
			return e
		}
		for i := range j.State.Requests {
			q := &j.State.Requests[i]
			if q.RequestID != requestID {
				continue
			}
			if q.ApprovalOrder > 0 {
				if q.ApprovalDigest != digest(in) {
					return ErrConflict
				}
			} else {
				if q.Status != "pending" || in.ExpectedVersion != j.Version || !requestMemberLive(j, q, now) {
					return ErrConflict
				}
				if q.Source != nil {
					if !j.State.AllowOutsideDiscovery || r.Downloads == nil {
						return ErrUnavailable
					}
					q.DecisionID = uuid.New()
					jobID := uuid.New()
					track, job, e := db.CreateCapturedSourceDownloadTx(ctx, tx, o.UserID, q.Source.SelectionSessionID, q.DecisionID, jobID, q.Source.CandidateID, q.Selected, now)
					if e != nil {
						return ErrConflict
					}
					q.TrackID = track
					q.Status = "ready"
					if job {
						q.JobID = jobID
						q.Status = "importing"
					}
				} else {
					for _, c := range j.State.Catalog {
						if c.CatalogItemID == q.CatalogItemID {
							q.TrackID = c.TrackID
						}
					}
					if e := ownedPlayable(ctx, tx, o.UserID, q.TrackID); e != nil {
						return e
					}
					q.Status = "ready"
				}
				j.State.ApprovalSequence++
				q.ApprovalOrder = j.State.ApprovalSequence
				q.ApprovalDigest = digest(in)
				q.HostSessionID = in.HostSessionID
				q.AdmissionKey = digest(map[string]any{"ownerUserId": o.UserID, "ownerAuthGeneration": o.Generation, "jamId": id, "requestId": q.RequestID, "hostDeviceId": j.State.DeviceID, "leaseId": j.State.LeaseID, "hostSessionId": in.HostSessionID})
				j.Version++
				if e := save(ctx, tx, j); e != nil {
					return e
				}
			}
			if e := reconcile(ctx, tx, j, now); e != nil {
				return e
			}
			if q.JobID != uuid.Nil && q.Status == "importing" {
				copy := *q
				publish = &copy
			}
			out = hostView(j, now)
			return nil
		}
		return ErrDenied
	})
	if err != nil {
		return out, err
	}
	if publish != nil {
		c, e := db.SourceCandidateFromCapture(publish.Selected)
		if e != nil {
			return out, e
		}
		// Lost Redis ACK is deliberately NOT marked failed. Repeating the exact
		// approval or boot recovery ensures this SAME durable job ID.
		if _, e = r.Downloads.EnsureSourceCandidateWithID(ctx, publish.JobID.String(), o.UserID.String(), c, nil); e != nil {
			return out, ErrUnavailable
		}
	}
	return out, nil
}
func requestMemberLive(j *row, q *requestRecord, now time.Time) bool {
	for _, m := range j.State.Members {
		if m.Hash == q.MemberHash {
			return !m.Revoked && now.Before(m.Expires)
		}
	}
	return false
}
func admissible(j *row, q *requestRecord, now time.Time) bool {
	if q.Status != "ready" || q.TrackID <= 0 || !online(j, now) || !requestMemberLive(j, q, now) {
		return false
	}
	for _, earlier := range j.State.Requests {
		if earlier.ApprovalOrder > 0 && earlier.ApprovalOrder < q.ApprovalOrder && unadmitted(earlier.Status) {
			return false
		}
	}
	return true
}
func ownedPlayable(ctx context.Context, tx *sql.Tx, owner uuid.UUID, track int64) error {
	var id int64
	e := tx.QueryRowContext(ctx, `SELECT t.id FROM tracks t JOIN user_library l ON l.track_id=t.id WHERE l.user_id=$1 AND t.id=$2 AND COALESCE(t.storage_key,'')<>'' FOR SHARE OF t,l`, owner, track).Scan(&id)
	return deniedMissing(e)
}
func reconcile(ctx context.Context, tx *sql.Tx, j *row, now time.Time) error {
	changed := false
	for i := range j.State.Requests {
		q := &j.State.Requests[i]
		if !unadmitted(q.Status) {
			continue
		}
		if !live(j, now) || !requestMemberLive(j, q, now) {
			q.Status = "withdrawn"
			changed = true
			continue
		}
		if q.Status == "importing" {
			var status string
			var track sql.NullInt64
			e := tx.QueryRowContext(ctx, `SELECT d.track_id,j.status FROM source_selection_decisions d JOIN download_jobs j ON j.id=d.download_job_id AND j.user_id=d.user_id WHERE d.id=$1 AND d.user_id=$2 AND j.id=$3`, q.DecisionID, j.Owner, q.JobID).Scan(&track, &status)
			if errors.Is(e, sql.ErrNoRows) {
				q.Status = "failed"
				changed = true
				continue
			}
			if e != nil {
				return e
			}
			if status == "failed" {
				q.Status = "failed"
				changed = true
				continue
			}
			if status == "complete" && track.Valid {
				if e = ownedPlayable(ctx, tx, j.Owner, track.Int64); e != nil {
					if errors.Is(e, ErrDenied) {
						q.Status = "failed"
						changed = true
						continue
					}
					return e
				}
				q.TrackID = track.Int64
				q.Status = "ready"
				changed = true
			}
		}
		if q.Status == "ready" {
			if e := ownedPlayable(ctx, tx, j.Owner, q.TrackID); e != nil {
				if errors.Is(e, ErrDenied) {
					q.Status = "failed"
					changed = true
					continue
				}
				return e
			}
			// Resolved aliases recheck against earlier approved or already admitted
			// party identities. Ordinary host A/B/A queue semantics are untouched.
			for _, other := range j.State.Requests {
				track := other.TrackID
				for _, c := range j.State.Catalog {
					if other.CatalogItemID == c.CatalogItemID {
						track = c.TrackID
					}
				}
				if other.RequestID != q.RequestID && track == q.TrackID && (other.Status == "queued" || (other.ApprovalOrder > 0 && other.ApprovalOrder < q.ApprovalOrder && unadmitted(other.Status))) {
					q.Status = "duplicate"
					changed = true
					break
				}
			}
		}
	}
	if changed {
		j.Version++
		return save(ctx, tx, j)
	}
	return nil
}
