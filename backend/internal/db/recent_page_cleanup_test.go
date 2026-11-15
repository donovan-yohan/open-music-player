package db

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

// This driver observes the actual database/sql Rows and transaction lifetime.
// It does not require a server or replace RecentPage's revision/hydration code.
func TestRecentPageRowsCleanup(t *testing.T) {
	for _, mode := range []string{"normal", "scan-error", "iteration-error", "stale", "hydration-error", "canceled"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			fixture := &recentCleanupDriver{mode: mode, cancel: cancel}
			name := "recent-cleanup-" + uuid.NewString()
			sql.Register(name, fixture)
			pool, err := sql.Open(name, "")
			if err != nil {
				t.Fatal(err)
			}
			defer pool.Close()
			pool.SetMaxOpenConns(1)
			expected := ""
			if mode == "stale" {
				expected = strings.Repeat("f", 64)
			}
			tracks, revision, more, err := NewPlayEventRepository(&DB{DB: pool}).RecentPage(ctx, uuid.New(), 20, 0, expected)
			if mode == "normal" {
				want := fmt.Sprintf("%x", sha256.Sum256([]byte("7/2026-11-14T12:00:00Z\n")))
				if err != nil || revision != want || len(tracks) != 0 || !more || !fixture.committed {
					t.Fatalf("normal result: tracks=%v revision=%q more=%v error=%v committed=%v", tracks, revision, more, err, fixture.committed)
				}
			} else if err == nil || fixture.committed {
				t.Fatalf("error path accepted: error=%v committed=%v", err, fixture.committed)
			}
			if mode == "stale" && !errors.Is(err, ErrRecentChanged) {
				t.Fatalf("stale revision: %v", err)
			}
			if mode == "canceled" && !errors.Is(err, context.Canceled) {
				t.Fatalf("canceled revision: %v", err)
			}
			// A canceled transaction may be retired by database/sql's goroutine.
			// Acquiring its sole connection synchronizes that retirement.
			conn, connErr := pool.Conn(context.Background())
			if connErr != nil {
				t.Fatal(connErr)
			}
			conn.Close()
			if fixture.revisionCloses != 1 || fixture.active || fixture.violation != "" {
				t.Fatalf("cleanup: closes=%d active=%v violation=%q", fixture.revisionCloses, fixture.active, fixture.violation)
			}
			wantQueries := 1
			if mode == "normal" || mode == "hydration-error" {
				wantQueries = 2
			}
			if fixture.queries != wantQueries || !fixture.began {
				t.Fatalf("snapshot queries=%d want=%d began=%v", fixture.queries, wantQueries, fixture.began)
			}
		})
	}
}

type recentCleanupDriver struct {
	mode           string
	cancel         context.CancelFunc
	began          bool
	active         bool
	committed      bool
	queries        int
	revisionCloses int
	violation      string
}

type recentCleanupConn struct{ fixture *recentCleanupDriver }
type recentCleanupTx struct{ fixture *recentCleanupDriver }
type recentCleanupRows struct {
	fixture  *recentCleanupDriver
	revision bool
	sent     bool
}

func (d *recentCleanupDriver) Open(string) (driver.Conn, error) {
	return &recentCleanupConn{fixture: d}, nil
}
func (c *recentCleanupConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected Prepare")
}
func (c *recentCleanupConn) Close() error { return nil }
func (c *recentCleanupConn) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected Begin without options")
}
func (c *recentCleanupConn) BeginTx(_ context.Context, opts driver.TxOptions) (driver.Tx, error) {
	d := c.fixture
	if opts.Isolation != driver.IsolationLevel(sql.LevelRepeatableRead) || !opts.ReadOnly {
		d.violation = "snapshot options changed"
	}
	d.began, d.active = true, true
	return &recentCleanupTx{fixture: d}, nil
}
func (c *recentCleanupConn) QueryContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	d := c.fixture
	d.queries++
	if !d.active {
		d.violation = "query outside transaction"
	}
	if d.queries == 1 {
		if !strings.HasPrefix(query, "SELECT track_id, MAX(played_at)") {
			d.violation = "revision query order changed"
		}
		return &recentCleanupRows{fixture: d, revision: true}, nil
	}
	if d.revisionCloses != 1 {
		d.violation = "revision rows open during hydration"
	}
	if d.mode == "hydration-error" {
		return nil, errors.New("synthetic hydration error")
	}
	return &recentCleanupRows{fixture: d}, nil
}
func (tx *recentCleanupTx) retire() {
	d := tx.fixture
	if d.revisionCloses != 1 {
		d.violation = "revision rows open during transaction retirement"
	}
	d.active = false
}
func (tx *recentCleanupTx) Commit() error {
	tx.fixture.committed = true
	tx.retire()
	return nil
}
func (tx *recentCleanupTx) Rollback() error { tx.retire(); return nil }
func (r *recentCleanupRows) Columns() []string {
	if r.revision {
		return []string{"track_id", "max"}
	}
	return []string{"unused empty hydration"}
}
func (r *recentCleanupRows) Close() error {
	if r.revision {
		r.fixture.revisionCloses++
	}
	return nil
}
func (r *recentCleanupRows) Next(values []driver.Value) error {
	if !r.revision || r.sent {
		return io.EOF
	}
	r.sent = true
	switch r.fixture.mode {
	case "iteration-error":
		return errors.New("synthetic revision iteration error")
	case "canceled":
		r.fixture.cancel()
		return context.Canceled
	case "scan-error":
		values[0] = "not-an-integer"
	default:
		values[0] = int64(7)
	}
	values[1] = time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	return nil
}
