package db

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type analysisLifecycleSQL struct {
	query string
	args  []driver.NamedValue
	rows  int64
	err   error
}
type analysisLifecycleConnector struct{ state *analysisLifecycleSQL }

func (c analysisLifecycleConnector) Connect(context.Context) (driver.Conn, error) {
	return analysisLifecycleConn{c.state}, nil
}
func (c analysisLifecycleConnector) Driver() driver.Driver { return analysisLifecycleDriver{c.state} }

type analysisLifecycleDriver struct{ state *analysisLifecycleSQL }

func (d analysisLifecycleDriver) Open(string) (driver.Conn, error) {
	return analysisLifecycleConn{d.state}, nil
}

type analysisLifecycleConn struct{ state *analysisLifecycleSQL }

func (analysisLifecycleConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("unexpected prepare")
}
func (analysisLifecycleConn) Close() error { return nil }
func (analysisLifecycleConn) Begin() (driver.Tx, error) {
	return nil, errors.New("unexpected transaction")
}
func (c analysisLifecycleConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	c.state.query = query
	c.state.args = append([]driver.NamedValue(nil), args...)
	return driver.RowsAffected(c.state.rows), c.state.err
}
func newAnalysisLifecycleRepo(t *testing.T, rows int64) (*AnalysisRepository, *analysisLifecycleSQL) {
	t.Helper()
	state := &analysisLifecycleSQL{rows: rows}
	raw := sql.OpenDB(analysisLifecycleConnector{state})
	t.Cleanup(func() { _ = raw.Close() })
	return NewAnalysisRepository(&DB{DB: raw}), state
}

type analysisSchedulingRequester interface {
	RequestAnalysisIfNeeded(context.Context, int64, json.RawMessage) (bool, error)
}

func TestAnalysisRequestReturnsAtomicSchedulingDecision(t *testing.T) {
	for _, rows := range []int64{0, 1} {
		t.Run(string(rune('0'+rows)), func(t *testing.T) {
			repo, captured := newAnalysisLifecycleRepo(t, rows)
			requester, ok := any(repo).(analysisSchedulingRequester)
			if !ok {
				t.Fatal("analysis request cannot report whether work needs scheduling")
			}
			queued, err := requester.RequestAnalysisIfNeeded(context.Background(), 42, json.RawMessage(`{"source":{"storage_key":"canonical-a"}}`))
			if err != nil || queued != (rows == 1) {
				t.Fatalf("scheduling decision = %v, %v for affected rows %d", queued, err, rows)
			}
			query := strings.Join(strings.Fields(captured.query), " ")
			if !strings.Contains(query, "WHERE track_analysis.status IN ('failed', 'stale')") {
				t.Fatalf("request must leave analyzed/active/unsupported rows and their provenance unchanged: %s", query)
			}
		})
	}
}

func TestAnalysisClaimOnlyTransitionsPendingWork(t *testing.T) {
	repo, captured := newAnalysisLifecycleRepo(t, 0)
	if err := repo.MarkAnalyzing(context.Background(), 42, nil); !errors.Is(err, ErrAnalysisResultSuperseded) {
		t.Fatalf("unclaimable request = %v", err)
	}
	query := strings.Join(strings.Fields(captured.query), " ")
	if !strings.Contains(query, "AND status = $4") || len(captured.args) != 4 || captured.args[3].Value != AnalysisStatusPending {
		t.Fatalf("claim admits already analyzed or unrequested stale work: query=%s args=%+v", query, captured.args)
	}
}
