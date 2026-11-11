package jam

import (
	"context"
	"testing"

	"github.com/google/uuid"
)

// Leaving must retire unadmitted intent, not just the browser capability.
// Otherwise a host's previously captured approval can insert after Leave.
func TestPostgresLeaveRetiresPendingIntent(t *testing.T) {
	r, owner, proof := testRepository(t)
	ctx := context.Background()
	id := createFixture(t, r, owner, proof)
	invite, err := r.RotateInvite(ctx, owner, id, proof)
	if err != nil {
		t.Fatal(err)
	}
	input := JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: NewSecret()}
	joined, err := r.Join(ctx, id, input)
	if err != nil {
		t.Fatal(err)
	}
	request := RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[0].CatalogItemID, ExpectedVersion: joined.Snapshot.Version}
	if _, err = r.AddRequest(ctx, id, input.MemberSecret, request); err != nil {
		t.Fatal(err)
	}
	before, err := r.HostSnapshot(ctx, owner, id)
	if err != nil {
		t.Fatal(err)
	}
	if err = r.Leave(ctx, id, input.MemberSecret); err != nil {
		t.Fatal(err)
	}
	after, err := r.HostSnapshot(ctx, owner, id)
	if err != nil {
		t.Fatal(err)
	}
	if after.HostRequests[0].Status != "withdrawn" || after.Version <= before.Version || after.MemberCount != 0 {
		t.Fatalf("Leave did not retire unadmitted intent: status=%s version=%d prior=%d members=%d", after.HostRequests[0].Status, after.Version, before.Version, after.MemberCount)
	}
	decision := DecisionInput{ExpectedVersion: after.Version, Status: "queued", Receipt: &AdmissionReceipt{RequestID: request.RequestID, SessionID: "fixture-session", OccurrenceID: "fixture-occurrence"}}
	if _, err = r.Decide(ctx, owner, id, proof, request.RequestID, decision); err != ErrConflict {
		t.Fatalf("late admission after Leave: %v", err)
	}
	if err = r.Leave(ctx, id, input.MemberSecret); err != nil {
		t.Fatalf("exact Leave retry must remain idempotent: %v", err)
	}
	if _, err = r.Join(ctx, id, input); err != ErrDenied {
		t.Fatalf("retired join replay: %v", err)
	}
}

func TestPostgresEndRetiresPendingButPreservesQueuedReceipts(t *testing.T) {
	r, owner, proof := testRepository(t)
	ctx := context.Background()
	if _, err := r.DB.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,2)`, owner.UserID); err != nil {
		t.Fatal(err)
	}
	id := uuid.New()
	if _, err := r.Create(ctx, owner, CreateInput{JamID: id, Proof: proof, TrackIDs: []int64{1, 2}}); err != nil {
		t.Fatal(err)
	}
	invite, err := r.RotateInvite(ctx, owner, id, proof)
	if err != nil {
		t.Fatal(err)
	}
	for index := 0; index < 2; index++ {
		input := JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: NewSecret()}
		joined, err := r.Join(ctx, id, input)
		if err != nil {
			t.Fatal(err)
		}
		request := RequestInput{RequestID: uuid.New(), CatalogItemID: joined.Snapshot.Catalog[index].CatalogItemID, ExpectedVersion: joined.Snapshot.Version}
		if _, err = r.AddRequest(ctx, id, input.MemberSecret, request); err != nil {
			t.Fatal(err)
		}
		if index == 0 {
			view, err := r.HostSnapshot(ctx, owner, id)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = r.Decide(ctx, owner, id, proof, request.RequestID, DecisionInput{ExpectedVersion: view.Version, Status: "queued", Receipt: &AdmissionReceipt{RequestID: request.RequestID, SessionID: "fixture-session", OccurrenceID: "fixture-occurrence"}}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err = r.Close(ctx, owner, id); err != nil {
		t.Fatal(err)
	}
	view, err := r.HostSnapshot(ctx, owner, id)
	if err != nil {
		t.Fatal(err)
	}
	if view.HostRequests[0].Status != "queued" || view.HostRequests[0].Receipt.OccurrenceID != "fixture-occurrence" || view.HostRequests[1].Status != "withdrawn" || view.MemberCount != 0 {
		t.Fatalf("End must retire only unadmitted intent: statuses=%s,%s members=%d", view.HostRequests[0].Status, view.HostRequests[1].Status, view.MemberCount)
	}
}
