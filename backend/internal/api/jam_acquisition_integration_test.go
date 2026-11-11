package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/openmusicplayer/backend/internal/jam"
)

func TestJamOneUnresolvedRequestPerMember(t *testing.T) {
	repo, owner, proof, _ := jamIntegration(t)
	ctx := context.Background()
	id := uuid.New()
	created, err := repo.Create(ctx, owner, jam.CreateInput{JamID: id, Proof: proof, TrackIDs: []int64{1}})
	if err != nil {
		t.Fatal(err)
	}
	invite, err := repo.RotateInvite(ctx, owner, id, proof)
	if err != nil {
		t.Fatal(err)
	}
	secret := jam.NewSecret()
	if _, err = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: secret}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		_, err = repo.AddRequest(ctx, id, secret, jam.RequestInput{RequestID: uuid.New(), CatalogItemID: created.Catalog[0].CatalogItemID, ExpectedVersion: created.Version + int64(i)})
		if i == 0 && err != nil {
			t.Fatal(err)
		}
		if i == 1 && err != jam.ErrConflict {
			t.Fatalf("second unresolved request must conflict, got %v", err)
		}
	}
}

func TestJamHostMemberIdentityOnlyFromAuthenticatedReadback(t *testing.T) {
	repo, owner, proof, mux := jamIntegration(t)
	ctx := context.Background()
	id := uuid.New()
	if _, err := repo.Create(ctx, owner, jam.CreateInput{JamID: id, Proof: proof, TrackIDs: []int64{1}}); err != nil {
		t.Fatal(err)
	}
	invite, err := repo.RotateInvite(ctx, owner, id, proof)
	if err != nil {
		t.Fatal(err)
	}
	secret := jam.NewSecret()
	// Deliberately discard guest join result: the host cannot consume guest credentials.
	if _, err = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: secret}); err != nil {
		t.Fatal(err)
	}
	path := "/api/v1/jams/" + id.String()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("X-Test-Owner", owner.UserID.String())
	out := httptest.NewRecorder()
	mux.ServeHTTP(out, req)
	var view struct {
		Version int64 `json:"version"`
		Members []struct {
			MemberID    uuid.UUID `json:"memberId"`
			DisplayName string    `json:"displayName"`
		} `json:"members"`
	}
	if err = json.Unmarshal(out.Body.Bytes(), &view); err != nil {
		t.Fatal(err)
	}
	if out.Code != 200 || len(view.Members) != 1 || view.Members[0].MemberID == uuid.Nil {
		t.Fatalf("host cannot discover revoke identity: HTTP %d %s", out.Code, out.Body.String())
	}
	if view.Members[0].DisplayName != "Listener" {
		t.Fatal("member association")
	}
	server := httptest.NewServer(mux)
	defer server.Close()
	body := map[string]any{"hostDeviceId": proof.HostDeviceID, "leaseId": proof.LeaseID, "writerSecret": proof.WriterSecret, "expectedVersion": view.Version}
	data, _ := json.Marshal(body)
	req = httptest.NewRequest(http.MethodDelete, path+"/members/"+view.Members[0].MemberID.String(), bytes.NewReader(data))
	req.Header.Set("X-Test-Owner", owner.UserID.String())
	out = httptest.NewRecorder()
	mux.ServeHTTP(out, req)
	if out.Code != 204 {
		t.Fatalf("revoke %d %s", out.Code, out.Body.String())
	}
	if _, err = repo.GuestSnapshot(ctx, id, secret); err != jam.ErrDenied {
		t.Fatalf("capability survived %v", err)
	}
}
