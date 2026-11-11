package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/jam"
)

type jamUnavailableSearchProvider struct{ calls atomic.Int32 }

func (p *jamUnavailableSearchProvider) Name() string { return "youtube" }
func (p *jamUnavailableSearchProvider) Search(context.Context, string, int) ([]discovery.Candidate, error) {
	p.calls.Add(1)
	return nil, errors.New("synthetic provider unavailable")
}

// Actual SQL/Redis/HTTP status sequence behind guest F1. Provider output and host
// authorization are synthetic; no external provider, audio or native claim.
func TestJamReplacementSearchFailureDeniesOldCaptureButKeepsMember(t *testing.T) {
	repo, owner, proof, mux := jamIntegration(t)
	ctx := context.Background()
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{&jamSyntheticProvider{}}})
	repo.Downloads = &jamNeverPublisher{t: t}
	id := uuid.New()
	if _, err := repo.Create(ctx, owner, jam.CreateInput{JamID: id, Proof: proof, TrackIDs: []int64{1}, AllowOutsideDiscovery: true}); err != nil {
		t.Fatal(err)
	}
	invite, err := repo.RotateInvite(ctx, owner, id, proof)
	if err != nil {
		t.Fatal(err)
	}
	secret := jam.NewSecret()
	joined, err := repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Fixture listener", MemberSecret: secret})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(mux)
	defer server.Close()
	base := server.URL + "/api/v1/guest/jams/" + id.String()
	code, body, _ := jamHTTP(t, server.Client(), "POST", base+"/search", secret, jam.SearchInput{SearchID: uuid.New(), Query: "Recording A"})
	if code != 200 {
		t.Fatalf("A search HTTP %d", code)
	}
	var a jam.SearchResult
	if err = json.Unmarshal(body, &a); err != nil || len(a.Results) != 1 {
		t.Fatalf("A capture: %v", err)
	}
	unavailable := &jamUnavailableSearchProvider{}
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{unavailable}})
	b := jam.SearchInput{SearchID: uuid.New(), Query: "Recording B"}
	code, _, _ = jamHTTP(t, server.Client(), "POST", base+"/search", secret, b)
	if code != 503 {
		t.Fatalf("reserved B provider failure HTTP %d", code)
	}
	code, _, _ = jamHTTP(t, server.Client(), "POST", base+"/search", secret, b)
	if code != 409 || unavailable.calls.Load() != 1 {
		t.Fatalf("exact B retry replayed provider or lost reservation: HTTP %d calls %d", code, unavailable.calls.Load())
	}
	old := jam.SourceRequestInput{RequestID: uuid.New(), SelectionSessionID: a.Results[0].SelectionSessionID, CandidateID: a.Results[0].CandidateID, ExpectedVersion: joined.Snapshot.Version}
	code, _, _ = jamHTTP(t, server.Client(), "POST", base+"/source-requests", secret, old)
	if code != 403 {
		t.Fatalf("old A binding must remain denied: HTTP %d", code)
	}
	code, body, _ = jamHTTP(t, server.Client(), "GET", base, secret, nil)
	var visible jam.Snapshot
	if err = json.Unmarshal(body, &visible); code != 200 || err != nil || len(visible.Requests) != 0 {
		t.Fatalf("source denial incorrectly retired member or created request: HTTP %d decode %v", code, err)
	}
	for _, table := range []string{"download_jobs", "source_selection_decisions"} {
		var count int
		if err = repo.DB.QueryRowContext(ctx, "SELECT count(*) FROM "+table).Scan(&count); err != nil || count != 0 {
			t.Fatalf("stale source acquired: %s count %d error %v", table, count, err)
		}
	}
	if err = repo.RevokeMember(ctx, owner, id, proof, joined.MemberID, jam.VersionInput{ExpectedVersion: visible.Version}); err != nil {
		t.Fatal(err)
	}
	code, _, _ = jamHTTP(t, server.Client(), "GET", base, secret, nil)
	if code != 403 {
		t.Fatalf("actually revoked member remained readable: HTTP %d", code)
	}
}
