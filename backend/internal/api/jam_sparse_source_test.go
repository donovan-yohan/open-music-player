package api

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/discovery"
	"github.com/openmusicplayer/backend/internal/jam"
)

type jamSparseProvider struct{}

func (*jamSparseProvider) Name() string { return "youtube" }
func (*jamSparseProvider) Search(context.Context, string, int) ([]discovery.Candidate, error) {
	return []discovery.Candidate{{CandidateID: "youtube:jam-sparse", Provider: "youtube", SourceID: "jam-sparse", SourceURL: "https://www.youtube.com/watch?v=jam-sparse", Title: "Sparse recording (synthetic)", Downloadable: true}}, nil
}

// Preserve the actual producer's omitempty behavior rather than fabricating a
// client fixture with always-present artist/duration metadata.
func TestJamSparseSourceHTTPProducerOmitsUnknownPrivateMetadata(t *testing.T) {
	repo, owner, proof, mux := jamIntegration(t)
	ctx := context.Background()
	repo.Searcher = discovery.NewService(discovery.ServiceConfig{Providers: []discovery.Provider{&jamSparseProvider{}}})
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
	if _, err = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Synthetic listener", MemberSecret: secret}); err != nil {
		t.Fatal(err)
	}
	result, err := repo.Search(ctx, id, secret, jam.SearchInput{SearchID: uuid.New(), Query: "Sparse recording"})
	if err != nil || len(result.Results) != 1 {
		t.Fatalf("sparse source lookup: %v", err)
	}
	choice := result.Results[0]
	if choice.Artist != "" || choice.DurationMS != 0 {
		t.Fatal("fixture unexpectedly has artist or duration")
	}
	if _, err = repo.AddSourceRequest(ctx, id, secret, jam.SourceRequestInput{RequestID: uuid.New(), SelectionSessionID: choice.SelectionSessionID, CandidateID: choice.CandidateID, ExpectedVersion: 1}); err != nil {
		t.Fatal(err)
	}
	status, body := jamOwnerHTTP(t, mux, owner, "GET", "/api/v1/jams/"+id.String(), nil)
	if status != 200 {
		t.Fatalf("host response status: %d", status)
	}
	var view jam.HostView
	if err = json.Unmarshal(body, &view); err != nil || len(view.HostRequests) != 1 {
		t.Fatalf("host response: %v", err)
	}
	var selected map[string]json.RawMessage
	if err = json.Unmarshal(view.HostRequests[0].SelectedSource, &selected); err != nil {
		t.Fatal(err)
	}
	if _, exists := selected["artist"]; exists {
		t.Fatal("expected actual private artist omission")
	}
	if _, exists := selected["durationMs"]; exists {
		t.Fatal("expected actual private unknown-duration omission")
	}
	jamSaveProducer(t, "host-sparse-pending", body)
}
