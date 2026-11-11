package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/db"
	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/download"
	"github.com/openmusicplayer/backend/internal/jam"
)

type jamSyntheticProvider struct{ calls atomic.Int32 }

func (p *jamSyntheticProvider) Name() string { return "youtube" }
func (p *jamSyntheticProvider) Search(_ context.Context, _ string, _ int) ([]discovery.Candidate, error) {
	p.calls.Add(1)
	return []discovery.Candidate{{CandidateID: "youtube:jam-exact-live", Provider: "youtube", SourceID: "jam-exact-live", SourceURL: "https://www.youtube.com/watch?v=jam-exact-live", Title: "Afterglow (live, synthetic)", Artist: "Synthetic artist", DurationMs: 181000, Downloadable: true, Metadata: map[string]any{"private": "must not cross projection"}}}, nil
}

type jamLostPublisher struct {
	service *download.Service
	lose    bool
}

func (p *jamLostPublisher) EnsureSourceCandidateWithID(ctx context.Context, job, user string, c download.SourceCandidate, mb *string) (*download.DownloadJob, error) {
	result, e := p.service.EnsureSourceCandidateWithID(ctx, job, user, c, mb)
	if e == nil && p.lose {
		p.lose = false
		return nil, errors.New("synthetic lost Redis ACK")
	}
	return result, e
}
func jamOwnerHTTP(t *testing.T, m http.Handler, o jam.Owner, method, path string, body any) (int, []byte) {
	t.Helper()
	var data []byte
	var err error
	if body != nil {
		data, err = json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
	}
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.Header.Set("X-Test-Owner", o.UserID.String())
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	m.ServeHTTP(w, r)
	return w.Code, w.Body.Bytes()
}
func jamSaveProducer(t *testing.T, name string, data []byte) {
	t.Helper()
	dir := os.Getenv("JAM_ACQUISITION_EVIDENCE_DIR")
	if dir == "" {
		return
	}
	if e := os.MkdirAll(dir, 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(dir, name+".json"), data, 0600); e != nil {
		t.Fatal(e)
	}
}

func TestJamAcquisitionHTTPExactSourceDurableRecoveryAndOrdering(t *testing.T) {
	repo, o, p, m := jamIntegration(t)
	ctx := context.Background()
	provider := &jamSyntheticProvider{}
	searcher := discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{provider}})
	lifecycle := db.NewSourceSelectionDownloadLifecycle(&db.DB{DB: repo.DB})
	service, e := download.NewService(&download.ServiceConfig{RedisURL: "redis://" + os.Getenv("JAM_TEST_REDIS") + "/0", WorkerCount: 0}, nil, lifecycle)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = service.Queue().Close() })
	publisher := &jamLostPublisher{service: service, lose: true}
	repo.Searcher = searcher
	repo.Downloads = publisher
	id := uuid.New()
	path := "/api/v1/jams/" + id.String()
	code, b := jamOwnerHTTP(t, m, o, "POST", "/api/v1/jams", jam.CreateInput{JamID: id, Proof: p, TrackIDs: []int64{1}, AllowOutsideDiscovery: true})
	if code != 201 {
		t.Fatalf("create %d %s", code, b)
	}
	invite, e := repo.RotateInvite(ctx, o, id, p)
	if e != nil {
		t.Fatal(e)
	}
	server := httptest.NewServer(m)
	defer server.Close()
	base := server.URL + "/api/v1/guest/jams/" + id.String()
	secrets := []string{jam.NewSecret(), jam.NewSecret()}
	for _, secret := range secrets {
		code, b, _ = jamHTTP(t, server.Client(), "POST", base+"/members", "", jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Synthetic listener", MemberSecret: secret})
		if code != 201 {
			t.Fatalf("join %d %s", code, b)
		}
	}
	search := jam.SearchInput{SearchID: uuid.New(), Query: "Afterglow live"}
	for attempt := 0; attempt < 2; attempt++ {
		code, b, _ = jamHTTP(t, server.Client(), "POST", base+"/search", secrets[0], search)
		if code != 200 {
			t.Fatalf("search %d %s", code, b)
		}
	}
	if provider.calls.Load() != 1 {
		t.Fatal("lost search ACK repeated provider")
	}
	jamSaveProducer(t, "search", b)
	if strings.Contains(string(b), "sourceUrl") || strings.Contains(string(b), "private") {
		t.Fatal("private search details escaped")
	}
	var results jam.SearchResult
	if e = json.Unmarshal(b, &results); e != nil || len(results.Results) != 1 {
		t.Fatalf("search decode %v", e)
	}
	source := results.Results[0]
	request := jam.SourceRequestInput{RequestID: uuid.New(), SelectionSessionID: source.SelectionSessionID, CandidateID: source.CandidateID, ExpectedVersion: 1}
	// An exact server-issued selection is member-bound, not just owner-bound.
	code, _, _ = jamHTTP(t, server.Client(), "POST", base+"/source-requests", secrets[1], request)
	if code != 403 {
		t.Fatalf("other member selected capture: %d", code)
	}
	for attempt := 0; attempt < 2; attempt++ {
		code, b, _ = jamHTTP(t, server.Client(), "POST", base+"/source-requests", secrets[0], request)
		if code != 201 {
			t.Fatalf("request %d %s", code, b)
		}
	}
	jamSaveProducer(t, "source-request", b)
	code, b = jamOwnerHTTP(t, m, o, "GET", path, nil)
	if code != 200 {
		t.Fatal(code)
	}
	jamSaveProducer(t, "host-pending", b)
	var view jam.HostView
	if e = json.Unmarshal(b, &view); e != nil {
		t.Fatal(e)
	}
	if view.HostRequests[0].Status != "pending" || view.HostRequests[0].TrackID != 0 {
		t.Fatal("source prematurely playable")
	}
	var n int
	if e = repo.DB.QueryRow(`SELECT count(*) FROM download_jobs`).Scan(&n); e != nil || n != 0 {
		t.Fatalf("implicit acquisition %d %v", n, e)
	}
	approve := map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": view.Version, "hostSessionId": "synthetic-host-incarnation-1"}
	approvalPath := path + "/requests/" + request.RequestID.String() + "/approval"
	code, b = jamOwnerHTTP(t, m, o, "POST", approvalPath, approve)
	if code != 503 {
		t.Fatalf("lost publisher ACK expected unavailable %d %s", code, b)
	}
	code, b = jamOwnerHTTP(t, m, o, "POST", approvalPath, approve)
	if code != 200 {
		t.Fatalf("approval retry %d %s", code, b)
	}
	jamSaveProducer(t, "host-importing", b)
	if e = json.Unmarshal(b, &view); e != nil {
		t.Fatal(e)
	}
	q := view.HostRequests[0]
	if q.Status != "importing" || q.CanAdmit || q.TrackID != 0 || q.DownloadJobID == uuid.Nil {
		t.Fatalf("job called queued/ready %+v", q)
	}
	if e = repo.DB.QueryRow(`SELECT count(*) FROM download_jobs`).Scan(&n); e != nil || n != 1 {
		t.Fatalf("duplicate durable job %d %v", n, e)
	}
	// Reconstruct the repository: all request, source and approval identity is SQL.
	database := repo.DB
	*repo = *jam.NewRepository(database)
	repo.Searcher = searcher
	repo.Downloads = publisher
	recovered, e := lifecycle.Recover(ctx, service, 10)
	if e != nil || recovered != 1 {
		t.Fatalf("recovery %d %v", recovered, e)
	}
	job, e := service.GetJob(ctx, q.DownloadJobID.String())
	if e != nil {
		t.Fatal(e)
	}
	if job.SourceID != source.SourceID || job.URL != "https://www.youtube.com/watch?v=jam-exact-live" || job.UserID != o.UserID.String() {
		t.Fatalf("source changed %+v", job)
	}
	t.Cleanup(func() {
		client := service.Queue().Client()
		client.LRem(ctx, "download:queue", 0, job.ID)
		client.Del(ctx, "download:job:"+job.ID)
		client.ZRem(ctx, "download:user:"+o.UserID.String(), job.ID)
	})
	// Second guest's offered request can be approved but cannot pass the earlier import.
	offered := jam.RequestInput{RequestID: uuid.New(), CatalogItemID: view.Catalog[0].CatalogItemID, ExpectedVersion: view.Version}
	code, b, _ = jamHTTP(t, server.Client(), "POST", base+"/requests", secrets[1], offered)
	if code != 201 {
		t.Fatalf("offered %d %s", code, b)
	}
	code, b = jamOwnerHTTP(t, m, o, "GET", path, nil)
	if code != 200 {
		t.Fatal(code)
	}
	_ = json.Unmarshal(b, &view)
	approve2 := map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": view.Version, "hostSessionId": "synthetic-host-incarnation-1"}
	code, b = jamOwnerHTTP(t, m, o, "POST", path+"/requests/"+offered.RequestID.String()+"/approval", approve2)
	if code != 200 {
		t.Fatalf("offered approval %d %s", code, b)
	}
	_ = json.Unmarshal(b, &view)
	if view.HostRequests[1].CanAdmit {
		t.Fatal("acquisition completion order bypasses approval order")
	}
	receiptBody := map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": view.Version, "status": "queued", "receipt": jam.AdmissionReceipt{RequestID: offered.RequestID, SessionID: "synthetic-host-incarnation-1", OccurrenceID: "synthetic-occurrence-2"}}
	code, _ = jamOwnerHTTP(t, m, o, "PUT", path+"/requests/"+offered.RequestID.String(), receiptBody)
	if code != 409 {
		t.Fatalf("later admission bypass %d", code)
	}
	// Synthetic worker output: SQL track + owned membership, then REAL lifecycle
	// completion. No yt-dlp/audio/native queue insertion is claimed by this test.
	if _, e = repo.DB.Exec(`INSERT INTO tracks(id,identity_hash,title,artist,storage_key,duration_ms) VALUES(2,'jam-synthetic-acquired','Afterglow (live, synthetic)','Synthetic artist','synthetic-acquired-no-media',181000);`); e != nil {
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
	if code != 200 {
		t.Fatalf("ready %d %s", code, b)
	}
	jamSaveProducer(t, "host-ready", b)
	_ = json.Unmarshal(b, &view)
	if view.HostRequests[0].Status != "ready" || view.HostRequests[0].TrackID != 2 || !view.HostRequests[0].CanAdmit || view.HostRequests[1].CanAdmit {
		t.Fatalf("readiness/order %+v", view.HostRequests)
	}
	code, guest, _ := jamHTTP(t, server.Client(), "GET", base, secrets[0], nil)
	if code != 200 {
		t.Fatal(code)
	}
	jamSaveProducer(t, "guest-ready", guest)
	for _, private := range []string{"ownerUserId", "hostDeviceId", "leaseId", "selectedSource", "sourceUrl", "trackId", "memberId", "admissionKey"} {
		if strings.Contains(string(guest), `"`+private+`"`) {
			t.Fatalf("guest private field %s", private)
		}
	}
	receiptBody = map[string]any{"hostDeviceId": p.HostDeviceID, "leaseId": p.LeaseID, "writerSecret": p.WriterSecret, "expectedVersion": view.Version, "status": "queued", "receipt": jam.AdmissionReceipt{RequestID: request.RequestID, SessionID: "synthetic-host-incarnation-1", OccurrenceID: "synthetic-occurrence-1"}}
	for attempt := 0; attempt < 2; attempt++ {
		code, b = jamOwnerHTTP(t, m, o, "PUT", path+"/requests/"+request.RequestID.String(), receiptBody)
		if code != 200 {
			t.Fatalf("receipt/retry %d %s", code, b)
		}
	}
	code, b = jamOwnerHTTP(t, m, o, "GET", path, nil)
	if code != 200 {
		t.Fatal(code)
	}
	jamSaveProducer(t, "host-receipt-reconciled", b)
	_ = json.Unmarshal(b, &view)
	if view.HostRequests[0].Status != "queued" || !view.HostRequests[1].CanAdmit {
		t.Fatal("receipt failed to release approval order")
	}
	t.Log("actual HTTP + guarded canonical SQL + Redis acquisition projection/recovery passed; provider and worker output and host occurrence receipt are SYNTHETIC, not native/audio acceptance")
}
