package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/jam"
)

func TestJamAcquisitionRetirementFencesLateCompletion(t *testing.T) {
	for _, action := range []string{"withdraw", "revoke", "end", "generation", "leave", "expire"} {
		t.Run(action, func(t *testing.T) {
			repo, o, p, m := jamIntegration(t)
			ctx := context.Background()
			lifecycle := db.NewSourceSelectionDownloadLifecycle(&db.DB{DB: repo.DB})
			service, e := download.NewService(&download.ServiceConfig{RedisURL: "redis://" + os.Getenv("JAM_TEST_REDIS") + "/0", WorkerCount: 0}, nil, lifecycle)
			if e != nil {
				t.Fatal(e)
			}
			t.Cleanup(func() { _ = service.Queue().Close() })
			repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{&jamSyntheticProvider{}}})
			repo.Downloads = service
			id := uuid.New()
			path := "/api/v1/jams/" + id.String()
			_, e = repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}, AllowOutsideDiscovery: true})
			if e != nil {
				t.Fatal(e)
			}
			invite, e := repo.RotateInvite(ctx, o, id, p)
			if e != nil {
				t.Fatal(e)
			}
			secret := jam.NewSecret()
			_, e = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Synthetic listener", MemberSecret: secret})
			if e != nil {
				t.Fatal(e)
			}
			result, e := repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "synthetic"})
			if e != nil {
				t.Fatal(e)
			}
			source := result.Results[0]
			requestID := uuid.New()
			_, e = repo.AddSourceRequest(ctx, id, secret, jam.SourceRequestInput{RequestID: requestID, SelectionSessionID: source.SelectionSessionID, CandidateID: source.CandidateID, ExpectedVersion: 1})
			if e != nil {
				t.Fatal(e)
			}
			code, b := jamOwnerHTTP(t, m, o, "POST", path+"/requests/"+requestID.String()+"/approval", map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": 2, "hostSessionId": "retirement-fixture"})
			if code != 200 {
				t.Fatalf("approve %d %s", code, b)
			}
			var view jam.HostView
			_ = json.Unmarshal(b, &view)
			q := view.HostRequests[0]
			job, e := service.GetJob(ctx, q.DownloadJobID.String())
			if e != nil {
				t.Fatal(e)
			}
			t.Cleanup(func() {
				client := service.Queue().Client()
				client.LRem(ctx, "download:queue", 0, job.ID)
				client.Del(ctx, "download:job:"+job.ID)
			})
			server := httptest.NewServer(m)
			defer server.Close()
			base := server.URL + "/api/v1/guest/jams/" + id.String()
			switch action {
			case "withdraw":
				code, b, _ = jamHTTP(t, server.Client(), "DELETE", base+"/requests/"+requestID.String(), secret, jam.VersionInput{ExpectedVersion: view.Version})
				if code != 204 {
					t.Fatalf("withdraw %d %s", code, b)
				}
			case "leave":
				code, b, _ = jamHTTP(t, server.Client(), "DELETE", base+"/members/me", secret, nil)
				if code != 204 {
					t.Fatalf("leave %d %s", code, b)
				}
			case "revoke":
				// Target comes EXCLUSIVELY from the authenticated host producer response.
				code, b = jamOwnerHTTP(t, m, o, "DELETE", path+"/members/"+view.Members[0].MemberID.String(), map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": view.Version})
				if code != 204 {
					t.Fatalf("revoke %d %s", code, b)
				}
			case "end":
				code, b = jamOwnerHTTP(t, m, o, "DELETE", path, nil)
				if code != 204 {
					t.Fatalf("end %d %s", code, b)
				}
			case "generation":
				if _, e = repo.DB.Exec(`UPDATE users SET connect_auth_generation=connect_auth_generation+1 WHERE id=$1`, o.UserID); e != nil {
					t.Fatal(e)
				}
			case "expire":
				now := repo.Now()
				repo.Now = func() time.Time { return now.Add(61 * time.Second) }
			}
			// Even after intent retirement, an already authorized acquisition may finish
			// and add Library membership. It must NEVER revive party admission.
			if _, e = repo.DB.Exec(`INSERT INTO tracks(id,identity_hash,title,storage_key) VALUES(2,'retirement-synthetic','Synthetic acquired','synthetic-no-media')`); e != nil {
				t.Fatal(e)
			}
			if _, e = repo.DB.Exec(`INSERT INTO user_library(user_id,track_id) VALUES($1,2)`, o.UserID); e != nil {
				t.Fatal(e)
			}
			track := int64(2)
			job.TrackID = &track
			if e = lifecycle.Complete(ctx, job); e != nil {
				t.Fatal(e)
			}
			code, b = jamOwnerHTTP(t, m, o, "GET", path, nil)
			if action == "generation" {
				if code != 403 {
					t.Fatalf("retired generation read %d", code)
				}
			} else {
				if code != 200 {
					t.Fatalf("retired read %d %s", code, b)
				}
				_ = json.Unmarshal(b, &view)
				if view.HostRequests[0].Status != "withdrawn" || view.HostRequests[0].CanAdmit {
					t.Fatalf("late completion revived intent %+v", view.HostRequests[0])
				}
			}
			code, _ = jamOwnerHTTP(t, m, o, "PUT", path+"/requests/"+requestID.String(), map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": view.Version, "status": "queued", "receipt": jam.AdmissionReceipt{RequestID: requestID, SessionID: "retirement-fixture", OccurrenceID: "must-not-admit"}})
			if code == 200 {
				t.Fatal("late receipt admitted retired intent")
			}
		})
	}
}

func TestJamAcquisitionStoredSourceReusesMembershipAndBindsConsent(t *testing.T) {
	repo, o, p, m := jamIntegration(t)
	ctx := context.Background()
	// Non-nil publisher enables the feature, but stored source must not call it.
	publisher := &jamNeverPublisher{t: t}
	repo.Downloads = publisher
	provider := &jamSyntheticProvider{}
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{provider}})
	if _, e := repo.DB.Exec(`INSERT INTO tracks(id,identity_hash,title,storage_key) VALUES(2,'stored-source-synthetic','Synthetic stored','synthetic-no-media');INSERT INTO track_sources(track_id,provider,source_id,source_url) VALUES(2,'youtube','jam-exact-live','https://www.youtube.com/watch?v=jam-exact-live')`); e != nil {
		t.Fatal(e)
	}
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
	secret := jam.NewSecret()
	_, e = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Fixture", MemberSecret: secret})
	if e != nil {
		t.Fatal(e)
	}
	result, e := repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "synthetic"})
	if e != nil {
		t.Fatal(e)
	}
	qid := uuid.New()
	_, e = repo.AddSourceRequest(ctx, id, secret, jam.SourceRequestInput{RequestID: qid, SelectionSessionID: result.SearchID, CandidateID: result.Results[0].CandidateID, ExpectedVersion: 1})
	if e != nil {
		t.Fatal(e)
	}
	approvalPath := path + "/requests/" + qid.String() + "/approval"
	body := map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": 2, "hostSessionId": "captured-host-incarnation"}
	wrong := map[string]any{}
	for k, v := range body {
		wrong[k] = v
	}
	wrong["leaseId"] = uuid.New()
	code, _ := jamOwnerHTTP(t, m, o, "POST", approvalPath, wrong)
	if code != 403 {
		t.Fatalf("wrong lease %d", code)
	}
	code, b := jamOwnerHTTP(t, m, o, "POST", approvalPath, body)
	if code != 200 {
		t.Fatalf("stored approval %d %s", code, b)
	}
	var view jam.HostView
	_ = json.Unmarshal(b, &view)
	q := view.HostRequests[0]
	if q.Status != "ready" || q.TrackID != 2 || q.DownloadJobID != uuid.Nil || !q.CanAdmit || len(q.AdmissionKey) != 64 {
		t.Fatalf("stored source %+v", q)
	}
	var n int
	if e = repo.DB.QueryRow(`SELECT count(*) FROM download_jobs`).Scan(&n); e != nil || n != 0 {
		t.Fatal("stored source downloaded")
	}
	body["hostSessionId"] = "replacement-incarnation"
	code, _ = jamOwnerHTTP(t, m, o, "POST", approvalPath, body)
	if code != 409 {
		t.Fatalf("consent rebound %d", code)
	}
	// Ready cannot remain admissible after ownership has disappeared.
	if _, e = repo.DB.Exec(`DELETE FROM user_library WHERE user_id=$1 AND track_id=2`, o.UserID); e != nil {
		t.Fatal(e)
	}
	code, b = jamOwnerHTTP(t, m, o, "GET", path, nil)
	if code != 200 {
		t.Fatal(code)
	}
	_ = json.Unmarshal(b, &view)
	if view.HostRequests[0].Status != "failed" || view.HostRequests[0].CanAdmit {
		t.Fatal("ready survived membership removal")
	}
}

type jamNeverPublisher struct{ t *testing.T }

func (p *jamNeverPublisher) EnsureSourceCandidateWithID(context.Context, string, string, download.SourceCandidate, *string) (*download.DownloadJob, error) {
	p.t.Fatal("unexpected acquisition publication")
	return nil, jam.ErrUnavailable
}

func TestJamAcquisitionDefaultOptOut(t *testing.T) {
	repo, o, p, _ := jamIntegration(t)
	ctx := context.Background()
	provider := &jamSyntheticProvider{}
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{provider}})
	repo.Downloads = &jamNeverPublisher{t: t}
	id := uuid.New()
	_, e := repo.Create(ctx, o, jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}})
	if e != nil {
		t.Fatal(e)
	}
	invite, e := repo.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	secret := jam.NewSecret()
	_, e = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Fixture", MemberSecret: secret})
	if e != nil {
		t.Fatal(e)
	}
	_, e = repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "synthetic"})
	if e != jam.ErrDenied || provider.calls.Load() != 0 {
		t.Fatal("default spent on discovery")
	}
}
