package api

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/jam"
)

func TestJamAcquisitionDuplicateAndExpiredCaptureDoNotAcquire(t *testing.T) {
	repo, o, p, m := jamIntegration(t)
	ctx := context.Background()
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{&jamSyntheticProvider{}}})
	repo.Downloads = &jamNeverPublisher{t: t}
	id := uuid.New()
	path := "/api/v1/jams/" + id.String()
	_, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}, AllowOutsideDiscovery: true})
	if e != nil {
		t.Fatal(e)
	}
	invite, e := repo.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	secrets := []string{jam.NewSecret(), jam.NewSecret()}
	searches := make([]jam.SearchResult, 2)
	for i, secret := range secrets {
		if _, e = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Fixture", MemberSecret: secret}); e != nil {
			t.Fatal(e)
		}
		searches[i], e = repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "synthetic"})
		if e != nil {
			t.Fatal(e)
		}
	}
	qid := uuid.New()
	_, e = repo.AddSourceRequest(ctx, id, secrets[0], jam.SourceRequestInput{RequestID: qid, SelectionSessionID: searches[0].SearchID, CandidateID: searches[0].Results[0].CandidateID, ExpectedVersion: 1})
	if e != nil {
		t.Fatal(e)
	}
	_, e = repo.AddSourceRequest(ctx, id, secrets[1], jam.SourceRequestInput{RequestID: uuid.New(), SelectionSessionID: searches[1].SearchID, CandidateID: searches[1].Results[0].CandidateID, ExpectedVersion: 2})
	if e != jam.ErrConflict {
		t.Fatalf("same source duplicated %v", e)
	}
	// Expire only the source snapshot, not member or host authority.
	if _, e = repo.DB.Exec(`UPDATE source_selection_sessions SET created_at=clock_timestamp()-interval '10 minutes',expires_at=clock_timestamp()-interval '1 second' WHERE id=$1`, searches[0].SearchID); e != nil {
		t.Fatal(e)
	}
	code, b := jamOwnerHTTP(t, m, o, "POST", path+"/requests/"+qid.String()+"/approval", map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": 2, "hostSessionId": "expiry-fixture"})
	if code != 409 {
		t.Fatalf("expired selection approved %d %s", code, b)
	}
	var count int
	if e = repo.DB.QueryRow(`SELECT count(*) FROM download_jobs`).Scan(&count); e != nil || count != 0 {
		t.Fatal("expired/duplicate capture acquired")
	}
	code, b = jamOwnerHTTP(t, m, o, "GET", path, nil)
	if code != 200 {
		t.Fatal(code)
	}
	var view jam.HostView
	_ = json.Unmarshal(b, &view)
	if len(view.HostRequests) != 1 || view.HostRequests[0].Status != "pending" {
		t.Fatal("failed approval partially committed")
	}
}
