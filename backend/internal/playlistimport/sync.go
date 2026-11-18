package playlistimport

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/lib/pq"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/playlistsync"
)

var ErrSyncConflict = errors.New("source sync conflict")
var ErrSyncUnavailable = errors.New("source unavailable; relink required")

type SyncOperation struct {
	ID             uuid.UUID `json:"id"`
	PlaylistID     int64     `json:"playlistId"`
	Status         string    `json:"status"`
	Accepted       bool      `json:"accepted"`
	Generation     int64     `json:"generation"`
	Added          int       `json:"added"`
	Removed        int       `json:"removed"`
	Reordered      bool      `json:"reordered"`
	Pending        int       `json:"pending"`
	Failed         int       `json:"failed"`
	ErrorCode      string    `json:"errorCode,omitempty"`
	requestBinding int64
	bindingID      int64
	sourceURL      string
	owner          uuid.UUID
}
type SyncState struct {
	Eligible  bool           `json:"eligible"`
	BindingID int64          `json:"bindingId"`
	Reason    string         `json:"reason,omitempty"`
	Operation *SyncOperation `json:"operation,omitempty"`
}

// syncSource is resolved exclusively from current owned durable evidence. A GET
// may inspect legacy evidence, but only explicit reservation persists its binding.
func (r *ImportRepository) syncSource(ctx context.Context, tx *sql.Tx, user uuid.UUID, playlist int64) (*db.PlaylistSourceBinding, []db.ResolvedPlaylistSourceEntry, error) {
	var id int64
	if err := tx.QueryRowContext(ctx, `SELECT id FROM playlists WHERE id=$1 AND user_id=$2 FOR UPDATE`, playlist, user).Scan(&id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil, db.ErrPlaylistNotOwned
		}
		return nil, nil, err
	}
	b := &db.PlaylistSourceBinding{PlaylistID: playlist, UserID: user}
	err := tx.QueryRowContext(ctx, `SELECT id,provider,provider_playlist_id,canonical_url,snapshot_generation,snapshot_fingerprint,sync_enabled,last_sync_status,last_sync_started_at,last_sync_completed_at,last_sync_error_redacted FROM playlist_source_bindings WHERE playlist_id=$1 AND user_id=$2 FOR UPDATE`, playlist, user).Scan(&b.ID, &b.Provider, &b.ProviderPlaylistID, &b.CanonicalURL, &b.SnapshotGeneration, &b.SnapshotFingerprint, &b.SyncEnabled, &b.LastSyncStatus, &b.LastSyncStartedAt, &b.LastSyncCompletedAt, &b.LastSyncErrorRedacted)
	if err == nil {
		if b.Provider != "youtube" {
			return nil, nil, ErrSyncUnavailable
		}
		pid, e := youtubePlaylistID(b.CanonicalURL)
		if e != nil || pid != b.ProviderPlaylistID {
			return nil, nil, ErrSyncUnavailable
		}
		return b, nil, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, nil, err
	}
	rows, err := tx.QueryContext(ctx, `SELECT j.source_url,i.source_id,i.track_id,i.playlist_position FROM playlist_import_jobs j LEFT JOIN playlist_import_items i ON i.import_job_id=j.id WHERE j.playlist_id=$1 AND j.user_id=$2 AND NOT j.is_source_sync ORDER BY j.created_at,i.source_index LIMIT 4001`, playlist, user)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	entries := map[string]db.ResolvedPlaylistSourceEntry{}
	var source string
	count := 0
	for rows.Next() {
		count++
		if count > 4000 {
			return nil, nil, ErrSyncUnavailable
		}
		var raw string
		var stable sql.NullString
		var track sql.NullInt64
		var pos sql.NullInt64
		if err := rows.Scan(&raw, &stable, &track, &pos); err != nil {
			return nil, nil, err
		}
		pid, e := youtubePlaylistID(raw)
		if e != nil {
			return nil, nil, ErrSyncUnavailable
		}
		if source != "" && source != pid {
			return nil, nil, ErrSyncUnavailable
		}
		source = pid
		if !stable.Valid || stable.String == "" || !pos.Valid || pos.Int64 < 0 {
			return nil, nil, ErrSyncUnavailable
		}
		v := db.ResolvedPlaylistSourceEntry{ProviderEntryID: stable.String, SourceURL: youtubeWatchURL(stable.String), SourceOrder: int(pos.Int64)}
		if track.Valid {
			v.TrackID = track.Int64
		}
		if old, ok := entries[stable.String]; ok {
			if old.TrackID != 0 && v.TrackID != 0 && old.TrackID != v.TrackID {
				return nil, nil, ErrSyncUnavailable
			}
			if old.TrackID != 0 {
				v.TrackID = old.TrackID
			}
			v.SourceOrder = old.SourceOrder
		}
		entries[stable.String] = v
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	if source == "" || len(entries) == 0 {
		return nil, nil, ErrSyncUnavailable
	}
	out := make([]db.ResolvedPlaylistSourceEntry, 0, len(entries))
	for _, v := range entries {
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].SourceOrder == out[j].SourceOrder {
			return out[i].ProviderEntryID < out[j].ProviderEntryID
		}
		return out[i].SourceOrder < out[j].SourceOrder
	})
	for i := range out {
		out[i].SourceOrder = i
	}
	var conflicts int
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_source_bindings WHERE user_id=$1 AND provider='youtube' AND provider_playlist_id=$2`, user, source).Scan(&conflicts); err != nil {
		return nil, nil, err
	}
	if conflicts > 0 {
		return nil, nil, ErrSyncUnavailable
	}
	b.Provider = "youtube"
	b.ProviderPlaylistID = source
	b.CanonicalURL = canonicalYouTubePlaylistURL(source)
	return b, out, nil
}

func (r *ImportRepository) InspectSync(ctx context.Context, user uuid.UUID, playlist int64, requested ...uuid.UUID) (*SyncState, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	b, _, err := r.syncSource(ctx, tx, user, playlist)
	state := &SyncState{}
	if errors.Is(err, ErrSyncUnavailable) {
		state.Reason = "relink_required"
	} else if err != nil {
		return nil, err
	} else {
		state.Eligible = true
		state.BindingID = b.ID
	}
	// Recovery does not require the source still to be eligible.
	query := syncSelect + ` WHERE user_id=$1 AND playlist_id=$2 AND is_source_sync`
	args := []any{user, playlist}
	if len(requested) > 0 {
		query += ` AND id=$3`
		args = append(args, requested[0])
	}
	op, e := scanSync(tx.QueryRowContext(ctx, query+` ORDER BY created_at DESC,id DESC LIMIT 1`, args...))
	if e == nil {
		state.Operation = op
	} else if !errors.Is(e, sql.ErrNoRows) {
		return nil, e
	}
	return state, nil
}

const syncSelect = `SELECT id,user_id,playlist_id,COALESCE(sync_binding_id,0),source_url,status,sync_accepted,sync_generation,sync_added,sync_removed,sync_reordered,queued_items,failed_items,COALESCE(error,''),sync_request_binding_id FROM playlist_import_jobs`

type syncScanner interface{ Scan(...any) error }

func scanSync(row syncScanner) (*SyncOperation, error) {
	v := &SyncOperation{}
	err := row.Scan(&v.ID, &v.owner, &v.PlaylistID, &v.bindingID, &v.sourceURL, &v.Status, &v.Accepted, &v.Generation, &v.Added, &v.Removed, &v.Reordered, &v.Pending, &v.Failed, &v.ErrorCode, &v.requestBinding)
	return v, err
}
func (r *ImportRepository) ReserveSync(ctx context.Context, user uuid.UUID, playlist, binding int64, key uuid.UUID) (*SyncOperation, error) {
	if key == uuid.Nil {
		return nil, ErrSyncConflict
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	// Serialize duplicate-key reservations across playlists before any source work.
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, key.String()); err != nil {
		return nil, err
	}
	old, e := scanSync(tx.QueryRowContext(ctx, syncSelect+` WHERE id=$1 AND is_source_sync`, key))
	if e == nil {
		if old.owner != user || old.PlaylistID != playlist || old.requestBinding != binding {
			return nil, ErrSyncConflict
		}
		return old, nil
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return nil, e
	}
	b, legacy, err := r.syncSource(ctx, tx, user, playlist)
	if err != nil {
		return nil, err
	}
	if b.ID != binding {
		return nil, ErrSyncConflict
	}
	// A newer explicit intent may replace accepted membership while an older
	// acquisition finishes. Outstanding track jobs retain their source-bound claim.
	if _, err = tx.ExecContext(ctx, `UPDATE playlist_import_jobs SET status='superseded',updated_at=clock_timestamp() WHERE playlist_id=$1 AND is_source_sync AND sync_accepted AND status='importing'`, playlist); err != nil {
		return nil, err
	}
	var active int
	if err = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_import_jobs WHERE playlist_id=$1 AND is_source_sync AND status IN ('resolving','importing')`, playlist).Scan(&active); err != nil {
		return nil, err
	}
	if active > 0 {
		return nil, ErrSyncConflict
	}
	if b.ID == 0 {
		// Historical mappings are evidence of provenance, NOT a new remote snapshot.
		err = tx.QueryRowContext(ctx, `INSERT INTO playlist_source_bindings(playlist_id,user_id,provider,provider_playlist_id,canonical_url,sync_enabled) VALUES($1,$2,$3,$4,$5,FALSE) RETURNING id`, playlist, user, b.Provider, b.ProviderPlaylistID, b.CanonicalURL).Scan(&b.ID)
		if err != nil {
			var pe *pq.Error
			if errors.As(err, &pe) && pe.Code == "23505" {
				return nil, ErrSyncUnavailable
			}
			return nil, err
		}
		for _, v := range legacy {
			_, err = tx.ExecContext(ctx, `INSERT INTO playlist_source_entries(source_binding_id,provider_entry_id,source_url,track_id,source_order) VALUES($1,$2,$3,NULLIF($4,0),$5)`, b.ID, v.ProviderEntryID, v.SourceURL, v.TrackID, v.SourceOrder)
			if err != nil {
				return nil, err
			}
		}
		// Existing historical work becomes source-bound too; no inferred manual claim.
		_, err = tx.ExecContext(ctx, `UPDATE playlist_import_items i SET playlist_source_entry_id=e.id,source_bound=TRUE FROM playlist_import_jobs j,playlist_source_entries e WHERE i.import_job_id=j.id AND j.playlist_id=$1 AND j.user_id=$2 AND e.source_binding_id=$3 AND e.provider_entry_id=i.source_id`, playlist, user, b.ID)
		if err != nil {
			return nil, err
		}
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO playlist_import_jobs(id,user_id,playlist_id,source_url,status,max_items,is_source_sync,sync_binding_id,sync_generation,sync_request_binding_id) VALUES($1,$2,$3,$4,'resolving',1000,TRUE,$5,$6,$7)`, key, user, playlist, b.CanonicalURL, b.ID, b.SnapshotGeneration, binding)
	if err != nil {
		return nil, err
	}
	op, err := scanSync(tx.QueryRowContext(ctx, syncSelect+` WHERE id=$1`, key))
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return op, nil
}

func (r *ImportRepository) acceptSync(ctx context.Context, op *SyncOperation, snapshot playlistsync.Snapshot) error {
	if err := playlistsync.ValidateComplete(snapshot); err != nil {
		return err
	}
	if len(snapshot.Entries) > HardMaxItems {
		return ErrLimitExceeded
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('playlist-source-import:'||$1::text,0))`, op.PlaylistID); err != nil {
		return err
	}
	b, _, err := r.syncSource(ctx, tx, op.owner, op.PlaylistID)
	if err != nil {
		return err
	}
	current, err := scanSync(tx.QueryRowContext(ctx, syncSelect+` WHERE id=$1 FOR UPDATE`, op.ID))
	if err != nil {
		return err
	}
	if current.Accepted {
		return nil
	}
	if b.ID != op.bindingID || b.SnapshotGeneration != op.Generation || b.CanonicalURL != op.sourceURL || b.Provider != snapshot.Source.Provider || b.ProviderPlaylistID != snapshot.Source.PlaylistID || b.CanonicalURL != snapshot.Source.CanonicalURL {
		return ErrSyncConflict
	}
	rows, err := tx.QueryContext(ctx, `SELECT provider_entry_id,track_id,source_order FROM playlist_source_entries WHERE source_binding_id=$1 ORDER BY source_order,id`, b.ID)
	if err != nil {
		return err
	}
	defer rows.Close()
	known := map[string]int64{}
	prior := []playlistsync.SourceEntryMapping{}
	for rows.Next() {
		var id string
		var track sql.NullInt64
		var order int
		if err = rows.Scan(&id, &track, &order); err != nil {
			rows.Close()
			return err
		}
		known[id] = track.Int64
		prior = append(prior, playlistsync.SourceEntryMapping{StableEntryID: id, Position: order})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	plan, err := playlistsync.PlanReconciliation(snapshot, prior)
	if err != nil {
		return err
	}
	mapping := []db.ResolvedPlaylistSourceEntry{}
	unique := []playlistsync.Entry{}
	seen := map[string]bool{}
	for i, v := range snapshot.Entries {
		if seen[v.StableID] {
			continue
		}
		seen[v.StableID] = true
		unique = append(unique, v)
		mapping = append(mapping, db.ResolvedPlaylistSourceEntry{ProviderEntryID: v.StableID, SourceURL: v.SourceURL, TrackID: known[v.StableID], SourceOrder: i})
	}
	b.SnapshotFingerprint = sql.NullString{String: snapshotFingerprint(snapshot), Valid: true}
	if err = db.NewPlaylistSourceRepository(r.db).ApplyResolvedMappingTx(ctx, tx, b, mapping); err != nil {
		return err
	}
	for i, v := range unique {
		m := mapping[i]
		status := ItemStatusPending
		var errorCode any
		var track any
		if m.TrackID > 0 {
			status = ItemStatusImported
			track = m.TrackID
		} else if v.Metadata.Unavailable {
			status = ItemStatusFailed
			errorCode = "source_unavailable"
		}
		var entryID int64
		if err = tx.QueryRowContext(ctx, `SELECT id FROM playlist_source_entries WHERE source_binding_id=$1 AND provider_entry_id=$2`, b.ID, v.StableID).Scan(&entryID); err != nil {
			return err
		}
		// A desired in-flight acquisition is adopted, never recreated by a later sync.
		var pendingJob sql.NullString
		if status == ItemStatusPending {
			err = tx.QueryRowContext(ctx, `SELECT i.download_job_id FROM playlist_import_items i JOIN download_jobs d ON d.id::text=i.download_job_id WHERE i.playlist_source_entry_id=$1 AND i.status='queued' AND d.status NOT IN ('complete','failed') ORDER BY i.id LIMIT 1`, entryID).Scan(&pendingJob)
			if err != nil && !errors.Is(err, sql.ErrNoRows) {
				return err
			}
			if pendingJob.Valid {
				status = ItemStatusQueued
			}
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO playlist_import_items(import_job_id,source_index,playlist_position,source_id,source_url,title,artist,album,uploader,duration_ms,thumbnail_url,status,error,track_id,playlist_source_entry_id,source_bound,download_job_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,TRUE,$16)`, op.ID, m.SourceOrder+1, m.SourceOrder, v.StableID, v.SourceURL, v.Metadata.Title, v.Metadata.Artist, v.Metadata.Album, v.Metadata.Uploader, v.Metadata.DurationMS, v.Metadata.ThumbnailURL, status, errorCode, track, entryID, pendingJob)
		if err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, `UPDATE playlist_import_jobs SET sync_accepted=TRUE,sync_generation=$2,sync_added=$3,sync_removed=$4,sync_reordered=$5,status='importing',error=NULL,updated_at=clock_timestamp() WHERE id=$1`, op.ID, b.SnapshotGeneration, len(plan.Additions), len(plan.MembershipRemovals), plan.Reordered)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (r *ImportRepository) itemDecision(ctx context.Context, store SourceSelectionStore, user uuid.UUID, item int64, candidate download.SourceCandidate) (*db.SourceSelectionDecision, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var decision uuid.NullUUID
	if err = tx.QueryRowContext(ctx, `SELECT selection_decision_id FROM playlist_import_items WHERE id=$1 FOR UPDATE`, item).Scan(&decision); err != nil {
		return nil, err
	}
	if decision.Valid {
		return db.NewSourceSelectionRepository(r.db).GetDecisionForUser(ctx, user, decision.UUID)
	}
	d, err := store.CreateTrustedSourceSelectionDecision(ctx, user, db.SourceSelectionOriginPlaylistExplicit, trustedPlaylistCandidate(candidate), "server-enumerated explicit playlist entry")
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE playlist_import_items SET selection_decision_id=$2 WHERE id=$1`, item, d.ID); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return d, nil
}

func (r *ImportRepository) refreshSync(ctx context.Context, id uuid.UUID) error {
	_, err := r.db.ExecContext(ctx, `UPDATE playlist_import_items i SET status='imported',track_id=e.track_id,error=NULL FROM playlist_source_entries e WHERE i.import_job_id=$1 AND i.playlist_source_entry_id=e.id AND e.track_id IS NOT NULL`, id)
	if err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `UPDATE playlist_import_items i SET status='failed',error='acquisition_failed' FROM download_jobs d WHERE i.import_job_id=$1 AND i.download_job_id=d.id::text AND i.status='queued' AND d.status='failed'`, id)
	if err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `UPDATE playlist_import_jobs j SET total_items=c.total,queued_items=c.pending,failed_items=c.failed,imported_items=c.imported,status=CASE WHEN c.pending>0 THEN 'importing' WHEN c.failed>0 THEN 'partial_failure' ELSE 'complete' END,updated_at=clock_timestamp() FROM (SELECT COUNT(*)::int total,COUNT(*) FILTER(WHERE status IN ('pending','queued'))::int pending,COUNT(*) FILTER(WHERE status='failed')::int failed,COUNT(*) FILTER(WHERE status='imported')::int imported FROM playlist_import_items WHERE import_job_id=$1) c WHERE j.id=$1 AND j.sync_accepted AND j.status<>'superseded'`, id)
	return err
}

// One finite unit; the SQL session lock also fences other backend instances.
// Only admitted import jobs are resumed. There is no scan/enumeration of bindings.
func (s *Service) ProcessNextSync(ctx context.Context) (bool, error) {
	r, ok := s.store.(*ImportRepository)
	if !ok || s.adapter == nil {
		return false, nil
	}
	conn, err := r.db.Conn(ctx)
	if err != nil {
		return false, err
	}
	defer conn.Close()
	var locked bool
	if err = conn.QueryRowContext(ctx, `SELECT pg_try_advisory_lock(73619021)`).Scan(&locked); err != nil || !locked {
		return false, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, e := conn.ExecContext(cleanup, `SELECT pg_advisory_unlock(73619021)`); e != nil {
			conn.Raw(func(any) error { return driver.ErrBadConn })
		}
	}()
	op, err := scanSync(r.db.QueryRowContext(ctx, syncSelect+` WHERE is_source_sync AND status IN ('resolving','importing') ORDER BY sync_accepted,updated_at,id LIMIT 1`))
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !op.Accepted {
		snapshot, e := s.adapter.Resolve(ctx, op.sourceURL)
		if e == nil {
			e = r.acceptSync(ctx, op, snapshot)
		}
		if e != nil {
			if ctx.Err() != nil {
				return true, ctx.Err()
			}
			code := "source_incomplete"
			if errors.Is(e, ErrSyncConflict) || errors.Is(e, db.ErrPlaylistNotOwned) {
				code = "source_changed"
			}
			_, err = r.db.ExecContext(ctx, `UPDATE playlist_import_jobs SET status='failed',error=$2,updated_at=clock_timestamp() WHERE id=$1 AND NOT sync_accepted`, op.ID, code)
			return true, err
		}
	}
	if err = r.refreshSync(ctx, op.ID); err != nil {
		return true, err
	}
	var busy int
	// At most one outstanding manual-sync acquisition, leaving foreground workers
	// and device-local playback preparation independent of a large source backlog.
	if err = r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM playlist_import_items i JOIN playlist_import_jobs j ON j.id=i.import_job_id JOIN download_jobs d ON d.id::text=i.download_job_id WHERE j.is_source_sync AND i.status='queued' AND d.status NOT IN ('complete','failed')`).Scan(&busy); err != nil {
		return true, err
	}
	if busy > 0 {
		return true, nil
	}
	items, err := r.ListItems(ctx, op.ID)
	if err != nil {
		return true, err
	}
	for _, item := range items {
		if item.Status != ItemStatusPending {
			continue
		}
		itemCopy := []ImportItem{item}
		job := &ImportJob{ID: op.ID, UserID: op.owner, PlaylistID: op.PlaylistID, ManualSync: true}
		if err = s.acquireItems(ctx, op.owner, op.PlaylistID, job, itemCopy); err != nil {
			return true, err
		}
		break
	}
	return true, r.refreshSync(ctx, op.ID)
}

func (s *Service) InspectSync(ctx context.Context, user uuid.UUID, playlist int64, requested ...uuid.UUID) (*SyncState, error) {
	r, ok := s.store.(*ImportRepository)
	if !ok {
		return nil, ErrSyncUnavailable
	}
	return r.InspectSync(ctx, user, playlist, requested...)
}
func (s *Service) StartSync(ctx context.Context, user uuid.UUID, playlist, binding int64, key uuid.UUID) (*SyncOperation, error) {
	r, ok := s.store.(*ImportRepository)
	if !ok {
		return nil, ErrSyncUnavailable
	}
	return r.ReserveSync(ctx, user, playlist, binding, key)
}

// RunManualSync resumes only explicitly admitted jobs, with one enumerator and
// bounded per-track publication. It never enumerates a merely enabled binding.
func (s *Service) RunManualSync(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		_, _ = s.ProcessNextSync(ctx)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
