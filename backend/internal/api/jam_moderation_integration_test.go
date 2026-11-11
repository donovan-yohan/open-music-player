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

func TestJamGuestWithdrawHTTPFencesOtherMembersAndLateApproval(t *testing.T) {
	repo, owner, proof, mux := jamIntegration(t)
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
	secrets := []string{jam.NewSecret(), jam.NewSecret()}
	for _, secret := range secrets {
		if _, err = repo.Join(ctx, id, jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: secret}); err != nil {
			t.Fatal(err)
		}
	}
	requestID := uuid.New()
	if _, err = repo.AddRequest(ctx, id, secrets[0], jam.RequestInput{RequestID: requestID, CatalogItemID: created.Catalog[0].CatalogItemID, ExpectedVersion: created.Version}); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(mux)
	defer server.Close()
	path := server.URL + "/api/v1/guest/jams/" + id.String() + "/requests/" + requestID.String()
	body := map[string]int64{"expectedVersion": created.Version + 1}
	status, _, _ := jamHTTP(t, server.Client(), http.MethodDelete, path, secrets[1], body)
	if status != http.StatusForbidden {
		t.Fatalf("another guest could retire intent: HTTP %d", status)
	}
	for attempt := 0; attempt < 2; attempt++ {
		status, _, _ = jamHTTP(t, server.Client(), http.MethodDelete, path, secrets[0], body)
		if status != http.StatusNoContent {
			t.Fatalf("same withdrawal/retry: HTTP %d", status)
		}
	}
	view, err := repo.HostSnapshot(ctx, owner, id)
	if err != nil || view.HostRequests[0].Status != "withdrawn" {
		t.Fatalf("withdrawal readback: status=%v error=%v", view.HostRequests, err)
	}
	_, err = repo.Decide(ctx, owner, id, proof, requestID, jam.DecisionInput{ExpectedVersion: view.Version, Status: "queued", Receipt: &jam.AdmissionReceipt{RequestID: requestID, SessionID: "fixture", OccurrenceID: "fixture"}})
	if err != jam.ErrConflict {
		t.Fatalf("withdrawn request admitted: %v", err)
	}
}

func TestJamHostRevokeHTTPRequiresWriterAndRetiresIntent(t *testing.T) {
	repo, owner, proof, mux := jamIntegration(t)
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
	input := jam.JoinInput{JoinToken: invite.JoinToken, RequestID: uuid.New(), DisplayName: "Listener", MemberSecret: jam.NewSecret()}
	_, err = repo.Join(ctx, id, input)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = repo.AddRequest(ctx, id, input.MemberSecret, jam.RequestInput{RequestID: uuid.New(), CatalogItemID: created.Catalog[0].CatalogItemID, ExpectedVersion: created.Version}); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(mux)
	defer server.Close()
	hostPath := "/api/v1/jams/" + id.String()
	code, data := jamOwnerHTTP(t, mux, owner, http.MethodGet, hostPath, nil)
	var host jam.HostView
	if code != 200 || json.Unmarshal(data, &host) != nil || len(host.Members) != 1 {
		t.Fatalf("host member readback %d %s", code, data)
	}
	path := hostPath + "/members/" + host.Members[0].MemberID.String()
	body := map[string]any{"hostDeviceId": proof.HostDeviceID, "leaseId": proof.LeaseID, "writerSecret": proof.WriterSecret, "expectedVersion": created.Version + 1}
	status, _, _ := jamHTTP(t, server.Client(), http.MethodDelete, server.URL+path, input.MemberSecret, body)
	if status != http.StatusForbidden {
		t.Fatalf("guest used host revoke: HTTP %d", status)
	}
	for attempt := 0; attempt < 2; attempt++ {
		recorder := httptest.NewRecorder()
		payload, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodDelete, path, bytes.NewReader(payload))
		request.Header.Set("X-Test-Owner", owner.UserID.String())
		request.Header.Set("Content-Type", "application/json")
		mux.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusNoContent {
			t.Fatalf("same host revoke/retry: HTTP %d", recorder.Code)
		}
	}
	view, err := repo.HostSnapshot(ctx, owner, id)
	if err != nil || view.MemberCount != 0 || view.HostRequests[0].Status != "withdrawn" {
		t.Fatalf("revoke readback members=%d error=%v", view.MemberCount, err)
	}
	if _, err = repo.GuestSnapshot(ctx, id, input.MemberSecret); err != jam.ErrDenied {
		t.Fatalf("revoked guest read: %v", err)
	}
	if _, err = repo.Join(ctx, id, input); err != jam.ErrDenied {
		t.Fatalf("revoked join replay: %v", err)
	}
}
