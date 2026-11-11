package api

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/jam"
)

// A pending source request whose selection session expired can never be
// approved. It must stop holding the guest's slot, and a failed approval must
// still commit its retirement instead of leaving it pending.
func TestJamExpiredSourceRequestReleasesSlotAndRetiresOnApproval(t *testing.T) {
	repo, o, p, _ := jamIntegration(t)
	ctx := context.Background()
	clock := time.Now().UTC()
	repo.Now = func() time.Time { return clock }
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{&jamSyntheticProvider{}}})
	repo.Downloads = &jamNeverPublisher{t: t}
	id := uuid.New()
	if _, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}, AllowOutsideDiscovery: true}); e != nil {
		t.Fatal(e)
	}
	invite, e := repo.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	secret := jam.NewSecret()
	if _, e = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Fixture", MemberSecret: secret}); e != nil {
		t.Fatal(e)
	}
	first, e := repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "synthetic"})
	if e != nil {
		t.Fatal(e)
	}
	expired := uuid.New()
	if _, e = repo.AddSourceRequest(ctx, id, secret, jam.SourceRequestInput{RequestID: expired, SelectionSessionID: first.SearchID, CandidateID: first.Results[0].CandidateID, ExpectedVersion: 1}); e != nil {
		t.Fatal(e)
	}
	// Host and guest stay live; only the captured selection ages out.
	var hostSequence, guestSequence int64
	for !clock.After(first.ExpiresAt) {
		clock = clock.Add(20 * time.Second)
		hostSequence++
		if _, e = repo.Heartbeat(ctx, o, id, jam.HeartbeatInput{Proof: p, HostSequence: hostSequence}); e != nil {
			t.Fatal(e)
		}
		guestSequence++
		if _, e = repo.MemberHeartbeat(ctx, id, secret, guestSequence); e != nil {
			t.Fatal(e)
		}
	}
	// No read has reconciled yet: the expired request must not block a new one.
	second, e := repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "synthetic"})
	if e != nil {
		t.Fatal(e)
	}
	replacement := uuid.New()
	if _, e = repo.AddSourceRequest(ctx, id, secret, jam.SourceRequestInput{RequestID: replacement, SelectionSessionID: second.SearchID, CandidateID: second.Results[0].CandidateID, ExpectedVersion: 2}); e != nil {
		t.Fatalf("expired pending request still holds the guest slot/source: %v", e)
	}
	if _, e = repo.Approve(ctx, o, id, p, expired, jam.ApprovalInput{ExpectedVersion: 3, HostSessionID: "expiry-fixture"}); !errors.Is(e, jam.ErrConflict) {
		t.Fatalf("expired approval = %v, want conflict", e)
	}
	statuses := map[string]string{}
	rows, e := repo.DB.Query(`SELECT r->>'requestId', r->>'status' FROM jams, jsonb_array_elements(state->'requests') r WHERE id=$1`, id)
	if e != nil {
		t.Fatal(e)
	}
	defer rows.Close()
	for rows.Next() {
		var requestID, status string
		if e = rows.Scan(&requestID, &status); e != nil {
			t.Fatal(e)
		}
		statuses[requestID] = status
	}
	if statuses[expired.String()] != "withdrawn" || statuses[replacement.String()] != "pending" {
		t.Fatalf("committed request statuses after failed approval = %v", statuses)
	}
}
