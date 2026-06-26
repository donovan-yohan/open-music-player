package db

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
)

const captureUpdateDriverName = "capture_update_mb_match"

var (
	captureUpdateOnce sync.Once
	captureUpdateMu   sync.Mutex
	captureUpdate     capturedUpdate
)

type capturedUpdate struct {
	query string
	args  []driver.NamedValue
	rows  int64
}

type captureUpdateDriver struct{}

type captureUpdateConn struct{}

func (captureUpdateDriver) Open(string) (driver.Conn, error) { return captureUpdateConn{}, nil }

func (captureUpdateConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("prepare not supported")
}

func (captureUpdateConn) Close() error { return nil }

func (captureUpdateConn) Begin() (driver.Tx, error) {
	return nil, errors.New("transactions not supported")
}

func (captureUpdateConn) CheckNamedValue(*driver.NamedValue) error { return nil }

func (captureUpdateConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	captureUpdateMu.Lock()
	defer captureUpdateMu.Unlock()

	captureUpdate.query = query
	captureUpdate.args = append([]driver.NamedValue(nil), args...)
	if captureUpdate.rows == 0 {
		captureUpdate.rows = 1
	}
	return driver.RowsAffected(captureUpdate.rows), nil
}

func newCaptureUpdateRepo(t *testing.T) *TrackRepository {
	t.Helper()
	captureUpdateOnce.Do(func() {
		sql.Register(captureUpdateDriverName, captureUpdateDriver{})
	})

	captureUpdateMu.Lock()
	captureUpdate = capturedUpdate{rows: 1}
	captureUpdateMu.Unlock()

	sqlDB, err := sql.Open(captureUpdateDriverName, "")
	if err != nil {
		t.Fatalf("open capture DB: %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	return NewTrackRepository(&DB{DB: sqlDB})
}

func latestCapturedUpdate(t *testing.T) capturedUpdate {
	t.Helper()
	captureUpdateMu.Lock()
	defer captureUpdateMu.Unlock()
	capture := captureUpdate
	capture.args = append([]driver.NamedValue(nil), captureUpdate.args...)
	return capture
}

func TestUpdateMBMatchAutomaticFallbackDoesNotClearExistingIdentity(t *testing.T) {
	repo := newCaptureUpdateRepo(t)

	if err := repo.UpdateMBMatch(context.Background(), 42, &MBMatchUpdate{
		RespectUserEdits:   true,
		MetadataStatus:     "failed",
		MetadataProvenance: []byte(`{"musicbrainz":{"status":"failed"}}`),
	}); err != nil {
		t.Fatalf("UpdateMBMatch failed: %v", err)
	}

	capture := latestCapturedUpdate(t)
	if len(capture.args) != 16 {
		t.Fatalf("arg count = %d, want 16", len(capture.args))
	}
	if !isNilValue(capture.args[4].Value) {
		t.Fatalf("MBVerified arg = %#v, want nil so existing verification is left unchanged", capture.args[4].Value)
	}
	if capture.args[14].Value != false {
		t.Fatalf("ApplyMBIdentity arg = %#v, want false", capture.args[14].Value)
	}
	if capture.args[15].Value != true {
		t.Fatalf("RespectUserEdits arg = %#v, want true", capture.args[15].Value)
	}
}

func TestUpdateMBMatchUserEditedGuardCoversAutomaticEnrichmentFields(t *testing.T) {
	repo := newCaptureUpdateRepo(t)
	recordingID := uuid.MustParse("11111111-1111-1111-1111-111111111111")
	verified := true
	confidence := 0.95

	if err := repo.UpdateMBMatch(context.Background(), 42, &MBMatchUpdate{
		MBRecordingID:      &recordingID,
		MBVerified:         &verified,
		ApplyMBIdentity:    true,
		RespectUserEdits:   true,
		MetadataStatus:     "enriched",
		MetadataConfidence: &confidence,
		MetadataProvenance: []byte(`{"musicbrainz":{"status":"enriched"}}`),
		CoverArtURL:        "https://coverartarchive.org/release/33333333-3333-3333-3333-333333333333/front-250",
		Title:              "Matched Title",
		Artist:             "Matched Artist",
		Album:              "Matched Album",
		DurationMs:         180000,
	}); err != nil {
		t.Fatalf("UpdateMBMatch failed: %v", err)
	}

	query := latestCapturedUpdate(t).query
	for _, fragment := range []string{
		"mb_recording_id = CASE WHEN $15 AND (metadata_user_edited = FALSE OR $16 = FALSE)",
		"mb_verified = CASE WHEN $5::boolean IS NOT NULL AND (metadata_user_edited = FALSE OR $16 = FALSE)",
		"metadata_status = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE",
		"metadata_confidence = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE",
		"metadata_provenance = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE",
		"cover_art_url = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE",
		"title = CASE WHEN metadata_user_edited = FALSE OR $16 = FALSE",
	} {
		if !strings.Contains(query, fragment) {
			t.Fatalf("UpdateMBMatch query missing user-edit guard fragment %q\nquery:\n%s", fragment, query)
		}
	}
}

func isNilValue(value interface{}) bool {
	if value == nil {
		return true
	}
	switch v := value.(type) {
	case *bool:
		return v == nil
	case *uuid.UUID:
		return v == nil
	default:
		return false
	}
}
