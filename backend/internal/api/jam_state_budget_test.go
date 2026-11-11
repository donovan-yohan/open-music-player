package api

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/jam"
)

// Reads reconcile and persist request state. A write that leaves the stored
// jsonb within bytes of the CHECK limit would make every later read fail once
// reconciliation lengthens a status, so ordinary writes must keep headroom and
// admissions must fail as capacity, not as a raw constraint error.
func TestJamStateBudgetKeepsReconciliationHeadroom(t *testing.T) {
	repo, o, p, _ := jamIntegration(t)
	ctx := context.Background()
	clock := time.Now().UTC().Truncate(time.Second)
	repo.Now = func() time.Time { return clock }
	id := uuid.New()
	created, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}})
	if e != nil {
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
	request := uuid.New()
	if _, e = repo.AddRequest(ctx, id, secret, jam.RequestInput{RequestID: request, CatalogItemID: created.Catalog[0].CatalogItemID, ExpectedVersion: created.Version}); e != nil {
		t.Fatal(e)
	}
	// The first heartbeat sets every fixed-width host field. The second only
	// lengthens the title, so its growth is exact.
	if _, e = repo.Heartbeat(ctx, o, id, jam.HeartbeatInput{Proof: p, HostSequence: 1, NowPlaying: &jam.NowPlaying{Title: "Budget", Artist: "Host"}}); e != nil {
		t.Fatal(e)
	}
	const growth = 10
	longer := &jam.NowPlaying{Title: "Budget" + strings.Repeat("y", growth), Artist: "Host"}
	var size int
	if e = repo.DB.QueryRow(`SELECT octet_length(state::text) FROM jams WHERE id=$1`, id).Scan(&size); e != nil {
		t.Fatal(e)
	}
	// Pad the stored state so the second heartbeat would land one byte under
	// the CHECK limit, leaving reconciliation no room.
	pad := jam.MaxStateBytes - 1 - growth - size
	if _, e = repo.DB.Exec(`UPDATE jams SET state=jsonb_set(state,'{catalog,0,title}',to_jsonb((state#>>'{catalog,0,title}')||$2::text)) WHERE id=$1`, id, strings.Repeat("x", pad)); e != nil {
		t.Fatal(e)
	}
	secondSecret := jam.NewSecret()
	if _, e = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Late", MemberSecret: secondSecret}); !errors.Is(e, jam.ErrCapacity) {
		t.Fatalf("join near the state limit = %v, want capacity", e)
	}
	if _, e = repo.Heartbeat(ctx, o, id, jam.HeartbeatInput{Proof: p, HostSequence: 2, NowPlaying: longer}); !errors.Is(e, jam.ErrCapacity) {
		t.Fatalf("heartbeat into reconciliation headroom = %v, want capacity", e)
	}
	// The guest goes away; the next read must still persist the withdrawal.
	clock = clock.Add(2 * time.Minute)
	view, e := repo.HostSnapshot(ctx, o, id)
	if e != nil {
		t.Fatalf("read could not persist reconciliation: %v", e)
	}
	if len(view.HostRequests) != 1 || view.HostRequests[0].Status != "withdrawn" {
		t.Fatalf("reconciled requests = %+v", view.HostRequests)
	}
	var stored string
	if e = repo.DB.QueryRow(`SELECT state#>>'{requests,0,status}' FROM jams WHERE id=$1`, id).Scan(&stored); e != nil || stored != "withdrawn" {
		t.Fatalf("stored status = %q, %v", stored, e)
	}
}
